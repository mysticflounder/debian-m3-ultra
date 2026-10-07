#!/usr/bin/env python3
"""Source-extracted host regression for the Rust ADT DST property view."""

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
PATCH_0020 = ROOT / "patches/m1n1/0020-check-adt-copy-length-before-write.patch"
PATCH_0021 = ROOT / "patches/m1n1/0021-fix-adt-property-view-length.patch"
TEMPLATE = ROOT / "tests/m1n1-adt-view.rs"
VIEW_HELPER = r'''

#[cfg(adt_view_harness)]
pub unsafe fn adt_view_harness_property(
    offset: c_int,
    name: *const c_char,
) -> Option<&'static ADTProperty> {
    let strname = CStr::from_ptr(name).to_str().ok()?;
    let ptr = adt.add(offset as usize) as *const ADTNode;
    ADTNode::from_ptr(ptr).ok()?.named_prop(strname).ok()
}

#[cfg(adt_view_harness)]
pub unsafe fn adt_view_harness_properties(
    offset: c_int,
) -> Option<Vec<&'static ADTProperty>> {
    let ptr = adt.add(offset as usize) as *const ADTNode;
    let node = ADTNode::from_ptr(ptr).ok()?;
    node.properties().map(|property| property.ok()).collect()
}
'''


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


def apply_patch(tree: pathlib.Path, patch: pathlib.Path, label: str) -> None:
    applied = run(
        [
            "patch",
            "-p1",
            "--batch",
            "--forward",
            "--fuzz=0",
            "--no-backup-if-mismatch",
            "-i",
            str(patch),
        ],
        tree,
    )
    if applied.returncode:
        fail(f"{label} did not apply:\n{applied.stdout}{applied.stderr}")


def materialize(work: pathlib.Path) -> tuple[str, str, str]:
    if not SOURCE.is_file() or not PATCH_0020.is_file() or not PATCH_0021.is_file() or not TEMPLATE.is_file():
        fail("ADT source, patches, or harness missing")
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
    apply_patch(tree, PATCH_0020, "0020")
    after_0020 = source_path.read_text(encoding="utf-8")
    apply_patch(tree, PATCH_0021, "0021")
    patched = source_path.read_text(encoding="utf-8")
    paths = {p.relative_to(tree) for p in tree.rglob("*") if p.is_file()}
    if paths != {pathlib.Path("rust/src/adt.rs")}:
        fail(f"ADT patches created unexpected paths: {sorted(str(p) for p in paths)}")
    return data.decode(), after_0020, patched


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


def mutate_header_metadata(source: str) -> str:
    old = "core::ptr::slice_from_raw_parts(ptr, size)"
    new = "core::ptr::slice_from_raw_parts(ptr, size + 36)"
    if source.count(old) != 1:
        fail(f"DST metadata construction: expected one site, found {source.count(old)}")
    return source.replace(old, new, 1)


def mutate_first_size_byte(source: str) -> str:
    old = """let size = (u32::from_le(core::ptr::read_unaligned(
                ptr.add(32).cast::<u32>(),
            )) & ADT_SIZE_MASK) as usize;"""
    new = "let size = unsafe { *ptr.add(32) as usize };"
    if source.count(old) != 1:
        fail(f"DST u32 length read: expected one site, found {source.count(old)}")
    return source.replace(old, new, 1)


def mutate_unmasked_payload_size(source: str) -> str:
    old = """fn payload_size(&self) -> u32 {
        self.size & ADT_SIZE_MASK
    }"""
    new = """fn payload_size(&self) -> u32 {
        self.size
    }"""
    if source.count(old) != 1:
        fail(f"ADT payload-size normalization: expected one site, found {source.count(old)}")
    return source.replace(old, new, 1)


def compile_and_run(work: pathlib.Path, source: str, label: str) -> subprocess.CompletedProcess[str]:
    (work / "adt.rs").write_text(host_compatible(source) + VIEW_HELPER, encoding="utf-8")
    harness = work / f"{label}.rs"
    harness.write_text(TEMPLATE.read_text(encoding="utf-8"), encoding="utf-8")
    binary = work / label
    compiled = run(
        [
            "rustc",
            "--edition=2021",
            "--cfg",
            "adt_view_harness",
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
    if "panicked at" in result.stderr or "out of bounds" in result.stderr:
        fail(f"{label}: failure was not the deterministic harness diagnostic")


def main() -> int:
    if shutil.which("rustc") is None:
        fail("rustc is required")
    scratch = ROOT / "scratch"
    if not scratch.is_dir():
        fail("scratch directory is required")
    with tempfile.TemporaryDirectory(dir=scratch, prefix="adt-view-") as directory:
        work = pathlib.Path(directory)
        _original, before_0021, patched = materialize(work)

        negative = compile_and_run(work, before_0021, "before-0021")
        expect_failure(negative, "before-0021", "ADT property view length mismatch")

        baseline = compile_and_run(work, patched, "baseline")
        if baseline.returncode != 0:
            fail(f"baseline harness failed with exit {baseline.returncode}")

        header_mutation = compile_and_run(
            work, mutate_header_metadata(patched), "mutation-header-in-dst-metadata"
        )
        expect_failure(
            header_mutation,
            "mutation-header-in-dst-metadata",
            "ADT DST metadata includes the property header",
        )

        byte_mutation = compile_and_run(
            work, mutate_first_size_byte(patched), "mutation-first-size-byte"
        )
        expect_failure(
            byte_mutation,
            "mutation-first-size-byte",
            "ADT DST metadata read only the first size byte",
        )

        raw_size_mutation = compile_and_run(
            work, mutate_unmasked_payload_size(patched), "mutation-unmasked-payload-size"
        )
        expect_failure(
            raw_size_mutation,
            "mutation-unmasked-payload-size",
            "ADT flagged C getter length was not normalized",
        )
    print("ADT property view harness: pre-0021 control + unflagged/flagged baseline + three mutations passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(f"m1n1 ADT property view harness: ERROR: {exc}")
        raise SystemExit(1)
