#!/usr/bin/env python3
"""Offline current-m1n1 handoff tests on the exact official J575d DT.

Compiles the pinned mainline DTS closure, checks its declared topology, and
executes the actual dt_set_cpus() with libfdt and mocked CPU liveness/addresses.
This is not dtbs_check, a kernel build, native execution, or MMIO qualification.
"""
from __future__ import annotations

import argparse
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
LINUX_REV = "602042bf29f6efde39cfb5fdd9289bf4854bc0c5"
BOARD = pathlib.Path("arch/arm64/boot/dts/apple/t6032-j575d.dts")
RAW_PREFIX = f"https://raw.githubusercontent.com/torvalds/linux/{LINUX_REV}/"
TEMPLATE = ROOT / "tests/m1n1-board-handoff.c"


def digest(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_helper(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load helper {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def closure(dt_root: pathlib.Path, manifest: dict) -> list[dict]:
    if manifest.get("repository") != "https://github.com/torvalds/linux" or \
            manifest.get("commit") != LINUX_REV:
        raise RuntimeError("expected the pinned official Linux source manifest")
    entries = manifest["source_files"]
    if not 1 <= len(entries) <= 50:
        raise RuntimeError("source closure exceeds the 50-file cap")
    listed = {}
    total = 0
    for entry in entries:
        local = pathlib.Path(entry["local"])
        if local.is_absolute() or ".." in local.parts or entry["local"] in listed:
            raise RuntimeError("unsafe or duplicate closure path")
        path = (dt_root / local).resolve()
        if not path.is_relative_to(dt_root) or not path.is_file():
            raise RuntimeError(f"missing closure file {local}")
        if entry["url"] != RAW_PREFIX + local.as_posix() or digest(path) != entry["sha256"]:
            raise RuntimeError(f"source provenance/hash mismatch: {local}")
        total += path.stat().st_size
        listed[entry["local"]] = path
    if total > 5 * 1024 * 1024:
        raise RuntimeError("source closure exceeds the 5-MiB cap")
    found, pending = set(), [BOARD.as_posix()]
    while pending:
        local = pending.pop()
        if local in found:
            continue
        if local not in listed:
            raise RuntimeError(f"unlisted source include {local}")
        found.add(local)
        source = listed[local]
        for include in re.findall(r'^\s*#include\s+[<"]([^>"]+)[>"]',
                                  source.read_text(encoding="utf-8"), re.M):
            candidates = [source.parent / include, dt_root / "include" / include]
            resolved = next((p.resolve() for p in candidates if p.is_file()), None)
            if resolved is None or not resolved.is_relative_to(dt_root):
                raise RuntimeError(f"missing/unsafe include {include}")
            pending.append(resolved.relative_to(dt_root).as_posix())
    if found != set(listed):
        raise RuntimeError("manifest is not the exact recursive include closure")
    return entries


def invoke(command: list[str], label: str, work: pathlib.Path,
           records: list[dict], expected_code: int = 0) -> subprocess.CompletedProcess[str]:
    env = {**os.environ, "ASAN_OPTIONS": "detect_leaks=0",
           "UBSAN_OPTIONS": "halt_on_error=1:print_stacktrace=1"}
    result = subprocess.run(command, cwd=work, env=env, text=True,
                            capture_output=True, timeout=60)
    stdout, stderr = work / f"{label}.stdout.log", work / f"{label}.stderr.log"
    stdout.write_text(result.stdout, encoding="utf-8")
    stderr.write_text(result.stderr, encoding="utf-8")
    records.append({"label": label, "argv": command, "returncode": result.returncode,
                    "expected_returncode": expected_code,
                    "sanitizer_environment": {key: env[key] for key in ("ASAN_OPTIONS", "UBSAN_OPTIONS")},
                    "stdout": stdout.name, "stderr": stderr.name,
                    "stdout_sha256": digest(stdout), "stderr_sha256": digest(stderr)})
    (work / "execution-manifest.json").write_text(json.dumps(records, indent=2) + "\n",
                                                 encoding="utf-8")
    if result.returncode != expected_code:
        raise RuntimeError(f"{label} exited {result.returncode}; retained evidence: {work}")
    if any(text in result.stdout + result.stderr for text in
           ("AddressSanitizer", "UndefinedBehaviorSanitizer", "runtime error:")):
        raise RuntimeError(f"{label} sanitizer failure; retained evidence: {work}")
    return result


def host_case(source: str, label: str, work: pathlib.Path, tree: pathlib.Path,
              helper, records: list[dict], expected_stderr: str | None = None):
    generated, binary = work / f"{label}.c", work / label
    generated.write_text(source, encoding="utf-8")
    libdir = tree / "src/libfdt"
    command = [shutil.which("clang"), "-std=c11", "-O1", "-g", "-Wall", "-Werror",
               "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
               "-fno-omit-frame-pointer", "-DBOARD_HANDOFF_STATIC_STACKS=1", "-include", "stdlib.h",
               "-I", str(libdir), str(generated),
               *(str(libdir / name) for name in helper.LIBFDT_SOURCES), "-o", str(binary)]
    invoke(command, label + "-compile", work, records)
    result = invoke([str(binary), str(work / "t6032-j575d.dtb")], label + "-run",
                    work, records, 0 if expected_stderr is None else 1)
    records[-1].update({"generated_source": generated.name,
                        "generated_source_sha256": digest(generated),
                        "binary": binary.name, "binary_sha256": digest(binary),
                        "expected_stderr": expected_stderr})
    (work / "execution-manifest.json").write_text(json.dumps(records, indent=2) + "\n",
                                                 encoding="utf-8")
    if expected_stderr is not None and result.stderr != expected_stderr:
        raise RuntimeError(f"{label} failed outside its exact designated assertions: {work}")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-tree", required=True, type=pathlib.Path)
    parser.add_argument("--dt-root", required=True, type=pathlib.Path)
    parser.add_argument("--manifest", required=True, type=pathlib.Path)
    args = parser.parse_args()
    tree, dt_root = args.source_tree.resolve(), args.dt_root.resolve()
    if shutil.which("clang") is None:
        raise RuntimeError("clang is required")
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    entries = closure(dt_root, manifest)
    board_helper = load_helper("board_handoff", ROOT / "scripts/test-m1n1-board-handoff.py")
    cpu_helper = load_helper("cpu_handoff", ROOT / "scripts/test-m1n1-cpu-handoff.py")
    header = (tree / "src/smp_asm.h").read_text(encoding="utf-8")
    for name, expected in (("MAX_CPUS", 32), ("MAX_EL3_CPUS", 4), ("SECONDARY_STACK_SIZE", 0x10000)):
        match = re.search(rf"(?m)^#define\s+{name}\s+(0x[0-9a-fA-F]+|\d+)\s*$", header)
        if match is None or int(match.group(1), 0) != expected:
            raise RuntimeError(f"source {name} differs from the fixture's reviewed contract")
    function = cpu_helper.extract_function((tree / "src/kboot.c").read_text(encoding="utf-8"))
    cleanup = "    free(pruned_phandles);\n    return 0;\n\nerr:"
    release = 'fdt_setprop_inplace_u64(dt, node, "cpu-release-addr", release_addr)'
    if function.count(cleanup) != 1 or function.count(release) != 1:
        raise RuntimeError("expected current-source CPU-map cleanup/release contract")
    template = TEMPLATE.read_text(encoding="utf-8")
    if template.count("/* INSERT_DT_SET_CPUS */") != 1:
        raise RuntimeError("fixture insertion marker missing/duplicated")
    work = pathlib.Path(tempfile.mkdtemp(prefix="m1n1-mainline-board-handoff.", dir=ROOT / "scratch"))
    records = []
    cpp = invoke([shutil.which("clang"), "-E", "-nostdinc", "-undef", "-D__DTS__",
                  "-x", "assembler-with-cpp", "-I", str(dt_root / "include"),
                  "-I", str(dt_root / BOARD.parent), str(dt_root / BOARD)], "cpp", work, records)
    preprocessed = work / "t6032-j575d.pp.dts"
    preprocessed.write_text(cpp.stdout, encoding="utf-8")
    invoke([board_helper.resolve_dtc(), "-@", "-I", "dts", "-O", "dtb", "-o",
            str(work / "t6032-j575d.dtb"), str(preprocessed)], "dtc", work, records)
    board_helper.validate_source_topology(work / "t6032-j575d.dtb")
    baseline_source = template.replace("/* INSERT_DT_SET_CPUS */", function)
    baseline = host_case(baseline_source, "baseline", work, tree, cpu_helper, records)
    expected_cases = ("alive32", "dead-cpu24", "dead-cluster5", "mismatch-cpu7")
    for name in expected_cases:
        if not re.search(rf"(?m)^board scenario\s+{name}\s", baseline.stdout):
            raise RuntimeError(f"baseline omitted scenario {name}")
    scenarios = (("alive32", 32), ("dead-cpu24", 31), ("dead-cluster5", 26))
    for label, mutated, allocations in (
            ("missing-cleanup", function.replace(cleanup, "    return 0;\n\nerr:"), 1),
            ("missing-release", function.replace(release, "0"), 0)):
        expected = "".join(f"{name}: result=0 nodes={live} map={live} allocations={allocations} expected={live}\n"
                           for name, live in scenarios) + baseline.stderr
        host_case(template.replace("/* INSERT_DT_SET_CPUS */", mutated), label,
                  work, tree, cpu_helper, records, expected)
    inputs = [TEMPLATE, pathlib.Path(__file__), args.manifest.resolve(),
              ROOT / "scripts/test-m1n1-board-handoff.py", ROOT / "scripts/test-m1n1-cpu-handoff.py",
              board_helper.TOPOLOGY, tree / "src/kboot.c", tree / "src/types.h", tree / "src/smp.h", tree / "src/smp_asm.h",
              *sorted((tree / "src/libfdt").glob("*.[ch]"))]
    snapshot = {"source_tree": str(tree), "dt_root": str(dt_root), "linux_revision": LINUX_REV,
                "source_files": entries,
                "inputs": [{"path": str(path), "sha256": digest(path)} for path in inputs],
                "dtb_sha256": digest(work / "t6032-j575d.dtb"),
                "preprocessed_sha256": digest(preprocessed),
                "scope": "source-extracted helper/libfdt + mocked SMP, no schema/kernel/native proof",
                "fixture_mode": "Static-stack mode preserves a synthetic caller reservation; whole-image reservation helper is not executed.",
                "host_abi_shim": "Fixture u64 is 64-bit unsigned long to match ELF-target uint64_t and %lx; macOS uint64_t is unsigned long long."}
    patch_sums = tree.parent / "PATCH_SHA256SUMS"
    if patch_sums.is_file():
        shutil.copy2(patch_sums, work / "PATCH_SHA256SUMS")
        snapshot["patch_manifest_sha256"] = digest(patch_sums)
    (work / "source-snapshot.json").write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")
    print("PASS: official J575d topology; four current-source handoff scenarios; two exact sanitized controls")
    print(f"Retained evidence: {work}")
    print("Scope: static-stack reservation preservation, not whole-image reservation execution or native boot")
    return 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"board handoff: {error}", file=sys.stderr)
        raise SystemExit(1)
