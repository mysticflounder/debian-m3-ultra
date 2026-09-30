#!/usr/bin/env python3
"""ASan/UBSan regression for m1n1 SMP CPU-index validation.

The runner materializes the pinned source, applies patches 0001--0016 and
then 0017, extracts the actual SMP helpers and proxy cases into a small host
fixture, and executes boundary cases.  A first-16-patch build is also run as
a negative control: its INT_MIN indexed access must trip ASan/UBSan.  Only
host test binaries execute; firmware is not booted and MMIO uses mocks.
No VM or hardware configuration is changed.
"""

from __future__ import annotations

import hashlib
import pathlib
import re
import shutil
import subprocess
import tarfile
import tempfile
from typing import NoReturn

ROOT = pathlib.Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / "scratch/m1n1-cpu-audit/source.tar.gz"
PINNED_NAME = "m1n1-4184923ffb2dff079b384d6a32cc02142aa14572"
ARCHIVE_SHA256 = "6425983260ab96d55c36fdaab3b456830c3bd80f06b7759a61ed2bcca924d973"
PATCH_DIR = ROOT / "patches/m1n1"
TEMPLATE = ROOT / "tests/m1n1-smp-api-indices.c"


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


def extract_function(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        fail(f"missing function: {signature}")
    brace = source.find("{", start)
    if brace < 0:
        fail(f"missing function body: {signature}")
    depth = 0
    quote: str | None = None
    escaped = line_comment = block_comment = False
    for index in range(brace, len(source)):
        char = source[index]
        nxt = source[index + 1] if index + 1 < len(source) else ""
        if line_comment:
            if char == "\n":
                line_comment = False
        elif block_comment:
            if char == "*" and nxt == "/":
                block_comment = False
        elif quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
        elif char in "\"'":
            quote = char
        elif char == "/" and nxt == "/":
            line_comment = True
        elif char == "/" and nxt == "*":
            block_comment = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    fail(f"unterminated function: {signature}")


def extract_case(source: str, name: str) -> str:
    match = re.search(rf"^        case {re.escape(name)}:", source, re.MULTILINE)
    if match is None:
        fail(f"missing proxy case: {name}")
    end = re.search(r"^        (?:case |default:)", source[match.end():], re.MULTILINE)
    if end is None:
        fail(f"unterminated proxy case: {name}")
    return source[match.start():match.end() + end.start()]


def patch_paths(limit: int) -> list[pathlib.Path]:
    paths: list[pathlib.Path] = []
    for index in range(1, limit + 1):
        matches = sorted(PATCH_DIR.glob(f"{index:04d}-*.patch"))
        if len(matches) != 1:
            fail(f"missing/ambiguous patch {index:04d}: {matches}")
        paths.append(matches[0])
    return paths


def patch_input_paths(patches: list[pathlib.Path]) -> set[str]:
    paths = {"src/smp.c", "src/proxy.c", "src/smp.h", "src/proxy.h"}
    for patch in patches:
        text = patch.read_text(encoding="utf-8")
        for match in re.finditer(r"^(?:\+\+\+ b/|--- a/)(\S+)", text, re.MULTILINE):
            if match.group(1) != "/dev/null":
                paths.add(match.group(1))
    return paths


def materialize(work: pathlib.Path, limit: int) -> pathlib.Path:
    if hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() != ARCHIVE_SHA256:
        fail("pinned source archive hash mismatch")
    patches = patch_paths(limit)
    tree = work / f"m1n1-{limit}"
    paths = patch_input_paths(patches)
    with tarfile.open(ARCHIVE) as archive:
        for relative in sorted(paths):
            member = f"{PINNED_NAME}/{relative}"
            try:
                source = archive.extractfile(member)
            except KeyError:
                fail(f"source archive lacks {relative}")
            if source is None:
                fail(f"source archive entry is not a file: {relative}")
            data = source.read()
            destination = tree / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
    for index, patch in enumerate(patches):
        command = ["patch", "-p1", "--batch", "--forward", "-i", str(patch)]
        if index >= 14:
            command.insert(4, "--fuzz=0")
        result = run(command, cwd=tree)
        if result.returncode:
            fail(f"{patch.name} failed:\n{result.stdout}{result.stderr}")
    return tree


def fixture(tree: pathlib.Path) -> str:
    smp = (tree / "src/smp.c").read_text(encoding="utf-8")
    proxy = (tree / "src/proxy.c").read_text(encoding="utf-8")
    functions = "\n\n".join(extract_function(smp, signature) for signature in (
        "static bool smp_start_cpu(", "static void smp_stop_cpu(",
        "void smp_send_ipi(", "void smp_call4(", "u64 smp_wait(",
        "bool smp_is_alive(", "uint64_t smp_get_mpidr(",
        "u64 smp_get_release_addr(",
    ))
    cases = "\n".join(extract_case(proxy, name) for name in (
        "P_SMP_CALL", "P_SMP_CALL_SYNC", "P_SMP_WAIT", "P_SMP_IS_ALIVE",
        "P_SMP_CALL_EL1", "P_SMP_CALL_EL1_SYNC", "P_SMP_CALL_EL0",
        "P_SMP_CALL_EL0_SYNC",
    ))
    text = TEMPLATE.read_text(encoding="utf-8")
    return text.replace("/* INSERT_SMP_FUNCTIONS */", functions).replace(
        "/* INSERT_PROXY_CASES */", cases)


def compile_and_run(source: str, clang: str, work: pathlib.Path, name: str) -> subprocess.CompletedProcess[str]:
    source_path = work / f"{name}.c"
    binary = work / name
    source_path.write_text(source, encoding="utf-8")
    result = run([clang, "-std=gnu11", "-O1", "-g", "-fsanitize=address,undefined",
                  "-fno-omit-frame-pointer", str(source_path), "-o", str(binary)])
    if result.returncode:
        fail(f"{name} fixture did not compile:\n{result.stdout}{result.stderr}")
    return run([str(binary)], cwd=work)


def main() -> int:
    clang = shutil.which("clang")
    if clang is None:
        fail("clang is required")
    if not TEMPLATE.is_file() or not ARCHIVE.is_file():
        fail("fixture or pinned source archive is missing")
    with tempfile.TemporaryDirectory(prefix="m1n1-smp-api-", dir=ROOT / "scratch") as temporary:
        work = pathlib.Path(temporary)
        baseline_tree = materialize(work, 16)
        baseline = compile_and_run(fixture(baseline_tree), clang, work, "baseline")
        if baseline.returncode == 0:
            fail("unpatched first-16 fixture did not trip ASan/UBSan")
        if ("AddressSanitizer" not in baseline.stderr or
                "runtime error: index -2147483648 out of bounds" not in baseline.stderr):
            fail(f"negative control failed for an unexpected reason:\n{baseline.stderr}")
        patched_tree = materialize(work, 17)
        source = fixture(patched_tree)
        patched = compile_and_run(source, clang, work, "patched")
        if patched.returncode:
            fail(f"patched fixture failed:\n{patched.stdout}{patched.stderr}")
        print(patched.stdout.strip())
        sync_case = extract_case(source, "P_SMP_CALL_EL0_SYNC")
        if sync_case.count("reply->retval = smp_wait(cpu);") != 1:
            fail("EL0 synchronous result assignment missing/ambiguous")
        missing_result = source.replace(sync_case, sync_case.replace(
            "reply->retval = smp_wait(cpu);", "(void)smp_wait(cpu);"))
        if compile_and_run(missing_result, clang, work, "missing-result").returncode != 37:
            fail("missing EL0-sync result mutation was not detected by its regression case")
        ingress_guard = "if (request->args[0] >= MAX_CPUS)\n                break;"
        if source.count(ingress_guard) != 8:
            fail("expected exactly eight SMP proxy ingress guards")
        missing_ingress = source.replace(ingress_guard, "/* negative control: unchecked narrowing */")
        if compile_and_run(missing_ingress, clang, work, "unchecked-ingress").returncode != 40:
            fail("unchecked proxy narrowing mutation was not detected by its regression case")
    print("SMP API index regression passed; first-16 negative control tripped ASan")
    print("Missing EL0-sync result and unchecked proxy-narrowing mutations rejected")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HarnessError as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        raise SystemExit(1)
