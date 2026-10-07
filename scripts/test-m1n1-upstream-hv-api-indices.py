#!/usr/bin/env python3
"""Run the existing MMU/HV index fixture against reviewed upstream helpers.

Only host mock binaries execute. The source archive and adapted patch order
come from the upstream SMP materializer. The guarded fixture exercises real
current helper bodies and proxy cases; three safe mutations exercise sentinel
and raw-ingress behavior without removing a direct array bounds guard.
"""

from __future__ import annotations

import importlib.util
import pathlib
import re
import shutil
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fixture(tree: pathlib.Path, hv) -> str:
    previous = hv.load_previous()
    helpers = []
    for relative, signature in (
        ("src/memory.c", "void mmu_init_secondary("),
        ("src/hv/hv.c", "void hv_start_secondary("),
        ("src/hv/hv_wdt.c", "void hv_wdt_start("),
        ("src/hv/hv.c", "void hv_pin_cpu("),
        ("src/hv/hv.c", "void hv_exit_cpu("),
        ("src/hv/hv.c", "bool hv_switch_cpu("),
    ):
        helpers.append(previous.extract_function(
            (tree / relative).read_text(encoding="utf-8"), signature))
    proxy = (tree / "src/proxy.c").read_text(encoding="utf-8")
    header = (tree / "src/proxy.h").read_text(encoding="utf-8")
    opcode_enum = re.search(r"typedef enum \{.*?\} ProxyOp;", header, re.S)
    if opcode_enum is None:
        raise RuntimeError("current proxy opcode enum missing")
    definitions = []
    for relative, name in (
        ("src/smp_asm.h", "MAX_CPUS"),
        ("src/hv/hv_wdt.c", "WDT_TIMEOUT"),
    ):
        text = (tree / relative).read_text(encoding="utf-8")
        matches = re.findall(rf"^#define\s+{name}\s+[^\n]+", text, re.M)
        if len(matches) != 1:
            raise RuntimeError(f"missing/ambiguous current define {name}")
        definitions.append(matches[0])
    cases = "\n".join(previous.extract_case(proxy, name) for name in (
        "P_MMU_INIT_SECONDARY", "P_HV_WDT_START", "P_HV_START_SECONDARY",
        "P_HV_SWITCH_CPU", "P_HV_PIN_CPU", "P_HV_EXIT_CPU",
    ))
    source = hv.TEMPLATE.read_text(encoding="utf-8")
    for marker, replacement in (
        ("INSERT_HELPERS", "\n\n".join(helpers)),
        ("INSERT_PROXY_CASES", cases),
        ("INSERT_SOURCE_DEFINES", "\n".join(definitions)),
        ("INSERT_PROXY_OPS", opcode_enum.group(0)),
    ):
        token = f"/* {marker} */"
        if source.count(token) != 1:
            raise RuntimeError(f"fixture marker missing/ambiguous: {marker}")
        if marker == "INSERT_PROXY_CASES":
            token = "        " + token
        source = source.replace(token, replacement)
    return source


def mutations(source: str, hv, clang: str, work: pathlib.Path) -> None:
    previous = hv.load_previous()
    sentinel = "raw_cpu == (u64)-1 ? -1 : (int)raw_cpu"
    for case, code in (("P_HV_PIN_CPU", 70), ("P_HV_EXIT_CPU", 71)):
        body = previous.extract_case(source, case)
        if body.count(sentinel) != 1:
            raise RuntimeError(f"missing/ambiguous sentinel conversion in {case}")
        mutated = source.replace(body, body.replace(
            sentinel, "raw_cpu == (u64)-1 ? 0 : (int)raw_cpu"))
        result = hv.compile_fixture(mutated, clang, work, f"wrong-{case.lower()}")
        hv.expect_case_failure(result, code, case)
    body = previous.extract_case(source, "P_MMU_INIT_SECONDARY")
    guard = "if (request->args[0] >= MAX_CPUS)\n                break;"
    if body.count(guard) != 1:
        raise RuntimeError("missing/ambiguous raw MMU ingress guard")
    mutated = source.replace(body, body.replace(guard, "/* unchecked narrowing control */"))
    result = hv.compile_fixture(mutated, clang, work, "unchecked-mmu-ingress")
    hv.expect_case_failure(result, 60, "MMU raw ingress")


def main() -> int:
    smp = load("reviewed_smp_materializer", "test-m1n1-upstream-smp.py")
    hv = load("pinned_hv_fixture_helpers", "test-m1n1-hv-api-indices.py")
    clang = shutil.which("clang")
    if clang is None:
        raise RuntimeError("clang required for host fixture")
    tree = smp.materialize()
    work = pathlib.Path(tempfile.mkdtemp(prefix="upstream-hv-indices-", dir=ROOT / "scratch"))
    source = fixture(tree, hv)
    result = hv.compile_fixture(source, clang, work, "guarded-upstream")
    if result.returncode or "AddressSanitizer" in result.stderr or "runtime error:" in result.stderr:
        raise RuntimeError(f"guarded upstream fixture failed:\n{result.stdout}{result.stderr}")
    mutations(source, hv, clang, work)
    print(result.stdout.strip())
    print("Three safe raw-ingress/sentinel mutation controls rejected")
    print(f"Retained reviewed source: {tree}")
    print(f"Retained host fixture evidence: {work}")
    return 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
