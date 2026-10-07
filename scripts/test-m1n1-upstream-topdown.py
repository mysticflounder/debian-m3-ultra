#!/usr/bin/env python3
"""Source-extracted tests for coordinated top-down memory reservations.

The fixture uses the pinned heapblock implementation and real malloc-backed
storage.  Only bootargs, panic and printing cross the host boundary.  Cases
run in separate processes so production static guard state is not reset by a
test-only helper.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
REV = "2460b604c6f016956ead711823605eea840c602e"
TEMPLATE = ROOT / "tests/m1n1-topdown.c"
REPORT_ROOT = ROOT / "scratch/m1n1-topdown-tests-2026-10-07"
TRACKED_PATCH = ROOT / "patches/m1n1/upstream-2460b60/0032-coordinate-top-down-reservations.patch"
COMMON = ("utils.c", "utils.h", "heapblock.c", "heapblock.h", "types.h",
          "xnuboot.h", "payload.c", "payload.h")
CASES = ("basic", "zero", "limits", "exact", "top-strict", "allocation-exact",
         "preinit", "preinit-invalid", "invalid", "top-overflow", "ret-overflow",
         "collision-atomic", "heap-arithmetic",
         "heap-align-overflow", "integration")


def fail(message: str) -> "NoReturn":
    raise RuntimeError(message)


def digest(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def extract_function(source: str, name: str) -> str | None:
    match = re.search(rf"(?m)^(?:static\s+)?[A-Za-z_][^\n;]*\b{name}\s*\(", source)
    if not match:
        return None
    start = source.rfind("\n", 0, match.start()) + 1
    brace = source.find("{", match.end())
    if brace < 0:
        fail(f"{name}: opening brace missing")
    depth = 0
    quote = None
    escaped = False
    comment = False
    block = False
    for i in range(brace, len(source)):
        c = source[i]
        n = source[i + 1] if i + 1 < len(source) else ""
        if block:
            if c == "*" and n == "/":
                block = False
        elif comment:
            if c == "\n":
                comment = False
        elif quote:
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == quote:
                quote = None
        elif c == "/" and n == "*":
            block = True
        elif c == "/" and n == "/":
            comment = True
        elif c in "'\"":
            quote = c
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return source[start:i + 1]
    fail(f"{name}: unterminated body")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if text.count(old) != 1:
        fail(f"{label}: expected one occurrence, got {text.count(old)}")
    return text.replace(old, new, 1)


def source_inputs(tree: pathlib.Path) -> list[pathlib.Path]:
    paths = [tree / "src" / name for name in COMMON]
    missing = [path for path in paths if not path.is_file()]
    if missing:
        fail("missing provenance input: " + ", ".join(map(str, missing)))
    return paths


def fixture_parts(tree: pathlib.Path, mutation: str | None, patched: bool) -> tuple[str, bool]:
    heap = (tree / "src/heapblock.c").read_text(encoding="utf-8")
    utils = (tree / "src/utils.c").read_text(encoding="utf-8")
    types = (tree / "src/types.h").read_text(encoding="utf-8")
    utils_h = (tree / "src/utils.h").read_text(encoding="utf-8")
    payload = (tree / "src/payload.c").read_text(encoding="utf-8")
    if not re.search(r"(?m)^#define\s+SZ_16K\s+\(1\s*<<\s*14\)\s*$", types):
        fail(f"{tree}: source SZ_16K declaration changed")
    if not re.search(r"(?m)^#define\s+ALIGN_UP\(x, a\)\s+\(\(\(x\) \+ \(\(a\) - 1\)\) & ~\(\(a\) - 1\)\)\s*$", utils_h):
        fail(f"{tree}: source ALIGN_UP declaration changed")
    names = ("heapblock_init", "heapblock_set_limit", "heapblock_get_cursor",
             "heapblock_get_limit", "heapblock_alloc", "heapblock_alloc_aligned")
    functions = [extract_function(heap, name) for name in names]
    reserve = extract_function(heap, "heapblock_reserve_top")
    top = extract_function(utils, "top_of_memory_alloc")
    helper = extract_function(payload, "prepare_decompression_buffer")
    if any(part is None for part in functions) or top is None:
        fail(f"{tree}: required allocator/top function missing")
    if patched and reserve is None:
        fail(f"{tree}: patched source lacks heapblock_reserve_top")
    if patched and helper is None:
        fail(f"{tree}: patched source lacks prepare_decompression_buffer")
    if helper is not None:
        if len(re.findall(r"(?m)^#define\s+KERNEL_ALIGN\s+\(2\s*<<\s*20\)\s*$", payload)) != 1:
            fail(f"{tree}: source KERNEL_ALIGN declaration changed")
        if len(re.findall(r"(?m)^#define\s+MAX_DECOMPRESSED_SIZE\s+\(1U\s*<<\s*30\)\s*$", payload)) != 1:
            fail(f"{tree}: source MAX_DECOMPRESSED_SIZE declaration changed")
    if mutation == "drop-guard":
        if reserve is None:
            fail("drop-guard mutation requires reserve_top")
        top, count = re.subn(r"(?m)^\s*heapblock_reserve_top\([^;]+\);\s*$",
                              "    /* dropped guard */", top)
        if count != 1:
            fail(f"drop guard: expected one reserve_top call, got {count}")
    globals_text = "\n".join(re.findall(r"(?m)^static\s+void\s+\*\s*heap_(?:base|limit|top)\s*;\s*$", heap))
    if patched and "heap_top" not in globals_text:
        fail(f"{tree}: heap_top static state missing")
    prototypes = "\n".join((
        "void heapblock_init(void);", "void heapblock_set_limit(void *);",
        "void *heapblock_get_cursor(void);", "void *heapblock_get_limit(void);",
        "void *heapblock_alloc(size_t);", "void *heapblock_alloc_aligned(size_t, size_t);",
        "void heapblock_reserve_top(void *);", "u64 top_of_memory_alloc(size_t);"))
    body = "\n\n".join([part for part in (*functions, reserve, top, helper) if part])
    return globals_text + "\n" + prototypes + "\n" + body, helper is not None


def make_fixture(tree: pathlib.Path, mutation: str | None, base: bool) -> tuple[str, bool]:
    parts, helper = fixture_parts(tree, mutation, not base)
    text = TEMPLATE.read_text(encoding="utf-8")
    text = text.replace("/* INSERT_SOURCE_GLOBALS */", parts.split("void heapblock_init(void);")[0], 1)
    text = text.replace("/* INSERT_SOURCE_PROTOTYPES */", "void heapblock_init(void);\n" +
                        parts.split("void heapblock_init(void);", 1)[1].split("void heapblock_init(void)", 1)[0], 1)
    # The split above is intentionally replaced below with the complete source
    # body; keep source globals and declarations visibly separate in the fixture.
    body_start = parts.index("void heapblock_init(void)", parts.index("void heapblock_init(void)") + 1)
    body = parts[body_start:]
    text = text.replace("/* INSERT_HEAP_FUNCTIONS */\n/* INSERT_TOP_FUNCTION */\n/* INSERT_PREPARE_FUNCTION */", body, 1)
    text = ("#define HAVE_TOP_RESERVE 1\n" if not base else "#define BASE_SOURCE 1\n") + text
    if helper:
        text = "#define HAVE_PREPARE_FUNCTION 1\n" + text
    return text, helper


def run_cmd(argv: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["ASAN_OPTIONS"] = "detect_leaks=0"
    env["UBSAN_OPTIONS"] = "halt_on_error=1:print_stacktrace=1"
    return subprocess.run(argv, cwd=cwd, env=env, text=True,
                          capture_output=True, timeout=120, check=False)


def compile_variant(source: str, label: str, work: pathlib.Path,
                    source_inputs: list[pathlib.Path], records: list[dict[str, object]]) -> pathlib.Path:
    generated = work / f"{label}.c"
    binary = work / label
    generated.write_text(source, encoding="utf-8")
    cc = os.environ.get("CC", "clang")
    argv = [cc, "-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
            "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
            str(generated), "-o", str(binary)]
    result = run_cmd(argv, work)
    compile_stdout = work / f"{label}.compile.stdout"
    compile_stderr = work / f"{label}.compile.stderr"
    compile_stdout.write_text(result.stdout, encoding="utf-8")
    compile_stderr.write_text(result.stderr, encoding="utf-8")
    if result.returncode:
        fail(f"{label}: compile failed")
    records.append({"label": label, "compile_argv": argv,
                    "compile_returncode": result.returncode,
                    "generated_source": str(generated),
                    "compile_stdout": str(compile_stdout),
                    "compile_stderr": str(compile_stderr),
                    "artifacts": [{"path": str(p), "sha256": digest(p)} for p in
                                   (generated, binary, compile_stdout, compile_stderr)],
                    "source_inputs": [{"path": str(p), "sha256": digest(p)} for p in source_inputs]})
    return binary


def run_cases(binary: pathlib.Path, label: str, cases: tuple[str, ...], work: pathlib.Path,
              records: list[dict[str, object]], expected_exit: int = 0,
              expected_stderr: str = "") -> None:
    for case in cases:
        result = run_cmd([str(binary), case], work)
        stem = f"{label}.{case}"
        stdout = work / f"{stem}.stdout"
        stderr = work / f"{stem}.stderr"
        log = work / f"{stem}.log"
        stdout.write_text(result.stdout, encoding="utf-8")
        stderr.write_text(result.stderr, encoding="utf-8")
        log.write_text(result.stdout + result.stderr, encoding="utf-8")
        if result.returncode != expected_exit or result.stderr != expected_stderr:
            fail(f"{stem}: expected exit/stderr witness, got {result.returncode!r}")
        if any(x in result.stdout + result.stderr for x in ("AddressSanitizer", "UndefinedBehaviorSanitizer", "runtime error:")):
            fail(f"{stem}: sanitizer diagnostic")
        records.append({"label": stem, "run_argv": [str(binary), case],
                        "run_returncode": result.returncode,
                        "expected_run_returncode": expected_exit,
                        "expected_stderr": expected_stderr,
                        "run_stdout": str(stdout), "run_stderr": str(stderr),
                        "run_log": str(log),
                        "sha256": {str(p): digest(p) for p in (stdout, stderr, log)}})


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-tree", type=pathlib.Path, required=True)
    parser.add_argument("--base-tree", type=pathlib.Path, required=True)
    args = parser.parse_args()
    patched = args.source_tree.resolve()
    base = args.base_tree.resolve()
    for tree in (patched, base):
        if not (tree / "src/utils.c").is_file():
            fail(f"missing source tree: {tree}")
    REPORT_ROOT.mkdir(parents=True, exist_ok=True)
    work = pathlib.Path(tempfile.mkdtemp(prefix="run-", dir=REPORT_ROOT))
    patch_sums: list[pathlib.Path] = []
    for tree in (base, patched):
        candidate = tree.parent / "PATCH_SHA256SUMS"
        if candidate.is_file() and candidate not in patch_sums:
            patch_sums.append(candidate)
    inputs = [TEMPLATE, pathlib.Path(__file__), TRACKED_PATCH, *source_inputs(base),
              *source_inputs(patched), *patch_sums]
    snapshot = {"status": "started", "revision": REV, "base_tree": str(base),
                "patched_tree": str(patched), "inputs": [
                    {"path": str(p), "sha256": digest(p)} for p in inputs]}
    (work / "source-snapshot.json").write_text(json.dumps(snapshot, indent=2) + "\n")
    records: list[dict[str, object]] = []
    patched_source, _ = make_fixture(patched, None, False)
    binary = compile_variant(patched_source, "patched", work, source_inputs(patched), records)
    run_cases(binary, "patched", CASES, work, records)
    mutation_source, _ = make_fixture(patched, "drop-guard", False)
    mutation_binary = compile_variant(mutation_source, "patched-dropped-guard", work,
                                      source_inputs(patched), records)
    run_cases(mutation_binary, "patched-dropped-guard", ("collision-control",), work,
              records, 1, "DESIGNATED_STALE_TOP_LIMIT_OVERLAP\n")
    original_source, _ = make_fixture(base, None, True)
    original_binary = compile_variant(original_source, "full29-original", work,
                                      source_inputs(base), records)
    run_cases(original_binary, "full29-original", ("collision-control",), work,
              records, 1, "DESIGNATED_STALE_TOP_LIMIT_OVERLAP\n")
    execution = {"status": "passed", "variants": records,
                 "source_snapshot": str(work / "source-snapshot.json")}
    (work / "execution-manifest.json").write_text(json.dumps(execution, indent=2) + "\n")
    (work / "source-snapshot.json").write_text(json.dumps({**snapshot, "status": "passed"}, indent=2) + "\n")
    print("PASS: top-down reservations, real heapblock bounds, arithmetic/state cases=14 integration=1 controls=2")
    print(f"Retained evidence: {work}")
    print("Scope: source-extracted host evidence; backing is real host memory; native physical mapping is not tested")
    return 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"topdown: {error}", file=sys.stderr)
        raise SystemExit(1)
