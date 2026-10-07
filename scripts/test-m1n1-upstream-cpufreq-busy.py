#!/usr/bin/env python3
"""Host-only busy-state tests for the reviewed m1n1 cpufreq source.

The source tree is supplied explicitly because this harness must test the
current full comparison tree, not silently materialize an older patch stack.
No native MMIO, firmware, VM, or hardware qualification is performed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "tests/m1n1-upstream-cpufreq-busy.c"


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def extracted_function(source: str, name: str) -> str:
    match = re.search(rf"(?:static\s+)?(?:[A-Za-z_][\w ]*?)\s+{name}\s*\([^;]*\)\s*\{{", source)
    if not match:
        raise RuntimeError(f"cannot find {name} in payload.c")
    start, depth, quote, escaped = match.start(), 0, None, False
    for i in range(match.end() - 1, len(source)):
        ch = source[i]
        if quote:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[start:i + 1]
    raise RuntimeError(f"unterminated {name}")


def source_defines(tree: pathlib.Path, cpufreq: str) -> str:
    soc, types, firmware = (read(tree / "src" / name)
                            for name in ("soc.h", "types.h", "firmware.h"))
    code = re.sub(r"/\*.*?\*/|//[^\n]*", "", cpufreq, flags=re.S)
    names = sorted(set(re.findall(r"\b(?:T\d{4}|S\d[A-Z0-9]*)\b", code)) |
                   {"T6031", "T6032"})
    result = []
    for name in names:
        match = re.search(rf"(?m)^#define {name}\s+[^\n]+", soc)
        if match is None:
            raise RuntimeError(f"missing source chip constant {name}")
        result.append(match.group(0))
    for name in ("BIT", "MASK", "GENMASK", "_FIELD_LSB", "FIELD_PREP", "FIELD_GET"):
        match = re.search(rf"(?m)^#define {name}\([^\n]+", types)
        if match is None:
            raise RuntimeError(f"missing source bit macro {name}")
        result.append(match.group(0))
    enum = re.search(r"(?ms)^enum fw_version \{.*?^\};", firmware)
    if enum is None:
        raise RuntimeError("missing source firmware enum")
    result.append(enum.group(0))
    return "\n".join(result)


def source_contract(cpufreq: str) -> tuple[str, str]:
    start = cpufreq.index("static int set_pstate")
    end = cpufreq.index("int cpufreq_init_cluster", start)
    helper = cpufreq[start:end]
    match = re.search(
        r"if\s*\(chip_id\s*==\s*T6032\s*&&\s*"
        r"poll64\s*\(\s*cluster->base\s*\+\s*CLUSTER_PSTATE\s*,\s*"
        r"CLUSTER_PSTATE_BUSY\s*,\s*0\s*,\s*CLUSTER_SWITCH_TIMEOUT\s*\)\s*<\s*0\s*\)\s*\{",
        helper, re.S)
    if match is None or helper.count("poll64(") != 2:
        raise RuntimeError("source set_pstate lacks the exact T6032 busy prewait")
    marker = match.group(0)
    if match.start() > helper.index("u64 val = read64"):
        raise RuntimeError("T6032 busy prewait is not before the initial read")
    return marker, helper


def make_source(tree: pathlib.Path) -> tuple[str, str, str]:
    cpufreq = read(tree / "src/cpufreq.c")
    payload = read(tree / "src/payload.c")
    marker, helper = source_contract(cpufreq)
    body = cpufreq[cpufreq.index("#define CLUSTER_PSTATE "):]
    # The mock layer uses these exact production constants before the source
    # body is inserted; move their source definitions above the mocks and
    # remove the duplicate lines from the inserted body.
    constants = re.findall(r"(?m)^#define (?:CLUSTER_|PMGR_)[^\n]+", body)
    body = re.sub(r"(?m)^#define (?:CLUSTER_|PMGR_)[^\n]+\n", "", body)
    caller = extracted_function(payload, "payload_run")
    start = caller.index("if (kernel && fdt) {")
    end = caller.index("mitigations_perform();", start) + len("mitigations_perform();")
    fragment = caller[start:end] + "\n    }"
    if fragment.count("cpufreq_init(") != 1 or fragment.count("smp_start_secondaries(") != 1:
        raise RuntimeError("payload cpufreq/SMP prefix changed")
    source = read(TEMPLATE)
    source = source.replace("/* INSERT_SOURCE_DEFINES */",
                           source_defines(tree, cpufreq) + "\n" + "\n".join(constants))
    source = source.replace("/* INSERT_CPUFREQ_SOURCE */", body)
    source = source.replace("/* INSERT_PAYLOAD_CPUFREQ_FRAGMENT */", fragment)
    if "INSERT_" in source:
        raise RuntimeError("fixture marker was not replaced")
    return source, marker, helper


def snapshot(tree: pathlib.Path, work: pathlib.Path) -> None:
    files = [tree / "src" / name for name in
             ("cpufreq.c", "payload.c", "proxy.c", "types.h", "soc.h", "firmware.h")]
    manifest = []
    for path in files:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        manifest.append(f"{digest}  {path.relative_to(tree)}")
    patch_sums = tree.parent / "PATCH_SHA256SUMS"
    if patch_sums.exists():
        manifest.append(f"PATCH_SHA256SUMS {hashlib.sha256(patch_sums.read_bytes()).hexdigest()}")
        shutil.copy2(patch_sums, work / "PATCH_SHA256SUMS")
    (work / "production-snapshot-sha256.txt").write_text("\n".join(manifest) + "\n", encoding="utf-8")
    (work / "source-tree.txt").write_text(str(tree) + "\n", encoding="utf-8")


def execute(source: str, label: str, work: pathlib.Path, clang: str,
            expected_failure: str | None = None) -> None:
    generated, binary = work / f"{label}.c", work / label
    generated.write_text(source, encoding="utf-8")
    env = {**os.environ, "ASAN_OPTIONS": "detect_leaks=0",
           "UBSAN_OPTIONS": "halt_on_error=1:print_stacktrace=1"}
    command = [clang, "-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
               "-Wno-missing-field-initializers", "-fno-omit-frame-pointer",
               "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
               str(generated), "-o", str(binary)]
    compiled = subprocess.run(command, cwd=work, env=env, text=True,
                              capture_output=True, timeout=60)
    (work / f"{label}-compile-stdout.log").write_text(compiled.stdout, encoding="utf-8")
    (work / f"{label}-compile-stderr.log").write_text(compiled.stderr, encoding="utf-8")
    (work / f"{label}-compile.log").write_text(compiled.stdout + compiled.stderr, encoding="utf-8")
    if compiled.returncode:
        raise RuntimeError(f"{label} compile failed; see retained compile log")
    result = subprocess.run([str(binary)], cwd=work, env=env, text=True,
                            capture_output=True, timeout=60)
    (work / f"{label}-stdout.log").write_text(result.stdout, encoding="utf-8")
    (work / f"{label}-stderr.log").write_text(result.stderr, encoding="utf-8")
    output = result.stdout + result.stderr
    (work / f"{label}.log").write_text(output, encoding="utf-8")
    manifest = {
        "label": label,
        "compile_argv": command,
        "run_argv": [str(binary)],
        "compile_returncode": compiled.returncode,
        "run_returncode": result.returncode,
        "expected_failure": expected_failure,
        "generated_source_sha256": sha256(generated),
        "binary_sha256": sha256(binary),
        "compile_stdout": f"{label}-compile-stdout.log",
        "compile_stderr": f"{label}-compile-stderr.log",
        "stdout": f"{label}-stdout.log",
        "stderr": f"{label}-stderr.log",
        "compile_stdout_sha256": sha256(work / f"{label}-compile-stdout.log"),
        "compile_stderr_sha256": sha256(work / f"{label}-compile-stderr.log"),
        "stdout_sha256": sha256(work / f"{label}-stdout.log"),
        "stderr_sha256": sha256(work / f"{label}-stderr.log"),
    }
    with (work / "execution-manifest.jsonl").open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(manifest, sort_keys=True) + "\n")
    sanitizer = any(x in output for x in ("AddressSanitizer", "UndefinedBehaviorSanitizer", "runtime error:"))
    if expected_failure is None:
        if result.returncode or sanitizer:
            raise RuntimeError(f"{label} fixture failed; see retained log")
        print(f"{label}: PASS")
    elif result.returncode != 1 or sanitizer or result.stderr != expected_failure + "\n":
        raise RuntimeError(f"{label} did not fail at its designated assertion; see retained log")
    else:
        print(f"{label}: designated assertion rejected (sanitizers clean)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-tree", required=True, type=pathlib.Path)
    args = parser.parse_args()
    tree = args.source_tree.resolve()
    if not (tree / "src/cpufreq.c").is_file():
        raise RuntimeError(f"not an m1n1 source tree: {tree}")
    clang = shutil.which("clang")
    if clang is None:
        raise RuntimeError("clang required for host fixtures")
    work = pathlib.Path(tempfile.mkdtemp(prefix="m1n1-upstream-cpufreq-busy.", dir=ROOT / "scratch"))
    source, marker, helper = make_source(tree)
    snapshot(tree, work)
    execute(source, "cpufreq-busy-baseline", work, clang)
    block_start = source.index("    " + marker)
    read_line = "    u64 val = read64(cluster->base + CLUSTER_PSTATE);"
    read_start = source.index(read_line, block_start)
    missing = source[:block_start] + source[read_start:]
    execute(missing, "cpufreq-busy-missing-prewait", work, clang,
            "T6032 equal busy state was not waited and reread")
    # The negative fixture places the read before the complete prewait block.
    block = source[block_start:read_start]
    reordered = source[:block_start] + read_line + "\n\n" + block + source[read_start + len(read_line):]
    execute(reordered, "cpufreq-busy-stale-read-order", work, clang,
            "T6032 prewait/read order mismatch")
    print(f"Retained reviewed source: {tree}")
    print(f"Retained host evidence: {work}")
    print("Scope: extracted cpufreq.c and payload prefix with host mocks; no hardware claims")
    return 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
