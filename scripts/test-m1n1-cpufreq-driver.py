#!/usr/bin/env python3
"""Compile the pinned cpufreq.c bodies against host-only MMIO mocks."""

from __future__ import annotations

import hashlib
import os
import pathlib
import shutil
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
PINNED = ROOT / "scratch/m1n1-cpu-audit/m1n1-4184923ffb2dff079b384d6a32cc02142aa14572"
SOURCE = PINNED / "src/cpufreq.c"
TEMPLATE = ROOT / "tests/m1n1-cpufreq-driver.c"
SOURCE_SHA256 = "d52a3c80a657485ba9288a91c7021fc90b4d1078f2e528091c212cd0f4b57b07"


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


def materialize(work: pathlib.Path) -> str:
    if not SOURCE.is_file():
        fail(f"pinned cpufreq source missing: {SOURCE}")
    data = SOURCE.read_bytes()
    if sha256(data) != SOURCE_SHA256:
        fail("pinned src/cpufreq.c hash mismatch")
    tree = work / "m1n1"
    (tree / "src").mkdir(parents=True)
    materialized = tree / "src/cpufreq.c"
    materialized.write_bytes(data)
    return data.decode("utf-8")


def body(source: str) -> str:
    marker = "#define CLUSTER_PSTATE"
    start = source.find(marker)
    if start < 0:
        fail("cpufreq source body marker missing")
    return source[start:]


def replace_once(source: str, old: str, new: str, label: str) -> str:
    if source.count(old) != 1:
        fail(f"{label}: expected one mutation site, found {source.count(old)}")
    return source.replace(old, new, 1)


def mutate_unsupported(source: str) -> str:
    clusters = source.index("const struct cluster_t *cpufreq_get_clusters(void)")
    features = source.index("const struct feat_t *cpufreq_get_features(void)")
    init = source.index("int cpufreq_init(void)")
    cluster_part = replace_once(
        source[clusters:features], "return NULL;", "return t6030_clusters;", "unsupported clusters"
    )
    feature_part = replace_once(
        source[features:init], "return NULL;", "return t6030_features;", "unsupported features"
    )
    return source[:clusters] + cluster_part + feature_part + source[init:]


def mutate_feature_failure(source: str) -> str:
    old = """printf(\"cpufreq: Timed out waiting for feature %s on cluster %s\\n\", features->name,
                   cluster->name);
            return -1;"""
    new = old.replace("return -1;", "return 0;")
    return replace_once(source, old, new, "feature rejection")


def mutate_outer_failure(source: str) -> str:
    return replace_once(
        source,
        "err |= cpufreq_init_cluster(cluster++, features);",
        "return cpufreq_init_cluster(cluster++, features);",
        "outer-loop continuation",
    )


def mutate_restore_write(source: str) -> str:
    old = "            write64(cluster->base + 0x440f8, 1);"
    if source.count(old) != 2:
        fail(f"restore deletion: expected two restore-write sites, found {source.count(old)}")
    first = source.find(old)
    second = source.find(old, first + len(old))
    return source[:second] + source[second + len(old):]


def compile_and_run(work: pathlib.Path, source: str, label: str) -> subprocess.CompletedProcess[str]:
    template = TEMPLATE.read_text(encoding="utf-8")
    marker = "/* INSERT_CPUFREQ_SOURCE */"
    if template.count(marker) != 1:
        fail("cpufreq harness source marker must occur exactly once")
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


def main() -> int:
    if shutil.which("clang") is None:
        fail("clang is required")
    if not TEMPLATE.is_file():
        fail("cpufreq harness template missing")
    with tempfile.TemporaryDirectory(dir=ROOT / "scratch", prefix="cpufreq-driver-") as directory:
        work = pathlib.Path(directory)
        source = materialize(work)
        baseline = compile_and_run(work, source, "baseline")
        if baseline.returncode != 0:
            fail(f"baseline harness failed with exit {baseline.returncode}")

        mutations = (
            ("mutation-unsupported", mutate_unsupported(source),
             "T6032 cpufreq_init did not reject before MMIO"),
            ("mutation-feature-rejection", mutate_feature_failure(source),
             "feature wait timeout was not reported"),
            ("mutation-outer-continuation", mutate_outer_failure(source),
             "T6031 APSC/features/wait/restore/default order mismatch"),
            ("mutation-restore-write", mutate_restore_write(source),
             "T6031 APSC/features/wait/restore/default order mismatch"),
        )
        for label, mutated, diagnostic in mutations:
            result = compile_and_run(work, mutated, label)
            if result.returncode != 1 or diagnostic not in result.stderr:
                fail(f"{label}: expected exit 1 and diagnostic {diagnostic!r}")
    print("cpufreq driver harness: baseline + 4 mutation checks passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(f"m1n1 cpufreq driver harness: ERROR: {exc}")
        raise SystemExit(1)
