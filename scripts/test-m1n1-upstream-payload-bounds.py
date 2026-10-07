#!/usr/bin/env python3
"""Source-extracted host tests for the m1n1 decompressor output cap.

The pinned tinf and minilzma implementations are compiled from the reviewed
tree.  Only heapblock, load_one_payload and boot-args are host mocks.  The
patched source is tested for bounded gzip/XZ output; the full28 source and two
independent dropped-cap mutations are retained as designated unsafe controls.
No VM, firmware, MMIO or native loader state is exercised.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import lzma
import os
import pathlib
import re
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
REV = "2460b604c6f016956ead711823605eea840c602e"
BASE_DEFAULT = ROOT / "scratch/m1n1-upstream-board-handoff.D1YyQS" / f"m1n1-{REV}"
TEMPLATE = ROOT / "tests/m1n1-payload-bounds.c"
REPORT_ROOT = ROOT / "scratch/native-loader-payload-tests-2026-10-07"
PATCH_SUMS = ROOT / "scratch/m1n1-upstream-board-handoff.D1YyQS/PATCH_SHA256SUMS"
DECODER_FILES = (
    "tinf/adler32.c", "tinf/crc32.c", "tinf/tinflate.c", "tinf/tinfzlib.c",
    "tinf/tinfgzip.c", "tinf/tinf.h", "minilzlib/dictbuf.c",
    "minilzlib/inputbuf.c", "minilzlib/lzma2dec.c", "minilzlib/lzmadec.c",
    "minilzlib/rangedec.c", "minilzlib/xzstream.c", "minilzlib/xzstream.h",
    "minilzlib/minlzlib.h", "minilzlib/minlzma.h", "minilzlib/lzma2dec.h",
    "minilzlib/lzmadec.h",
)
COMMON_INPUTS = ("payload.c", "payload.h", "heapblock.c", "heapblock.h",
                 "xnuboot.h", "types.h", "kboot.c", "kboot.h", "utils.h")


def fail(message: str) -> "NoReturn":
    raise RuntimeError(message)


def digest(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def extract_function(source: str, name: str) -> str | None:
    match = re.search(rf"(?m)^static\s+[^\n;]*\b{name}\s*\(", source)
    if match is None:
        return None
    start = source.rfind("\n", 0, match.start()) + 1
    brace = source.find("{", match.end())
    if brace < 0:
        fail(f"{name}: opening brace missing")
    depth = 0
    quote: str | None = None
    escaped = False
    comment = False
    block_comment = False
    i = brace
    while i < len(source):
        c = source[i]
        n = source[i + 1] if i + 1 < len(source) else ""
        if block_comment:
            if c == "*" and n == "/":
                block_comment = False
                i += 2
                continue
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
            block_comment = True
            i += 2
            continue
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
        i += 1
    fail(f"{name}: unterminated body")


def literal(data: bytes) -> str:
    return ", ".join(f"0x{byte:02x}" for byte in data)


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if text.count(old) != 1:
        fail(f"{label}: expected one mutation target, got {text.count(old)}")
    return text.replace(old, new, 1)


def source_inputs(tree: pathlib.Path) -> list[pathlib.Path]:
    names = [tree / "src" / name for name in (*COMMON_INPUTS, *DECODER_FILES)]
    missing = [path for path in names if not path.is_file()]
    if missing:
        fail(f"source provenance inputs missing: {', '.join(str(path) for path in missing)}")
    return names


def wrapper_set(tree: pathlib.Path, mutation: str | None = None) -> tuple[str, bool]:
    source_path = tree / "src/payload.c"
    source = source_path.read_text(encoding="utf-8")
    # The host template deliberately defines these constants too. Bind the
    # extracted functions to the native source declarations so a future macro
    # change cannot silently leave this fixture testing different limits.
    align_decl = re.compile(r"(?m)^#define\s+KERNEL_ALIGN\s+\(2\s*<<\s*20\)\s*$")
    if len(align_decl.findall(source)) != 1:
        fail(f"{source_path}: expected exactly one KERNEL_ALIGN=(2 << 20) declaration")
    helper = extract_function(source, "prepare_decompression_buffer")
    patched = helper is not None
    if patched:
        cap_decl = re.compile(r"(?m)^#define\s+MAX_DECOMPRESSED_SIZE\s+\(1U\s*<<\s*30\)\s*$")
        if len(cap_decl.findall(source)) != 1:
            fail(f"{source_path}: expected exactly one MAX_DECOMPRESSED_SIZE=(1U << 30) declaration")
    finalize = extract_function(source, "finalize_uncompression")
    gzip = extract_function(source, "decompress_gz")
    xz = extract_function(source, "decompress_xz")
    if finalize is None or gzip is None or xz is None:
        fail(f"{source_path}: expected decompressor functions missing")
    if patched:
        required = (
            "heapblock_get_cursor", "heapblock_get_limit", "cur_boot_args.phys_base",
            "cur_boot_args.mem_size", "__builtin_add_overflow", "MAX_DECOMPRESSED_SIZE",
        )
        for token in required:
            if token not in helper:
                fail(f"patched helper missing source-bound token {token}")
        for name, body in (("decompress_gz", gzip), ("decompress_xz", xz)):
            if body.count("prepare_decompression_buffer") != 1:
                fail(f"{name}: patched wrapper does not use the shared helper exactly once")
            if "dest_len = 1 << 30" in body or "dest_len = 1U << 30" in body:
                fail(f"{name}: stale unbounded one-GiB assignment remains")
    if mutation is not None and patched:
        old = ("    void *dest;\n"
               "    if (!prepare_decompression_buffer(&dest, &dest_len))\n"
               "        return NULL;")
        new = ("    void *dest = heapblock_alloc_aligned(0, KERNEL_ALIGN);\n"
               "    dest_len = 1U << 30;")
        if mutation == "gzip":
            gzip = replace_once(gzip, old, new, "gzip dropped-cap mutation")
        elif mutation == "xz":
            xz = replace_once(xz, old, new, "XZ dropped-cap mutation")
        else:
            fail(f"unknown mutation {mutation}")
    functions = "\n\n".join(part for part in (helper, finalize, gzip, xz) if part)
    return functions, patched


def decoder_sources(tree: pathlib.Path, work: pathlib.Path) -> tuple[str, list[pathlib.Path]]:
    files = tuple(name for name in DECODER_FILES if name.endswith(".c"))
    missing = [name for name in files if not (tree / "src" / name).is_file()]
    if missing:
        fail(f"decoder sources missing: {', '.join(missing)}")
    # Headers are inserted into the fixture; decoder implementations are
    # separate translation units so tinf's same-named static helpers do not
    # collide. xzstream's production utils.h is ARM-only and unused by this
    # decoder, so retain the source with that one host-only include elided.
    xz_path = tree / "src/minilzlib/xzstream.c"
    xz_host = work / f"xzstream-{digest(xz_path)[:12]}.c"
    xz_host.write_text("#include <stdio.h>\n" + xz_path.read_text(encoding="utf-8").replace(
        '#include "../utils.h"', "/* host fixture: ARM utils are unused by XZ decoder */"),
        encoding="utf-8")
    headers = (f'#include "{(tree / "src/tinf/tinf.h").as_posix()}"\n'
               f'#include "{(tree / "src/minilzlib/minlzma.h").as_posix()}"')
    implementations = [tree / "src" / name for name in files[:-1]] + [xz_host]
    return headers, implementations


def make_fixture(tree: pathlib.Path, mutation: str | None, base: bool,
                 work: pathlib.Path) -> tuple[str, list[pathlib.Path]]:
    payload, patched = wrapper_set(tree, mutation)
    if base and patched:
        fail("base fixture unexpectedly contains patched helper")
    if not base and not patched:
        fail("patched fixture source has no prepare_decompression_buffer helper")
    gzip_data = gzip.compress(b"PAYLOAD-GZ-BOUNDARY", mtime=0)
    xz = lzma.compress(b"PAYLOAD-XZ-BOUNDARY", format=lzma.FORMAT_XZ)
    text = TEMPLATE.read_text(encoding="utf-8")
    headers, implementations = decoder_sources(tree, work)
    text = replace_once(text, "/* INSERT_PAYLOAD_FUNCTIONS */",
                        headers + "\n\n" + payload, "payload insertion")
    text = replace_once(text, "/* INSERT_DECODER_SOURCES */", "", "decoder insertion")
    text = replace_once(text, "/* INSERT_GZIP_BYTES */", literal(gzip_data), "gzip fixture")
    text = replace_once(text, "/* INSERT_XZ_BYTES */", literal(xz), "XZ fixture")
    if base:
        text = "#define BASE_SOURCE 1\n" + text
    else:
        text = "#define HAVE_PREPARE_DECOMPRESSION_BUFFER 1\n" + text
    return text, implementations


def command_run(command: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["ASAN_OPTIONS"] = "detect_leaks=0"
    env["UBSAN_OPTIONS"] = "halt_on_error=1:print_stacktrace=1"
    return subprocess.run(command, cwd=cwd, env=env, text=True,
                          capture_output=True, timeout=120, check=False)


def compile_and_run(source: str, label: str, work: pathlib.Path,
                    args: list[str], records: list[dict[str, object]],
                    expected_exit: int = 0,
                    expected_stderr: str | None = None,
                    decoder_sources: list[pathlib.Path] | None = None) -> None:
    generated = work / f"{label}.c"
    binary = work / label
    generated.write_text(source, encoding="utf-8")
    clang = os.environ.get("CC", "clang")
    command = [clang, "-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-Wno-multichar", "-Wno-unused-function",
               "-fno-omit-frame-pointer", "-fsanitize=address,undefined",
               "-fno-sanitize-recover=all"]
    include_dirs = sorted({str(path.parent) for path in (decoder_sources or [])})
    command.extend(f"-I{path}" for path in include_dirs)
    command.extend([str(generated), *(str(path) for path in (decoder_sources or [])), "-o", str(binary)])
    result = command_run(command, work)
    compile_stdout = work / f"{label}.compile.stdout"
    compile_stderr = work / f"{label}.compile.stderr"
    compile_log = work / f"{label}.compile.log"
    compile_stdout.write_text(result.stdout, encoding="utf-8")
    compile_stderr.write_text(result.stderr, encoding="utf-8")
    compile_log.write_text(result.stdout + result.stderr, encoding="utf-8")
    record: dict[str, object] = {
        "label": label,
        "compile_argv": command,
        "compile_returncode": result.returncode,
        "run_argv": [str(binary), *args],
        "expected_run_returncode": expected_exit,
        "expected_stderr": expected_stderr,
        "generated_source": str(generated),
        "decoder_sources": [
            {"path": str(path), "sha256": digest(path)}
            for path in (decoder_sources or [])
        ],
        "compile_stdout": str(compile_stdout),
        "compile_stderr": str(compile_stderr),
        "compile_log": str(compile_log),
    }
    records.append(record)
    if result.returncode:
        fail(f"{label}: compile failed; see {compile_log}")
    result = command_run([str(binary), *args], work)
    run_stdout = work / f"{label}.run.stdout"
    run_stderr = work / f"{label}.run.stderr"
    run_log = work / f"{label}.run.log"
    run_stdout.write_text(result.stdout, encoding="utf-8")
    run_stderr.write_text(result.stderr, encoding="utf-8")
    run_log.write_text(result.stdout + result.stderr, encoding="utf-8")
    record.update({
        "run_returncode": result.returncode,
        "run_stdout": str(run_stdout),
        "run_stderr": str(run_stderr),
        "run_log": str(run_log),
    })
    if result.returncode != expected_exit:
        fail(f"{label}: expected exit {expected_exit}, got {result.returncode}; see {run_log}")
    if expected_stderr is not None and result.stderr != expected_stderr:
        fail(f"{label}: stderr was not the exact designated witness; see {run_stderr}")
    for output in (result.stdout, result.stderr):
        if any(marker in output for marker in ("AddressSanitizer", "UndefinedBehaviorSanitizer", "runtime error:")):
            fail(f"{label}: sanitizer diagnostic in captured output; see {run_log}")
    artifacts = [generated, binary, compile_stdout, compile_stderr, compile_log,
                 run_stdout, run_stderr, run_log]
    record["artifacts"] = [{"path": str(path), "sha256": digest(path)} for path in artifacts]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-tree", type=pathlib.Path, default=BASE_DEFAULT)
    parser.add_argument("--source-tree", type=pathlib.Path, required=True)
    args = parser.parse_args()
    base = args.base_tree.resolve()
    patched = args.source_tree.resolve()
    for tree in (base, patched):
        if not (tree / "src/payload.c").is_file():
            fail(f"missing source tree: {tree}")
    REPORT_ROOT.mkdir(parents=True, exist_ok=True)
    work = pathlib.Path(tempfile.mkdtemp(prefix="run-", dir=REPORT_ROOT))
    patch_sum_paths = [PATCH_SUMS]
    for tree in (base, patched):
        candidate = tree.parent / "PATCH_SHA256SUMS"
        if candidate.is_file() and candidate not in patch_sum_paths:
            patch_sum_paths.append(candidate)
    all_inputs = [TEMPLATE, pathlib.Path(__file__), *source_inputs(base),
                  *source_inputs(patched), *patch_sum_paths]
    manifest = {
        "status": "started", "base_tree": str(base), "patched_tree": str(patched),
        "revision": REV, "scope": "source-extracted tinf/minilzma + mocked heap/load/bootargs; no native proof",
        "inputs": [{"path": str(path), "sha256": digest(path)} for path in all_inputs],
    }
    (work / "source-snapshot.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    records: list[dict[str, object]] = []

    patched_source, patched_decoders = make_fixture(patched, None, False, work)
    compile_and_run(patched_source, "patched-bounded", work, [], records,
                    decoder_sources=patched_decoders)
    for codec in ("gzip", "xz"):
        mutation_source, mutation_decoders = make_fixture(patched, codec, False, work)
        compile_and_run(mutation_source, f"patched-mutation-{codec}", work,
                        [f"mutation-{codec}"], records, expected_exit=1,
                        expected_stderr="DESIGNATED_UNSAFE_WRITE_DETECTED\n",
                        decoder_sources=mutation_decoders)
    for codec in ("gzip", "xz"):
        original_source, original_decoders = make_fixture(base, codec, True, work)
        compile_and_run(original_source, f"full28-original-{codec}", work,
                        [f"mutation-{codec}"], records, expected_exit=1,
                        expected_stderr="DESIGNATED_UNSAFE_WRITE_DETECTED\n",
                        decoder_sources=original_decoders)
    execution = {"status": "passed", "variants": records,
                 "source_snapshot": str(work / "source-snapshot.json")}
    (work / "execution-manifest.json").write_text(json.dumps(execution, indent=2) + "\n", encoding="utf-8")
    (work / "source-snapshot.json").write_text(json.dumps({**manifest, "status": "passed"}, indent=2) + "\n", encoding="utf-8")
    print("PASS: patched gzip/XZ; helper-boundary-cases=10 wrapper-cases=16 mutation-controls=4")
    print(f"Retained evidence: {work}")
    print("Scope: host source extraction with real pinned decoders; heap/load/bootargs mocked; native/firmware/VM state not tested")
    return 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"payload bounds: {error}", file=sys.stderr)
        raise SystemExit(1)
