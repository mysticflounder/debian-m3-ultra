#!/usr/bin/env python3
"""Offline source-extracted ADT physical-span regression.

The pinned upstream tree and complete 21-patch host comparison stack are
materialized by the existing cpufreq runner.  This runner then applies the
two ADT patches with zero fuzz, source-scans the resulting Rust module for
unchecked global-ADT offset arithmetic, and runs exact-extent fixtures plus
the decoded J575d restore tree. The extracted boot-address helper also runs
against ASan/UBSan arithmetic fixtures. It never installs firmware or touches MMIO.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
PATCH_DIR = ROOT / "patches/m1n1/upstream-2460b60"
PHYSICAL_PATCHES = (
    PATCH_DIR / "0024-check-adt-physical-spans.patch",
    PATCH_DIR / "0025-check-adt-boot-relocation.patch",
)
TEMPLATE = ROOT / "tests/m1n1-adt-bounds.rs"
RESTORE = ROOT / "scratch/adt-j575d-decoded.bin"
REPORT_ROOT = ROOT / "scratch/adt-span-tests"
RESTORE_BYTES = 589140
RESTORE_SHA256 = "4a818ecc7f3d71195c1def12c6eed0c90b287f82cad2a6a4ffd6f0849fe13c12"
RELOCATION_TEMPLATE = ROOT / "tests/m1n1-adt-relocation.c"


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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
        timeout=120,
        env={**os.environ, "RUST_BACKTRACE": "1"},
    )


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def host_compatible(source: str) -> str:
    old = "use core::ffi::*;\n"
    new = "use core::ffi::{c_char, c_int, c_uint, c_void};\nuse core::ffi::CStr;\n"
    if source.count(old) != 1:
        fail("ADT source ffi import is not unique")
    source = source.replace(old, new, 1)
    old_name = "CStr::from_bytes_until_nul(&self.name)"
    if source.count(old_name) == 1:
        new_name = (
            "CStr::from_bytes_until_nul(unsafe { core::slice::from_raw_parts("
            "self.name.as_ptr() as *const u8, self.name.len()) })"
        )
        return source.replace(old_name, new_name, 1)
    # The physical-span patch may already have introduced a byte slice before
    # parsing the name; that form is host-compatible and needs no rewrite.
    if source.count("CStr::from_bytes_until_nul(name)") == 1:
        return source
    fail("ADT property name conversion site is not unique")


def apply_patch(tree: pathlib.Path, patch: pathlib.Path, log: list[str]) -> None:
    result = run(
        ["patch", "-p1", "--batch", "--forward", "--fuzz=0",
         "--no-backup-if-mismatch", "-i", str(patch)], tree
    )
    text = result.stdout + result.stderr
    log.append(f"{patch.name}: {text}")
    if result.returncode:
        fail(f"{patch.name} did not apply:\n{text}")


def materialize(report: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path, str, object]:
    if len(PHYSICAL_PATCHES) != 2 or len(set(PHYSICAL_PATCHES)) != 2:
        fail("expected exactly two unique physical-bound patches")
    if not TEMPLATE.is_file() or not RESTORE.is_file() or not RELOCATION_TEMPLATE.is_file():
        fail("ADT bounds template or decoded restore fixture is missing")
    if RESTORE.stat().st_size != RESTORE_BYTES or sha256(RESTORE) != RESTORE_SHA256:
        fail("decoded J575d restore fixture size or SHA-256 mismatch")
    cpufreq = load("reviewed_cpufreq_materializer", "test-m1n1-upstream-cpufreq.py")
    tree, work, _before, _memory, smp = cpufreq.materialize()
    patch_log: list[str] = [f"retained tree: {tree}\n"]
    for patch in PHYSICAL_PATCHES:
        apply_patch(tree, patch, patch_log)
    if any(tree.rglob("*.rej")):
        fail("patch reject artifacts remain in reviewed tree")

    source_path = tree / "rust/src/adt.rs"
    if not source_path.is_file():
        fail("materialized Rust ADT source is missing")
    source = source_path.read_text(encoding="utf-8")
    if re.search(r"\badt\s*\.\s*add\s*\(", source):
        fail("raw global adt.add remains after physical-span patch")
    if re.search(r"\.sub\s*\(\s*adt\s+as\s+usize", source):
        fail("raw pointer subtraction from global adt remains after patch")
    if source.count("fn adt_range(") != 1 or source.count("fn node_from_c_offset(") != 1:
        fail("expected centralized ADT range/node gates are missing")
    if "debug_putc" in smp.extract_function((tree / "src/startup.c").read_text(encoding="utf-8"), "adt_boot_address"):
        fail("relocation helper unexpectedly contains UART reporting")

    (report / "adt.rs").write_text(host_compatible(source), encoding="utf-8")
    (report / "harness.rs").write_text(TEMPLATE.read_text(encoding="utf-8"), encoding="utf-8")
    shutil.copy2(RESTORE, report / RESTORE.name)
    (report / "patch.log").write_text("".join(patch_log), encoding="utf-8")
    manifest = {
        "tree": str(tree),
        "patches": [p.name for p in PHYSICAL_PATCHES],
        "patch_count": 23,
        "comparison_stack_count": 21,
        "adt_sha256": sha256(source_path),
        "adt_lines": len(source.splitlines()),
        "restore_sha256": sha256(RESTORE),
        "restore_bytes": RESTORE.stat().st_size,
        "comparison_stack_log": str(work / "dvfs-patch.log"),
        "scope": "Rust ADT host fixtures and sanitized C relocation arithmetic; no native/MMIO/firmware/VM qualification",
    }
    (report / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return tree, work, source, smp


def compile_and_run(report: pathlib.Path, source: str, label: str = "adt-bounds",
                    expected_failure: str | None = None) -> None:
    rustc = shutil.which("rustc")
    if rustc is None:
        fail("rustc is required")
    report.mkdir(parents=True, exist_ok=True)
    (report / "adt.rs").write_text(host_compatible(source), encoding="utf-8")
    (report / "harness.rs").write_text(TEMPLATE.read_text(encoding="utf-8"), encoding="utf-8")
    shutil.copy2(RESTORE, report / RESTORE.name)
    binary = report / label
    compiled = run(
        [rustc, "--edition=2021", "--cfg", "adt_bounds_harness", "-C", "debuginfo=1",
         "-C", "opt-level=0", "-C", "overflow-checks=yes", "harness.rs", "-o", str(binary)],
        report,
    )
    (report / "compile.log").write_text(compiled.stdout + compiled.stderr, encoding="utf-8")
    if compiled.returncode:
        fail(f"Rust ADT bounds harness failed to compile; see {report / 'compile.log'}")
    result = run([str(binary)], report)
    output = result.stdout + result.stderr
    (report / "run.log").write_text(output, encoding="utf-8")
    if expected_failure is not None:
        if result.returncode != 1 or expected_failure not in output or "panicked at" in output:
            fail(f"{label} did not produce its deterministic designated failure; see {report / 'run.log'}")
        print(f"{label}: designated guard mutation rejected (no panic)")
        return
    if result.returncode != 0:
        fail(f"Rust ADT bounds harness exited {result.returncode}; see {report / 'run.log'}")
    if "panicked at" in output:
        fail("Rust ADT bounds harness panicked")
    print(output.strip())


def source_mutation(source: str, old: str, new: str, label: str) -> str:
    if source.count(old) != 1:
        fail(f"{label}: mutation seam missing or ambiguous")
    return source.replace(old, new, 1)


def run_rust_guard_controls(report: pathlib.Path, source: str) -> None:
    controls = (
        (
            "missing-extent-guard",
            "if extent > isize::MAX as usize || offset > extent || len > extent - offset {",
            "if false {",
            "FAIL: constructor lower-bound accepted property at exact eight-byte extent",
        ),
        (
            "missing-property-padding-guard",
            "let _ = adt_range(offset, record_len)?;",
            "let _ = adt_range(offset, ADT_PROPERTY_HEADER_SIZE)?;",
            "FAIL: one-byte-short payload",
        ),
        (
            "missing-bounded-path-guard",
            "if n_offs == ADT_MAX_DEPTH {",
            "if false && n_offs == ADT_MAX_DEPTH {",
            "FAIL: unterminated depth-8 path",
        ),
    )
    for label, old, new, diagnostic in controls:
        mutated = source_mutation(source, old, new, label)
        compile_and_run(report / label, mutated, label, diagnostic)


def relocation_fixture(tree: pathlib.Path, report: pathlib.Path, smp) -> str:
    report.mkdir(parents=True, exist_ok=True)
    startup = (tree / "src/startup.c").read_text(encoding="utf-8")
    helper = smp.extract_function(startup, "adt_boot_address")
    if helper.count("adt_boot_address") != 1:
        fail("source-extracted ADT relocation helper is missing or ambiguous")
    header = (tree / "src/xnuboot.h").read_text(encoding="utf-8")
    (report / "xnuboot.h").write_text(header, encoding="utf-8")
    fixture = RELOCATION_TEMPLATE.read_text(encoding="utf-8")
    if fixture.count("/* ADT_RELOCATION_SOURCE */") != 1:
        fail("ADT relocation fixture marker is missing or ambiguous")
    fixture = fixture.replace("/* ADT_RELOCATION_SOURCE */", helper, 1)
    return fixture


def c_run(report: pathlib.Path, source: str, label: str, args: tuple[str, ...] = (),
          expected_failure: str | None = None) -> None:
    clang = shutil.which("clang")
    if clang is None:
        fail("clang is required for relocation fixture")
    report.mkdir(parents=True, exist_ok=True)
    header = report / "xnuboot.h"
    if not header.is_file() and (report.parent / "xnuboot.h").is_file():
        shutil.copy2(report.parent / "xnuboot.h", header)
    generated = report / f"{label}.c"
    binary = report / label
    generated.write_text(source, encoding="utf-8")
    env = {**os.environ, "ASAN_OPTIONS": "detect_leaks=0",
           "UBSAN_OPTIONS": "halt_on_error=1:print_stacktrace=1"}
    compiled = subprocess.run(
        [clang, "-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
         "-fno-omit-frame-pointer", "-fsanitize=address,undefined",
         "-fno-sanitize-recover=all", "-I", str(report), str(generated), "-o", str(binary)],
        cwd=report, env=env, text=True, capture_output=True, check=False, timeout=120,
    )
    (report / "compile.log").write_text(compiled.stdout + compiled.stderr, encoding="utf-8")
    if compiled.returncode:
        fail(f"{label} relocation fixture failed to compile; see {report / 'compile.log'}")
    result = subprocess.run([str(binary), *args], cwd=report, env=env,
                            text=True, capture_output=True, check=False, timeout=120)
    output = result.stdout + result.stderr
    (report / "run.log").write_text(output, encoding="utf-8")
    sanitizer = any(token in output for token in ("AddressSanitizer", "UndefinedBehaviorSanitizer", "runtime error:"))
    if expected_failure is not None:
        if result.returncode != 1 or expected_failure not in output or sanitizer:
            fail(f"{label} did not produce designated clean failure; see {report / 'run.log'}")
        print(f"{label}: designated guard mutation rejected (sanitizers clean)")
        return
    if result.returncode or sanitizer:
        fail(f"{label} relocation fixture failed; see {report / 'run.log'}")
    print(f"{label}: PASS; log: {report / 'run.log'}")


def run_relocation_controls(tree: pathlib.Path, report: pathlib.Path, smp) -> None:
    source = relocation_fixture(tree, report, smp)
    c_run(report, source, "relocation-baseline")
    c_run(
        report / "missing-min-header-guard", source_mutation(
            source,
            "if (ba->devtree_size < sizeof(struct adt_node_hdr) || virtual_address < ba->virt_base)",
            "if (virtual_address < ba->virt_base)",
            "missing-min-header-guard",
        ),
        "missing-min-header-guard", ("short-node",), "FAIL: ADT relocation short-node",
    )
    c_run(
        report / "unchecked-physical-relocation", source_mutation(
            source,
            "__builtin_add_overflow(ba->phys_base, virtual_address - ba->virt_base,\n                               &physical_address)",
            "((physical_address = ba->phys_base + virtual_address - ba->virt_base), false)",
            "unchecked-physical-relocation",
        ),
        "unchecked-physical-relocation", ("physical-relocation-overflow",),
        "FAIL: ADT relocation physical-relocation-overflow",
    )
    c_run(
        report / "missing-physical-span-guard", source_mutation(
            source,
            "__builtin_add_overflow(physical_address, (u64)ba->devtree_size, &physical_end)",
            "((physical_end = physical_address + (u64)ba->devtree_size), false)",
            "missing-physical-span-guard",
        ),
        "missing-physical-span-guard", ("physical-span-overflow",),
        "FAIL: ADT relocation physical-span-overflow",
    )
    c_run(
        report / "missing-virtual-span-guard", source_mutation(
            source,
            "__builtin_add_overflow(virtual_address, (u64)ba->devtree_size, &virtual_end)",
            "((virtual_end = virtual_address + (u64)ba->devtree_size), false)",
            "missing-virtual-span-guard",
        ),
        "missing-virtual-span-guard", ("virtual-span-overflow",),
        "FAIL: ADT relocation virtual-span-overflow",
    )


def main() -> int:
    REPORT_ROOT.mkdir(parents=True, exist_ok=True)
    report = pathlib.Path(tempfile.mkdtemp(prefix="run-", dir=REPORT_ROOT))
    tree, work, source, smp = materialize(report)
    compile_and_run(report, source)
    run_rust_guard_controls(report, source)
    run_relocation_controls(tree, report / "relocation", smp)
    print(f"Retained reviewed source: {tree}")
    print(f"Retained ADT bounds artifacts: {report}")
    print(f"Materializer work/logs: {work}")
    print("Scope: declared ADT extents, C ABI wrappers and relocation arithmetic; physical mapping/lifetime/aliasing remain separate")
    return 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"m1n1 ADT bounds: ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
