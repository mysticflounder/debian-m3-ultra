#!/usr/bin/env python3
"""Run extracted dt_set_cpus() against the pinned J575d board DT.

This is a host-only test: SMP IDs and liveness are mocks, while the DT,
CPU ordering, six-cluster map, and AIC3 compatible are from the real board
source.  It performs no native boot, MMIO, or hardware validation.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
PINNED = ROOT / "scratch/m1n1-cpu-audit/m1n1-4184923ffb2dff079b384d6a32cc02142aa14572"
DT_ROOT = ROOT / "scratch/m1n1-board-dt"
TEMPLATE = ROOT / "tests/m1n1-board-handoff.c"
MANIFEST = ROOT / "docs/inventory/t6032-board-dt-sources-2026-09-26.json"
TOPOLOGY = ROOT / "docs/inventory/t6032-cpus-2026-09-26.json"
LIBFDT_SOURCES = (
    "fdt.c", "fdt_ro.c", "fdt_rw.c", "fdt_wip.c", "fdt_sw.c",
    "fdt_empty_tree.c", "fdt_strerror.c", "fdt_addresses.c", "fdt_overlay.c",
)


class HarnessError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise HarnessError(message)


def run(command: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=False)


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def manifest_entries() -> list[dict[str, str]]:
    if not MANIFEST.is_file():
        fail("board DTS source manifest missing")
    return json.loads(MANIFEST.read_text(encoding="utf-8"))["source_files"]


def fetch_closure() -> None:
    """Network-mutating mode; never used unless the caller passes --fetch."""
    for entry in manifest_entries():
        destination = DT_ROOT / entry["local"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        fetched = run(["curl", "--fail", "--location", entry["url"], "-o", str(destination)], ROOT)
        if fetched.returncode:
            fail(f"fetch failed for {entry['local']}:\n{fetched.stderr}")
        if sha256(destination) != entry["sha256"]:
            fail(f"fetched DTS closure SHA-256 mismatch: {entry['local']}")


def load_cpu_helper():
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("m1n1_cpu_handoff", ROOT / "scripts/test-m1n1-cpu-handoff.py")
    if spec is None or spec.loader is None:
        fail("could not load shared m1n1 handoff helper")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def resolve_dtc() -> str:
    preferred = pathlib.Path("/opt/homebrew/bin/dtc")
    dtc = str(preferred) if preferred.is_file() else shutil.which("dtc")
    if not dtc:
        fail("dtc 1.8.1 not found")
    return dtc


def validate_include_closure(entries: list[dict[str, str]]) -> None:
    """Ensure the manifest is exactly the recursively reachable DTS include set."""
    listed = {entry["local"] for entry in entries}
    discovered: set[str] = set()
    pending = ["t6032-j575d.dts"]
    include_re = re.compile(r"^\s*#include\s+[<\"]([^>\"]+)[>\"]")
    while pending:
        relative = pending.pop()
        if relative in discovered:
            continue
        discovered.add(relative)
        source = DT_ROOT / relative
        if not source.is_file():
            fail(f"include closure references missing file: {relative}")
        for line in source.read_text(encoding="utf-8").splitlines():
            match = include_re.match(line)
            if not match:
                continue
            include = match.group(1)
            candidate = (source.parent / include).relative_to(DT_ROOT) \
                if (source.parent / include).is_file() else pathlib.Path(include)
            candidate_name = candidate.as_posix()
            if candidate_name not in listed:
                fail(f"include closure file absent from manifest: {candidate_name}")
            pending.append(candidate_name)
    if discovered != listed:
        fail(f"manifest/recursive include mismatch: extra={sorted(listed - discovered)} "
             f"missing={sorted(discovered - listed)}")


def prepare_board_dt(work: pathlib.Path) -> pathlib.Path:
    entries = manifest_entries()
    validate_include_closure(entries)
    for entry in entries:
        path = DT_ROOT / entry["local"]
        if not path.is_file(): fail(f"missing DTS closure file {entry['local']}")
        if sha256(path) != entry["sha256"]:
            fail(f"DTS closure SHA-256 mismatch: {entry['local']}")
    board = DT_ROOT / "t6032-j575d.dts"
    out = work / "t6032-j575d.dtb"
    preprocessed = work / "t6032-j575d.pp.dts"
    include = DT_ROOT / "dt-bindings"
    command = ["clang", "-E", "-nostdinc", "-undef", "-D__DTS__",
               "-x", "assembler-with-cpp", "-I", str(DT_ROOT), "-I", str(include),
               str(board)]
    cpp = run(command, work)
    if cpp.returncode: fail(f"board DTS preprocessing failed:\n{cpp.stderr}")
    preprocessed.write_text(cpp.stdout, encoding="utf-8")
    dtc = resolve_dtc()
    compiled = run([dtc, "-@", "-I", "dts", "-O", "dtb", "-o", str(out), str(preprocessed)], work)
    if compiled.returncode: fail(f"board DTS compilation failed:\n{compiled.stdout}{compiled.stderr}")
    warnings = [line for line in compiled.stderr.splitlines() if "Warning (" in line]
    (work / "dtc-warning-summary.txt").write_text("\n".join(warnings) + "\n", encoding="utf-8")
    categories = sorted(set(re.findall(r"Warning \(([^)]+)\)", "\n".join(warnings))))
    print(f"board DTS compiled with {len(warnings)} warnings: {', '.join(categories) or 'none'}")
    return out


def validate_source_topology(board_dtb: pathlib.Path) -> None:
    """Compare DT-declared CPU ordinal/affinity fields with the source inventory."""
    decompiled = run([resolve_dtc(), "-I", "dtb", "-O", "dts", str(board_dtb)], ROOT)
    if decompiled.returncode:
        fail(f"could not decompile board DT for topology check:\n{decompiled.stderr}")
    inventory = json.loads(TOPOLOGY.read_text(encoding="utf-8"))["topology"]["affinity"]
    actual = []
    block_re = re.compile(r"(?ms)^\s*(?:cpu_[^:]+:\s+)?cpu@[0-9a-f]+\s*\{(.*?)^\s*\};")
    for body in block_re.findall(decompiled.stdout):
        if 'device_type = "cpu"' not in body:
            continue
        reg = re.search(r"reg = <0x([0-9a-f]+)\s+0x([0-9a-f]+)>;", body)
        compatible = re.search(r'compatible = "([^"]+)";', body)
        if not reg or not compatible:
            fail("board DT CPU node missing reg/compatible")
        high = int(reg.group(1), 16)
        mpidr = int(reg.group(2), 16)
        if high != 0 or mpidr & ~0x17fff:
            fail(f"CPU DT reg contains unknown bits: high={high:#x} low={mpidr:#x}")
        actual.append({"cluster": (mpidr >> 8) & 7, "core": mpidr & 0xff,
                       "die": (mpidr >> 11) & 0xf,
                       "compatible": compatible.group(1),
                       "type_bit": bool(mpidr & 0x10000)})
    if len(actual) != len(inventory):
        fail(f"board DT CPU count {len(actual)} != inventory {len(inventory)}")
    for cpu_id, (got, expected) in enumerate(zip(actual, inventory)):
        for field in ("cluster", "core", "die", "compatible"):
            if got[field] != expected[field]:
                fail(f"CPU {cpu_id} {field} {got[field]!r} != inventory {expected[field]!r}")
        expected_type_bit = expected["cluster_type"] == "P"
        if got["type_bit"] != expected_type_bit:
            fail(f"CPU {cpu_id} DT type bit {got['type_bit']!r} disagrees with {expected['cluster_type']}")
    print("board topology matches source inventory: 32 ordinals, two dies, 4E+6P+6P/die")


def main() -> int:
    if sys.argv[1:] == ["--fetch"]:
        fetch_closure()
        print(f"fetched and verified {len(manifest_entries())} pinned DTS closure files")
        return 0
    if sys.argv[1:]:
        fail("usage: test-m1n1-board-handoff.py [--fetch]")
    if shutil.which("clang") is None: fail("clang is required")
    if not TEMPLATE.is_file(): fail("board handoff C template missing")
    if not TOPOLOGY.is_file(): fail("source-declared CPU topology inventory missing")
    libdir = PINNED / "src/libfdt"
    if any(not (libdir / source).is_file() for source in LIBFDT_SOURCES):
        fail("pinned libfdt source is incomplete")
    with tempfile.TemporaryDirectory(prefix="m1n1-board-handoff-", dir=ROOT / "scratch") as temp:
        work = pathlib.Path(temp)
        board_dtb = prepare_board_dt(work)
        validate_source_topology(board_dtb)
        helper = load_cpu_helper()
        try:
            patched = helper.prepare_patched_source(
                work, (helper.CAPACITY_PATCH, helper.LEAK_PATCH), "capacity-and-leak-fix")
            function = helper.extract_function((patched / "src/kboot.c").read_text(encoding="utf-8"))
        except helper.HarnessError as exc:
            fail(str(exc))
        smp = (patched / "src/smp.h").read_text(encoding="utf-8")
        if not re.search(r"^#define\s+MAX_CPUS\s+32\s*$", smp, re.MULTILINE) or \
           not re.search(r"^#define\s+MAX_EL3_CPUS\s+4\s*$", smp, re.MULTILINE):
            fail("patched source does not retain MAX_CPUS=32/MAX_EL3_CPUS=4")
        template = TEMPLATE.read_text(encoding="utf-8")
        if template.count("/* INSERT_DT_SET_CPUS */") != 1:
            fail("C insertion marker missing or duplicated")
        generated = work / "handoff.c"
        generated.write_text(template.replace("/* INSERT_DT_SET_CPUS */", function), encoding="utf-8")
        binary = work / "handoff"
        compiled = run(["clang", "-std=c11", "-O1", "-g", "-fsanitize=address,undefined",
                        "-fno-sanitize-recover=all", "-include", "stdlib.h", "-I", str(libdir), str(generated),
                        *(str(libdir / source) for source in LIBFDT_SOURCES), "-o", str(binary)], work)
        if compiled.returncode: fail(f"clang failed:\n{compiled.stdout}{compiled.stderr}")
        completed = run([str(binary), str(board_dtb)], work)
        if completed.returncode:
            fail(f"board handoff scenarios failed ({completed.returncode}):\n{completed.stdout}{completed.stderr}")
        interesting = [line for line in completed.stdout.splitlines()
                       if line.startswith("board inventory") or line.startswith("board scenario")]
        print("\n".join(interesting))
    print("m1n1 board-DT handoff harness passed: pinned J575d six-cluster DT, 32 CPUs, dead CPU/cluster, mismatch")
    print("coverage is host libfdt + extracted patched dt_set_cpus; SMP IDs/liveness are mocks, no hardware claim")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HarnessError as exc:
        print(f"m1n1 board handoff: ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
