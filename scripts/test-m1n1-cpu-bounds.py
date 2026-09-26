#!/usr/bin/env python3
"""Source-driven host regression for the bounded m1n1 CPU-capacity patch.

This test never builds or runs m1n1.  It copies the pinned source into a
temporary scratch directory, applies the local patch with ``patch(1)``, and
compiles the extracted ``hv_switch_cpu`` function with harmless host mocks
under AddressSanitizer/UBSan.  The kboot guard is compiled directly from the
guard expression extracted from the real ``dt_set_cpus`` source; the complete
kboot function is intentionally not linked because it requires firmware,
libfdt, and architecture-specific runtime state.
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
from typing import NoReturn


ROOT = pathlib.Path(__file__).resolve().parents[1]
PINNED = ROOT / "scratch/m1n1-cpu-audit/m1n1-4184923ffb2dff079b384d6a32cc02142aa14572"
PATCH = ROOT / "patches/m1n1/0001-expand-cpu-capacity-and-fix-bounds.patch"
CLANG = shutil.which("clang")
BASE_SHA256 = {
    "src/smp.h": "d4bd759b232d47930893c4d0fb90280935741929e4e4dca5a15654fb0a316c83",
    "src/kboot.c": "11294702663baab7a3e0d0c7ac426688d6dc39f8543ca8c3088bf5cdd4f5d926",
    "src/hv.c": "764adf7001dd94bdd017c57b70893c87369716bf0034e64f7bf70dc9a74cd1cd",
}


class HarnessError(RuntimeError):
    pass


def fail(message: str) -> NoReturn:
    raise HarnessError(message)


def run(command: list[str], *, cwd: pathlib.Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)


def require_file(path: pathlib.Path) -> str:
    if not path.is_file():
        fail(f"missing pinned source file: {path}")
    return path.read_text(encoding="utf-8")


def max_cpu(source: str, path: pathlib.Path) -> int:
    match = re.search(r"^#define\s+MAX_CPUS\s+(\d+)\s*$", source, re.MULTILINE)
    if not match:
        fail(f"MAX_CPUS definition shape changed in {path}")
    return int(match.group(1))


def require_max_el3(source: str) -> None:
    match = re.search(r"^#define\s+MAX_EL3_CPUS\s+(\d+)\s*$", source, re.MULTILINE)
    if not match:
        fail("MAX_EL3_CPUS definition missing or changed shape")
    if int(match.group(1)) != 4:
        fail(f"MAX_EL3_CPUS changed unexpectedly: {match.group(1)}")


def extract_function(source: str, signature: str, path: pathlib.Path) -> str:
    start = source.find(signature)
    if start < 0:
        fail(f"function signature missing in {path}: {signature}")
    brace = source.find("{", start)
    if brace < 0:
        fail(f"function body missing in {path}: {signature}")
    depth = 0
    in_string: str | None = None
    escaped = False
    in_line_comment = False
    in_block_comment = False
    index = brace
    while index < len(source):
        char = source[index]
        next_char = source[index + 1] if index + 1 < len(source) else ""
        if in_line_comment:
            if char == "\n":
                in_line_comment = False
        elif in_block_comment:
            if char == "*" and next_char == "/":
                in_block_comment = False
                index += 1
        elif in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == in_string:
                in_string = None
        elif char in ("\"", "'"):
            in_string = char
        elif char == "/" and next_char == "/":
            in_line_comment = True
            index += 1
        elif char == "/" and next_char == "*":
            in_block_comment = True
            index += 1
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
        index += 1
    fail(f"unterminated function body in {path}: {signature}")


def extract_fdt_guard(source: str) -> str:
    match = re.search(
        r"if\s*\(\s*(cpu\s*(?:>=|>)\s*MAX_CPUS)\s*\)\s*\n\s*bail_cleanup",
        source,
    )
    if not match:
        fail("dt_set_cpus MAX_CPUS guard shape changed")
    return match.group(1)


def compiler_flags() -> list[str]:
    if CLANG is None:
        fail("clang is required for the host harness")
    return [CLANG, "-std=c11", "-O1", "-g", "-fno-omit-frame-pointer", "-fsanitize=address,undefined"]


def compile_and_run(source: str, output: pathlib.Path, *, cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
    source_path = output.with_suffix(".c")
    source_path.write_text(source, encoding="utf-8")
    compiled = run(compiler_flags() + [str(source_path), "-o", str(output)], cwd=cwd)
    if compiled.returncode != 0:
        fail(f"clang failed for {source_path.name}:\n{compiled.stderr}")
    return run([str(output)], cwd=cwd)


def hv_harness(function: str, limit: int) -> str:
    return f'''#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#define MAX_CPUS {limit}
static bool hv_started_cpus[MAX_CPUS];
static int hv_want_cpu = -1;
static unsigned rendezvous_calls;
static void hv_rendezvous(void) {{ rendezvous_calls++; }}

{function}

int main(void)
{{
    const int cpus[] = {{-1, 0, 23, 24, 31, 32}};
    memset(hv_started_cpus, 1, sizeof(hv_started_cpus));
    for (unsigned i = 0; i < sizeof(cpus) / sizeof(cpus[0]); i++) {{
        bool expected = cpus[i] >= 0 && cpus[i] < MAX_CPUS;
        bool actual = hv_switch_cpu(cpus[i]);
        if (actual != expected)
            return 10 + (int)i;
    }}
    if (rendezvous_calls != 4 || hv_want_cpu != 31)
        return 20;
    hv_started_cpus[0] = false;
    if (hv_switch_cpu(0) || rendezvous_calls != 4 || hv_want_cpu != 31)
        return 21;
    return 0;
}}
'''


def bound_guard_harness(expression: str, limit: int, expected: list[bool]) -> str:
    expected_c = ", ".join("true" if value else "false" for value in expected)
    return f'''#include <stdbool.h>
#define MAX_CPUS {limit}
static bool reject_cpu(int cpu)
{{
    if ({expression})
        return true;
    return false;
}}
int main(void)
{{
    const int cpus[] = {{0, 23, 24, 31, 32}};
    const bool expected[] = {{{expected_c}}};
    for (unsigned i = 0; i < sizeof(cpus) / sizeof(cpus[0]); i++)
        if (reject_cpu(cpus[i]) != expected[i])
            return 30 + (int)i;
    return 0;
}}
'''


def apply_patch_copy(work: pathlib.Path) -> pathlib.Path:
    destination = work / "m1n1"
    # The audit checkout intentionally omits generated/binary assets (some are
    # dangling symlinks).  The patch scope is three source files, so copy only
    # those files into a source-shaped temporary tree.
    (destination / "src").mkdir(parents=True)
    for relative in ("src/smp.h", "src/kboot.c", "src/hv.c"):
        target = destination / relative
        target.write_bytes((PINNED / relative).read_bytes())
    applied = run(["patch", "-p1", "--batch", "--forward", "-i", str(PATCH)], cwd=destination)
    if applied.returncode != 0:
        fail(f"patch did not apply to pinned source:\n{applied.stdout}{applied.stderr}")
    return destination


def assert_patch_scope() -> None:
    patch_text = PATCH.read_text(encoding="utf-8")
    paths = set(re.findall(r"^diff --git a/([^ ]+) b/[^ ]+$", patch_text, re.MULTILINE))
    expected = {"src/smp.h", "src/kboot.c", "src/hv.c"}
    if paths != expected:
        fail(f"patch scope changed: {sorted(paths)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    if not PINNED.is_dir():
        fail(f"pinned source tree missing: {PINNED}")
    if not PATCH.is_file():
        fail(f"patch missing: {PATCH}")
    assert_patch_scope()
    for relative, expected_hash in BASE_SHA256.items():
        source_file = PINNED / relative
        require_file(source_file)
        if hashlib.sha256(source_file.read_bytes()).hexdigest() != expected_hash:
            fail(f"pinned source digest mismatch: {relative}")

    baseline_smp = require_file(PINNED / "src/smp.h")
    baseline_kboot = require_file(PINNED / "src/kboot.c")
    baseline_hv = require_file(PINNED / "src/hv.c")
    if max_cpu(baseline_smp, PINNED / "src/smp.h") != 24:
        fail("unexpected baseline MAX_CPUS; refusing to test wrong source")
    require_max_el3(baseline_smp)
    if "if (cpu > MAX_CPUS)" not in baseline_kboot:
        fail("unexpected baseline kboot guard; refusing to test wrong source")
    if "if (cpu > MAX_CPUS || cpu < 0 || !hv_started_cpus[cpu])" not in baseline_hv:
        fail("unexpected baseline hv guard; refusing to test wrong source")

    with tempfile.TemporaryDirectory(prefix="m1n1-cpu-bounds-", dir=ROOT / "scratch") as temporary:
        work = pathlib.Path(temporary)
        patched = apply_patch_copy(work)
        patched_smp = require_file(patched / "src/smp.h")
        patched_kboot = require_file(patched / "src/kboot.c")
        patched_hv = require_file(patched / "src/hv.c")
        if max_cpu(patched_smp, patched / "src/smp.h") != 32:
            fail("patch did not set MAX_CPUS to 32")
        require_max_el3(patched_smp)
        if "if (cpu >= MAX_CPUS)" not in patched_kboot:
            fail("patch did not install the half-open kboot bound")
        if "if (cpu >= MAX_CPUS || cpu < 0 || !hv_started_cpus[cpu])" not in patched_hv:
            fail("patch did not install the half-open hv bound")

        hv_function = extract_function(patched_hv, "bool hv_switch_cpu(int cpu)", patched / "src/hv.c")
        hv_result = compile_and_run(hv_harness(hv_function, 32), work / "hv-patched", cwd=work)
        if hv_result.returncode != 0:
            fail(f"patched hv_switch_cpu boundary test failed:\n{hv_result.stdout}{hv_result.stderr}")

        baseline_function = extract_function(baseline_hv, "bool hv_switch_cpu(int cpu)", PINNED / "src/hv.c")
        baseline_result = compile_and_run(hv_harness(baseline_function, 24), work / "hv-baseline", cwd=work)
        if baseline_result.returncode == 0 or not any(
            marker in baseline_result.stderr
            for marker in ("AddressSanitizer", "runtime error: index 24 out of bounds")
        ):
            fail("baseline hv_switch_cpu unexpectedly accepted MAX_CPUS without sanitizer failure")

        baseline_guard_match = re.search(r"if\s*\(\s*(cpu\s*>\s*MAX_CPUS)\s*\|\|", baseline_hv)
        if not baseline_guard_match:
            fail("baseline hv upper-bound guard shape changed")
        baseline_guard = baseline_guard_match.group(1)
        # This negative control compiles the exact old guard and records its
        # off-by-one behavior: with capacity 24, index 24 is not rejected.
        old_guard_result = compile_and_run(
            bound_guard_harness(baseline_guard, 24, [False, False, False, True, True]),
            work / "hv-old-guard",
            cwd=work,
        )
        if old_guard_result.returncode != 0:
            fail(f"old hv guard negative control did not reproduce its index-24 behavior:\n{old_guard_result.stderr}")

        kboot_function = extract_function(
            patched_kboot, "static int dt_set_cpus(void)", patched / "src/kboot.c"
        )
        guard = extract_fdt_guard(kboot_function)
        if guard != "cpu >= MAX_CPUS":
            fail(f"unexpected patched FDT guard: {guard}")
        fdt_result = compile_and_run(
            bound_guard_harness(guard, 32, [False, False, False, False, True]),
            work / "fdt-guard",
            cwd=work,
        )
        if fdt_result.returncode != 0:
            fail(f"source-derived FDT pruning-boundary test failed:\n{fdt_result.stdout}{fdt_result.stderr}")

    print("m1n1 CPU capacity harness passed: patched hv -1,0,23,24,31,32 and inactive CPU; kboot guard 0,23,24,31,32; EL3 unchanged")
    print("negative controls passed: old capacity-24 '>' guard accepts index 24; old full hv path trips sanitizer")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HarnessError as exc:
        print(f"m1n1 CPU capacity harness: ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
