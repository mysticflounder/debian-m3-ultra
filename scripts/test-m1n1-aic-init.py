#!/usr/bin/env python3
"""Source-extracted host harness for the bounded AIC init contract."""

from __future__ import annotations

import hashlib
import os
import pathlib
import shutil
import subprocess
import tarfile
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
PINNED = ROOT / "scratch/m1n1-cpu-audit/m1n1-4184923ffb2dff079b384d6a32cc02142aa14572"
ARCHIVE = ROOT / "scratch/m1n1-cpu-audit/source.tar.gz"
ARCHIVE_SHA256 = "6425983260ab96d55c36fdaab3b456830c3bd80f06b7759a61ed2bcca924d973"
SOURCE = PINNED / "src/aic.c"
PATCH = ROOT / "patches/m1n1/0019-validate-aic-init-metadata.patch"
TEMPLATE = ROOT / "tests/m1n1-aic-init.c"
SOURCE_SHA256 = "a192556a285229af685faef3ebd9f3adb44dfcda2dde77093288a9acbd77b7b6"


def fail(message: str) -> None:
    raise RuntimeError(message)


def run(command: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        env={
            **os.environ,
            "ASAN_OPTIONS": "detect_leaks=0",
            "UBSAN_OPTIONS": "halt_on_error=1:print_stacktrace=1",
        },
    )


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def snapshot(tree: pathlib.Path) -> dict[pathlib.Path, bytes]:
    return {
        path.relative_to(tree): path.read_bytes()
        for path in tree.rglob("*")
        if path.is_file()
    }


def materialize(work: pathlib.Path) -> tuple[str, str]:
    if not SOURCE.is_file():
        fail(f"pinned AIC source missing: {SOURCE}")
    data = SOURCE.read_bytes()
    if sha256(data) != SOURCE_SHA256:
        fail("pinned src/aic.c hash mismatch")
    if sha256(ARCHIVE.read_bytes()) != ARCHIVE_SHA256:
        fail("pinned source archive hash mismatch")
    with tarfile.open(ARCHIVE) as archive:
        archived = archive.extractfile(f"{PINNED.name}/src/aic.c")
        if archived is None or archived.read() != data:
            fail("pinned archive src/aic.c mismatch")
    tree = work / "m1n1"
    (tree / "src").mkdir(parents=True)
    (tree / "src/aic.c").write_bytes(data)
    before = snapshot(tree)
    applied = run([
        "patch", "-p1", "--batch", "--forward", "--fuzz=0", "--no-backup-if-mismatch",
        "-i", str(PATCH)
    ], tree)
    if applied.returncode:
        fail(f"0019 did not apply:\n{applied.stdout}{applied.stderr}")
    after = snapshot(tree)
    changed = {path for path in set(before) | set(after) if before.get(path) != after.get(path)}
    if changed != {pathlib.Path("src/aic.c")}:
        fail(f"0019 changed unexpected paths: {sorted(str(path) for path in changed)}")
    return data.decode("utf-8"), after[pathlib.Path("src/aic.c")].decode("utf-8")


def body(source: str) -> str:
    marker = "#define MASK_REG"
    start = source.find(marker)
    if start < 0:
        fail("AIC source body marker missing")
    return source[start:]


def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        fail(f"{label}: expected one mutation site, found {count}")
    return source.replace(old, new, 1)


def mutate_no_length_guard(source: str) -> str:
    return replace_once(
        source,
        "if (ext_intr_config_len % 3)",
        "if (false && ext_intr_config_len % 3)",
        "extintrcfg length guard",
    )


def mutate_no_record_prevalidation(source: str) -> str:
    return replace_once(
        source,
        "if (die >= aic->nr_die || irq >= aic->nr_irq)",
        "if (false && (die >= aic->nr_die || irq >= aic->nr_irq))",
        "extintrcfg record prevalidation",
    )


def mutate_no_exact_length_check(source: str) -> str:
    return replace_once(
        source,
        "if (!raw || actual_len != len)",
        "if (!raw)",
        "ADT scalar exact-length check",
    )


def compile_and_run(work: pathlib.Path, source: str, label: str) -> subprocess.CompletedProcess[str]:
    template = TEMPLATE.read_text(encoding="utf-8")
    marker = "/* INSERT_AIC_SOURCE */"
    if template.count(marker) != 1:
        fail("AIC harness source marker must occur exactly once")
    generated = work / f"{label}.c"
    binary = work / label
    generated.write_text(template.replace(marker, body(source)), encoding="utf-8")
    compiled = run(
        [
            "clang",
            "-std=c11",
            "-O1",
            "-g",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-fsanitize=address,undefined",
            "-fno-sanitize-recover=all",
            "-fno-omit-frame-pointer",
            str(generated),
            "-o",
            str(binary),
        ],
        work,
    )
    if compiled.returncode:
        fail(f"{label}: clang failed:\n{compiled.stdout}{compiled.stderr}")
    completed = run([str(binary)], work)
    if completed.stdout:
        print(f"{label}: {completed.stdout.strip()}")
    if completed.stderr:
        print(f"{label}: stderr: {completed.stderr.strip()}")
    return completed


def expect_failure(result: subprocess.CompletedProcess[str], label: str, diagnostic: str) -> None:
    if result.returncode != 1 or diagnostic not in result.stderr:
        fail(f"{label}: expected exit 1 and diagnostic {diagnostic!r}")


def main() -> int:
    if shutil.which("clang") is None:
        fail("clang is required")
    if not PATCH.is_file() or not TEMPLATE.is_file():
        fail("AIC patch or harness template missing")
    with tempfile.TemporaryDirectory(dir=ROOT / "scratch", prefix="aic-init-") as directory:
        work = pathlib.Path(directory)
        original, patched = materialize(work)
        negative = compile_and_run(work, original, "negative-control")
        expect_failure(negative, "negative-control", "AIC3 missing cap0 did not fail closed")
        baseline = compile_and_run(work, patched, "baseline")
        if baseline.returncode != 0:
            fail(f"baseline harness failed with exit {baseline.returncode}")
        mutations = (
            ("mutation-no-length-guard", mutate_no_length_guard(patched),
             "malformed extintrcfg did not fail closed"),
            ("mutation-no-record-prevalidation", mutate_no_record_prevalidation(patched),
             "invalid later die wrote before validation"),
            ("mutation-no-exact-length-check", mutate_no_exact_length_check(patched),
             "wrong-size AIC config property did not fail closed"),
        )
        for label, source, diagnostic in mutations:
            expect_failure(compile_and_run(work, source, label), label, diagnostic)
    print("AIC init harness: negative control + baseline + 3 mutation checks passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(f"m1n1 AIC init harness: ERROR: {exc}")
        raise SystemExit(1)
