#!/usr/bin/env python3
"""ASan/UBSan regression for MMU/HV CPU-index and proxy sentinel guards.

The fixture is built from actual helper bodies and proxy cases extracted from
the pinned source plus patch 0018.  A first-17 negative control executes only
the old ``hv_exit_cpu(INT_MIN)`` path, proving that its failure is specific to
that unchecked direct helper. Only host test binaries execute; firmware is
not booted and MMIO uses mocks. No VM or hardware configuration is changed.
"""

from __future__ import annotations

import hashlib
import importlib.util
import pathlib
import re
import shutil
import subprocess
import tarfile
import tempfile
from typing import NoReturn

ROOT = pathlib.Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / "scratch/m1n1-cpu-audit/source.tar.gz"
PATCH18 = ROOT / "patches/m1n1/0018-validate-mmu-hv-cpu-indices.patch"
TEMPLATE = ROOT / "tests/m1n1-hv-api-indices.c"
ARCHIVE_SHA256 = "6425983260ab96d55c36fdaab3b456830c3bd80f06b7759a61ed2bcca924d973"


class HarnessError(RuntimeError):
    pass


def fail(message: str) -> NoReturn:
    raise HarnessError(message)


def run(command: list[str], *, cwd: pathlib.Path | None = None) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, check=False, timeout=30)
    except subprocess.TimeoutExpired:
        fail(f"subprocess timed out after 30s: {command[0]}")


def load_previous():
    path = ROOT / "scripts/test-m1n1-smp-api-indices.py"
    spec = importlib.util.spec_from_file_location("smp_api_indices", path)
    if spec is None or spec.loader is None:
        fail("unable to load prior source materializer")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def ensure_sources(tree: pathlib.Path) -> None:
    needed = ("src/memory.c", "src/hv.c", "src/hv_wdt.c", "src/proxy.c")
    with tarfile.open(ARCHIVE) as archive:
        for relative in needed:
            destination = tree / relative
            if destination.is_file():
                continue
            member = f"m1n1-4184923ffb2dff079b384d6a32cc02142aa14572/{relative}"
            source = archive.extractfile(member)
            if source is None:
                fail(f"source archive lacks {relative}")
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(source.read())


def materialize(work: pathlib.Path, patched: bool) -> pathlib.Path:
    previous = load_previous()
    tree = previous.materialize(work, 17)
    ensure_sources(tree)
    if patched:
        if not PATCH18.is_file():
            fail("patch 0018 is missing")
        result = run(["patch", "-p1", "--batch", "--forward", "--fuzz=0",
                      "-i", str(PATCH18)], cwd=tree)
        if result.returncode:
            fail(f"patch 0018 failed:\n{result.stdout}{result.stderr}")
    return tree


def fixture(tree: pathlib.Path) -> str:
    previous = load_previous()
    helpers = []
    for relative, signature in (
        ("src/memory.c", "void mmu_init_secondary("),
        ("src/hv.c", "void hv_start_secondary("),
        ("src/hv_wdt.c", "void hv_wdt_start("),
        ("src/hv.c", "void hv_pin_cpu("),
        ("src/hv.c", "void hv_exit_cpu("),
        ("src/hv.c", "bool hv_switch_cpu("),
    ):
        helpers.append(previous.extract_function((tree / relative).read_text(encoding="utf-8"), signature))
    proxy = (tree / "src/proxy.c").read_text(encoding="utf-8")
    proxy_header = (tree / "src/proxy.h").read_text(encoding="utf-8")
    opcode_enum = re.search(r"typedef enum \{.*?\} ProxyOp;", proxy_header, re.S)
    if opcode_enum is None:
        fail("pinned proxy opcode enum is missing")
    definitions = []
    for relative, name in (("src/smp.h", "MAX_CPUS"), ("src/hv_wdt.c", "WDT_TIMEOUT")):
        source = (tree / relative).read_text(encoding="utf-8")
        matches = re.findall(rf"^#define\s+{name}\s+[^\n]+", source, re.M)
        if len(matches) != 1:
            fail(f"missing/ambiguous source definition: {name}")
        definitions.append(matches[0])
    cases = "\n".join(previous.extract_case(proxy, name) for name in (
        "P_MMU_INIT_SECONDARY", "P_HV_WDT_START", "P_HV_START_SECONDARY",
        "P_HV_SWITCH_CPU", "P_HV_PIN_CPU", "P_HV_EXIT_CPU",
    ))
    template = TEMPLATE.read_text(encoding="utf-8")
    for marker in ("INSERT_HELPERS", "INSERT_PROXY_CASES", "INSERT_SOURCE_DEFINES", "INSERT_PROXY_OPS"):
        if template.count(f"/* {marker} */") != 1:
            fail(f"missing/ambiguous fixture marker: {marker}")
    return template.replace(
        "/* INSERT_HELPERS */", "\n\n".join(helpers)).replace(
        "        /* INSERT_PROXY_CASES */", cases).replace(
        "/* INSERT_SOURCE_DEFINES */", "\n".join(definitions)).replace(
        "/* INSERT_PROXY_OPS */", opcode_enum.group(0))


def compile_fixture(source: str, clang: str, work: pathlib.Path, name: str,
                    extra: list[str] | None = None) -> subprocess.CompletedProcess[str]:
    source_path = work / f"{name}.c"
    binary = work / f"{name}-bin"
    source_path.write_text(source, encoding="utf-8")
    command = [clang, "-std=gnu11", "-O1", "-g", "-fsanitize=address,undefined",
               "-fno-omit-frame-pointer"]
    command.extend(extra or [])
    command.extend([str(source_path), "-o", str(binary)])
    result = run(command)
    if result.returncode:
        fail(f"{name} fixture did not compile:\n{result.stdout}{result.stderr}")
    return run([str(binary)], cwd=work)


def expect_bad_exit(result: subprocess.CompletedProcess[str], name: str) -> None:
    if (result.returncode == 0 or "AddressSanitizer" not in result.stderr or
            "runtime error: index -2147483648 out of bounds" not in result.stderr):
        fail(f"{name} did not produce the specific hv_exit_cpu(INT_MIN) failure:\n{result.stderr}")


def expect_case_failure(result: subprocess.CompletedProcess[str], code: int, name: str) -> None:
    if (result.returncode != code or "AddressSanitizer" in result.stderr or
            "runtime error:" in result.stderr):
        fail(f"{name} was not rejected by its designated case ({code}):\n{result.stderr}")


def mutations(source: str, clang: str, work: pathlib.Path) -> None:
    previous = load_previous()
    pin = previous.extract_case(source, "P_HV_PIN_CPU")
    sentinel = "raw_cpu == (u64)-1 ? -1 : (int)raw_cpu"
    if pin.count(sentinel) != 1:
        fail("pin sentinel conversion missing/ambiguous")
    wrong_pin = source.replace(pin, pin.replace(sentinel, "raw_cpu == (u64)-1 ? 0 : (int)raw_cpu"))
    expect_case_failure(compile_fixture(wrong_pin, clang, work, "wrong-unpin"), 70, "wrong unpin")

    mmu = previous.extract_case(source, "P_MMU_INIT_SECONDARY")
    ingress = "if (raw_cpu >= MAX_CPUS)\n                break;"
    if mmu.count(ingress) != 1:
        fail("MMU proxy ingress guard missing/ambiguous")
    unchecked = source.replace(mmu, mmu.replace(ingress, "/* unchecked narrowing mutation */"))
    expect_case_failure(compile_fixture(unchecked, clang, work, "unchecked-mmu"), 60, "unchecked MMU")

    exit_helper = previous.extract_function(source, "void hv_exit_cpu(")
    guard = "if (cpu < 0 || cpu >= MAX_CPUS)\n        return;"
    if exit_helper.count(guard) != 1:
        fail("resolved exit guard missing/ambiguous")
    unchecked_exit = source.replace(exit_helper, exit_helper.replace(guard, "/* unchecked exit mutation */"))
    expect_bad_exit(compile_fixture(unchecked_exit, clang, work, "unchecked-exit",
                                   ["-DNEGATIVE_HV_EXIT"]), "unchecked exit mutation")


def main() -> int:
    clang = shutil.which("clang")
    if clang is None:
        fail("clang is required")
    if not ARCHIVE.is_file() or hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() != ARCHIVE_SHA256:
        fail("pinned source archive hash mismatch")
    with tempfile.TemporaryDirectory(prefix="m1n1-hv-api-", dir=ROOT / "scratch") as temporary:
        work = pathlib.Path(temporary)
        baseline = compile_fixture(fixture(materialize(work / "baseline", False)), clang,
                                   work, "baseline", ["-DNEGATIVE_HV_EXIT"])
        expect_bad_exit(baseline, "first-17 negative control")
        source = fixture(materialize(work / "patched", True))
        patched = compile_fixture(source, clang, work, "patched")
        if patched.returncode or "AddressSanitizer" in patched.stderr or "runtime error:" in patched.stderr:
            fail(f"patched fixture failed:\n{patched.stdout}{patched.stderr}")
        print(patched.stdout.strip())
        mutations(source, clang, work)
    print("MMU/HV API index and proxy sentinel regression passed; hv_exit negative control tripped ASan")
    print("Wrong unpin, unchecked MMU narrowing and missing exit-guard mutations rejected")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HarnessError as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        raise SystemExit(1)
