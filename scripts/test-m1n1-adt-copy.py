#!/usr/bin/env python3
"""Source-extracted host regression for the Rust ADT C-copy ABI."""

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
SOURCE = PINNED / "rust/src/adt.rs"
SOURCE_SHA256 = "3771322ab6ab7b9c28807857fa77672ae6b09bb58588d46d94bc58f144afdd97"
PATCHES = (
    ROOT / "patches/m1n1/0020-check-adt-copy-length-before-write.patch",
    ROOT / "patches/m1n1/0021-fix-adt-property-view-length.patch",
)
TEMPLATE = ROOT / "tests/m1n1-adt-copy.rs"


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
        env={**os.environ, "RUST_BACKTRACE": "1"},
    )


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def materialize(work: pathlib.Path) -> tuple[str, str]:
    if not SOURCE.is_file() or not all(p.is_file() for p in PATCHES) or not TEMPLATE.is_file():
        fail("ADT source, patch, or harness missing")
    data = SOURCE.read_bytes()
    if sha256(data) != SOURCE_SHA256:
        fail("pinned rust/src/adt.rs hash mismatch")
    archive_data = ARCHIVE.read_bytes()
    if sha256(archive_data) != ARCHIVE_SHA256:
        fail("pinned source archive hash mismatch")
    with tarfile.open(ARCHIVE) as archive:
        member = archive.extractfile(f"{PINNED.name}/rust/src/adt.rs")
        if member is None or member.read() != data:
            fail("pinned archive rust/src/adt.rs mismatch")

    tree = work / "m1n1"
    source_path = tree / "rust/src/adt.rs"
    source_path.parent.mkdir(parents=True)
    source_path.write_bytes(data)
    for patch in PATCHES:
        applied = run(
            ["patch", "-p1", "--batch", "--forward", "--fuzz=0", "--no-backup-if-mismatch",
             "-i", str(patch)], tree
        )
        if applied.returncode:
            fail(f"{patch.name} did not apply:\n{applied.stdout}{applied.stderr}")
    paths = {p.relative_to(tree) for p in tree.rglob("*") if p.is_file()}
    if paths != {pathlib.Path("rust/src/adt.rs")}:
        fail(f"ADT patches created unexpected paths: {sorted(str(p) for p in paths)}")
    return data.decode(), source_path.read_text(encoding="utf-8")


def mutate_no_length_guard(source: str) -> str:
    old = "    if p.payload_size() as usize != len {\n"
    new = "    if false && p.payload_size() as usize != len {\n"
    if source.count(old) != 1:
        fail(f"ADT length guard: expected one site, found {source.count(old)}")
    return source.replace(old, new, 1)


def host_compatible(source: str) -> str:
    old = "use core::ffi::*;\n"
    new = "use core::ffi::{c_char, c_int, c_uint, c_void};\nuse core::ffi::CStr;\n"
    if source.count(old) != 1:
        fail("ADT source ffi import is not unique")
    source = source.replace(old, new, 1)
    old_name = "CStr::from_bytes_until_nul(&self.name)"
    new_name = (
        "CStr::from_bytes_until_nul(unsafe { core::slice::from_raw_parts("
        "self.name.as_ptr() as *const u8, self.name.len()) })"
    )
    if source.count(old_name) != 1:
        fail("ADT property name conversion site is not unique")
    return source.replace(old_name, new_name, 1)


def compile_and_run(work: pathlib.Path, source: str, label: str) -> subprocess.CompletedProcess[str]:
    source_path = work / "adt.rs"
    source_path.write_text(host_compatible(source), encoding="utf-8")
    harness = work / f"{label}.rs"
    harness.write_text(TEMPLATE.read_text(encoding="utf-8"), encoding="utf-8")
    binary = work / label
    compiled = run(
        [
            "rustc",
            "--edition=2021",
            "-C",
            "debuginfo=1",
            "-C",
            "opt-level=0",
            str(harness),
            "-o",
            str(binary),
        ],
        work,
    )
    if compiled.returncode:
        fail(f"{label}: rustc failed:\n{compiled.stdout}{compiled.stderr}")
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
    if shutil.which("rustc") is None:
        fail("rustc is required")
    with tempfile.TemporaryDirectory(dir=ROOT / "scratch", prefix="adt-copy-") as directory:
        work = pathlib.Path(directory)
        original, patched = materialize(work)
        negative = compile_and_run(work, original, "negative-control")
        expect_failure(negative, "negative-control", "long mismatch modified destination")
        baseline = compile_and_run(work, patched, "baseline")
        if baseline.returncode != 0:
            fail(f"baseline harness failed with exit {baseline.returncode}")
        mutated = compile_and_run(work, mutate_no_length_guard(patched), "mutation-no-length-guard")
        expect_failure(mutated, "mutation-no-length-guard", "long mismatch modified destination")
    print("ADT copy harness: negative control + baseline + guard mutation passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(f"m1n1 ADT copy harness: ERROR: {exc}")
        raise SystemExit(1)
