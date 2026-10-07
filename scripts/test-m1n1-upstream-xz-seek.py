#!/usr/bin/env python3
"""Host regression for the minilzlib checked-seek/rewind change.

The harness includes the reviewed inputbuf.c implementation so it can inspect
the real BUFFER_STATE, while dictbuf/lzma2dec/lzmadec/rangedec/xzstream are
compiled as separate translation units from the same source tree.  Four
bounded controls preserve the old wraparound and migration failures.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import lzma
import pathlib
import random
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
REV = "2460b604c6f016956ead711823605eea840c602e"
BASE = ROOT / "scratch/m1n1-upstream-payload-input-guards.TShhW8" / f"m1n1-{REV}"
PATCHED = ROOT / "scratch/m1n1-xz-seek-patch-2026-10-07/source"
TEMPLATE = ROOT / "tests/m1n1-xz-seek.c"
REPORT_ROOT = ROOT / "scratch/m1n1-xz-seek-tests-2026-10-07"

MODULES = (
    "minilzlib/dictbuf.c", "minilzlib/lzma2dec.c", "minilzlib/lzmadec.c",
    "minilzlib/rangedec.c",
)
PROVENANCE = (
    "minilzlib/inputbuf.c", "minilzlib/minlzlib.h", "minilzlib/minlzma.h",
    "minilzlib/lzma2dec.c", "minilzlib/lzma2dec.h", "minilzlib/lzmadec.c",
    "minilzlib/lzmadec.h", "minilzlib/rangedec.c", "minilzlib/dictbuf.c",
    "minilzlib/xzstream.c", "minilzlib/xzstream.h",
)


def digest(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fail(message: str) -> "NoReturn":
    raise RuntimeError(message)


def command_version(command: list[str]) -> str:
    try:
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, check=False)
    except OSError as error:
        return f"unavailable: {error}"
    return result.stdout.splitlines()[0] if result.stdout else f"status={result.returncode}"


def function_span(text: str, name: str) -> tuple[int, int]:
    match = re.search(rf"(?m)^bool\s*\n?{name}\s*\(", text)
    if match is None:
        fail(f"{name}: source function missing")
    start = text.rfind("\n", 0, match.start()) + 1
    brace = text.find("{", match.end())
    if brace < 0:
        fail(f"{name}: function body missing")
    depth = 0
    quote = ""
    escaped = False
    block = False
    line = False
    i = brace
    while i < len(text):
        c = text[i]
        n = text[i + 1] if i + 1 < len(text) else ""
        if block:
            if c == "*" and n == "/":
                block = False
                i += 2
                continue
        elif line:
            if c == "\n":
                line = False
        elif quote:
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == quote:
                quote = ""
        elif c == "/" and n == "*":
            block = True
            i += 2
            continue
        elif c == "/" and n == "/":
            line = True
        elif c in "'\"":
            quote = c
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return start, i + 1
        i += 1
    fail(f"{name}: unterminated function")


def replace_function(text: str, name: str, replacement: str) -> str:
    start, end = function_span(text, name)
    return text[:start] + replacement.rstrip() + "\n" + text[end:]


def make_fixtures(directory: pathlib.Path) -> dict[str, object]:
    directory.mkdir(parents=True, exist_ok=True)
    repeated = (b"m1n1-xz-seek-" * 4096)[:32768]
    random_source = random.Random(0xA107).randbytes
    small = random_source(31)
    boundary = random_source(65536)
    data = {
        "compressed-32768": repeated,
        "raw-random-31": small,
        "raw-random-65536": boundary,
        "empty": b"",
    }
    for name, payload in data.items():
        encoded = lzma.compress(payload, format=lzma.FORMAT_XZ, preset=6)
        (directory / f"{name}.xz").write_bytes(encoded)
        (directory / f"{name}.out").write_bytes(payload)
    tail_encoded = lzma.compress(repeated, format=lzma.FORMAT_XZ, preset=6)
    tail = tail_encoded + b"M1N1TAIL"
    (directory / "tail.xz").write_bytes(tail)
    (directory / "tail.out").write_bytes(repeated)
    (directory / "tail.consumed").write_text(f"{len(tail_encoded)}\n", encoding="ascii")
    truncated = (directory / "compressed-32768.xz").read_bytes()[:-1]
    (directory / "truncated.xz").write_bytes(truncated)
    bad = bytearray((directory / "compressed-32768.xz").read_bytes())
    bad[-1] ^= 0x01
    (directory / "bad-footer.xz").write_bytes(bad)
    return {
        "files": [{"path": str(path), "sha256": digest(path)}
                  for path in sorted(directory.iterdir())],
        "sizes": {name: len(payload) for name, payload in data.items()},
    }


def source_inputs(tree: pathlib.Path) -> list[pathlib.Path]:
    paths = [tree / "src" / item for item in PROVENANCE]
    missing = [path for path in paths if not path.is_file()]
    if missing:
        fail("source provenance missing: " + ", ".join(map(str, missing)))
    return paths


def write_variant(tree: pathlib.Path, work: pathlib.Path, variant: str) -> tuple[pathlib.Path, list[pathlib.Path], bool]:
    input_source = (tree / "src/minilzlib/inputbuf.c").read_text(encoding="utf-8")
    has_rewind = "BfRewind" in input_source and "BfRewind" in (
        tree / "src/minilzlib/minlzlib.h").read_text(encoding="utf-8")
    if variant == "baselinewrap":
        source = input_source
        has_rewind = False
    elif variant == "droppedforwardguard":
        source = replace_function(input_source, "BfSeek", """bool
BfSeek (
    uint32_t Length,
    uint8_t** Bytes
    )
{
    if ((In.Offset + Length) > In.SoftLimit)
    {
        *Bytes = 0;
        return false;
    }
    *Bytes = &In.Buffer[In.Offset];
    In.Offset += Length;
    return true;
}""")
    elif variant == "droppedrewindguard":
        if not has_rewind:
            fail("candidate BfRewind API is not ready")
        source = replace_function(input_source, "BfRewind", """bool
BfRewind (
    uint32_t Length
    )
{
    In.Offset -= Length;
    return true;
}""")
    else:
        source = input_source
    variant_dir = work / variant
    variant_dir.mkdir()
    input_path = variant_dir / "inputbuf.c"
    input_path.write_text(source, encoding="utf-8")
    xz = tree / "src/minilzlib/xzstream.c"
    xz_host = variant_dir / "xzstream.c"
    xz_host.write_text(
        "#include <stdio.h>\n" + xz.read_text(encoding="utf-8").replace(
            '#include "../utils.h"',
            "/* host fixture: ARM utils are unused by XZ decoder */").replace(
                "streamFooter->Magic != 'ZY'",
                "streamFooter->Magic != (uint16_t)('Y' | ('Z' << 8))"),
        encoding="utf-8")
    rangedec = tree / "src/minilzlib/rangedec.c"
    rangedec_host = variant_dir / "rangedec.c"
    rangedec_text = rangedec.read_text(encoding="utf-8")
    if variant == "callerrewindnotmigrated":
        if not has_rewind:
            fail("candidate BfRewind API is not ready")
        rangedec_text, count = re.subn(
            r"BfRewind\s*\(\s*\*ChunkSize\s*\)",
            "BfSeek((uint32_t)(-*ChunkSize), &chunkEnd)", rangedec_text)
        if count != 1:
            fail("caller rewind mutation target missing")
    if "bool Failed;" in rangedec_text:
        wide_init = "bool HostRcInitialize(uint32_t *chunk_size) { return RcInitialize(chunk_size); }\n" \
            if "uint32_t* ChunkSize" in rangedec_text else \
            ("bool HostRcInitialize(uint32_t *chunk_size) {\n"
             "    uint16_t narrow = (uint16_t)*chunk_size;\n"
             "    bool result = RcInitialize(&narrow);\n"
             "    *chunk_size = narrow;\n"
             "    return result;\n"
             "}\n")
        probes = ("bool HostRcCanRead(void) { return RcCanRead(); }\n"
                  "bool HostRcIsFailed(void) { return RcState.Failed; }\n"
                  + wide_init +
                  "void HostRcForceRange(uint32_t range, uint32_t code) {\n"
                  "    RcState.Range = range; RcState.Code = code; RcState.Failed = false;\n"
                  "}\n")
    else:
        wide_init = ("bool HostRcInitialize(uint32_t *chunk_size) {\n"
                     "    uint16_t narrow = (uint16_t)*chunk_size;\n"
                     "    bool result = RcInitialize(&narrow);\n"
                     "    *chunk_size = narrow;\n"
                     "    return result;\n"
                     "}\n")
        probes = ("bool HostRcCanRead(void) { return RcCanRead(); }\n"
                  "bool HostRcIsFailed(void) { return false; }\n"
                  + wide_init +
                  "void HostRcForceRange(uint32_t range, uint32_t code) {\n"
                  "    (void)range; (void)code;\n"
                  "}\n")
    rangedec_host.write_text(rangedec_text + "\n"
        "/* host-only state probes; production rangedec.c is retained above */\n" +
        probes, encoding="utf-8")
    return input_path, [tree / "src" / item for item in MODULES[:3]] + [rangedec_host, xz_host], has_rewind


def run_variant(tree: pathlib.Path, work: pathlib.Path, fixtures: pathlib.Path,
                variant: str, expected: int, witness: str | None,
                records: list[dict[str, object]]) -> None:
    input_path, modules, has_rewind = write_variant(tree, work, variant)
    generated = work / variant / "m1n1-xz-seek.c"
    shutil.copy2(TEMPLATE, generated)
    binary = work / variant / "m1n1-xz-seek"
    compile_cmd = ["clang", "-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
                   "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                   f"-DTEST_HAS_BF_REWIND={int(has_rewind)}", "-I", str(work / variant),
                   "-I", str(tree / "src"), "-I", str(tree / "src/minilzlib"),
                   str(generated), *map(str, modules), "-o", str(binary)]
    compile_result = subprocess.run(compile_cmd, cwd=ROOT, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    (work / variant / "compile.stdout").write_text(compile_result.stdout, encoding="utf-8")
    (work / variant / "compile.stderr").write_text(compile_result.stderr, encoding="utf-8")
    record: dict[str, object] = {"variant": variant, "compile_argv": compile_cmd,
                                 "compile_status": compile_result.returncode,
                                 "expected_run_status": expected,
                                 "expected_witness": witness,
                                 "compile_stdout": str(work / variant / "compile.stdout"),
                                 "compile_stderr": str(work / variant / "compile.stderr"),
                                 "inputs": [{"path": str(path), "sha256": digest(path)}
                                            for path in [generated, input_path, *modules]]}
    records.append(record)
    if compile_result.returncode != 0:
        fail(f"{variant}: compile failed; see {work / variant / 'compile.stderr'}")
    mode = "patched" if variant == "patched" else variant
    result = subprocess.run([str(binary), mode, str(fixtures)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    (work / variant / "run.stdout").write_text(result.stdout, encoding="utf-8")
    (work / variant / "run.stderr").write_text(result.stderr, encoding="utf-8")
    record.update({"run_argv": [str(binary), mode, str(fixtures)],
                   "run_status": result.returncode,
                   "run_stdout": str(work / variant / "run.stdout"),
                   "run_stderr": str(work / variant / "run.stderr"),
                   "binary_sha256": digest(binary),
                   "compile_stdout_sha256": digest(work / variant / "compile.stdout"),
                   "compile_stderr_sha256": digest(work / variant / "compile.stderr"),
                   "run_stdout_sha256": digest(work / variant / "run.stdout"),
                   "run_stderr_sha256": digest(work / variant / "run.stderr")})
    if result.returncode != expected:
        fail(f"{variant}: expected status {expected}, got {result.returncode}; see {work / variant / 'run.stderr'}")
    if witness is not None and result.stderr != witness:
        fail(f"{variant}: designated witness mismatch; see {work / variant / 'run.stderr'}")
    for output in (result.stdout, result.stderr):
        if any(marker in output for marker in ("AddressSanitizer", "UndefinedBehaviorSanitizer", "runtime error:")):
            fail(f"{variant}: sanitizer diagnostic; see {work / variant / 'run.stderr'}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-tree", type=pathlib.Path, default=BASE)
    parser.add_argument("--source-tree", type=pathlib.Path, default=PATCHED)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    base = args.base_tree.resolve()
    patched = args.source_tree.resolve()
    REPORT_ROOT.mkdir(parents=True, exist_ok=True)
    work = pathlib.Path(tempfile.mkdtemp(prefix="run-", dir=REPORT_ROOT))
    fixtures = work / "fixtures"
    fixture_manifest = make_fixtures(fixtures)
    snapshot = {
        "status": "prepared", "revision": REV, "base_tree": str(base),
        "patched_tree": str(patched), "template": str(TEMPLATE),
        "template_sha256": digest(TEMPLATE), "fixture_manifest": fixture_manifest,
        "runner": str(pathlib.Path(__file__).resolve()),
        "runner_sha256": digest(pathlib.Path(__file__).resolve()),
        "toolchain": {"python": sys.version, "clang": command_version(["clang", "--version"]),
                       "xz_liblzma": command_version(["xz", "--version"]),
                       "python_liblzma": getattr(lzma, "LZMA_VERSION", "unknown")},
        "source_inputs": [{"path": str(path), "sha256": digest(path)}
                          for tree in (base, patched) for path in source_inputs(tree)],
        "patch_sums": [{"path": str(path), "sha256": digest(path)}
                       for path in (base.parent / "PATCH_SHA256SUMS",
                                    patched.parent / "PATCH_SHA256SUMS")
                       if path.is_file()],
    }
    (work / "source-snapshot.json").write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")
    if args.prepare_only:
        print(f"Prepared XZ seek fixtures: {work}")
        return 0
    candidate = patched / "src/minilzlib/inputbuf.c"
    if not candidate.is_file() or "BfRewind" not in candidate.read_text(encoding="utf-8"):
        print(f"candidate BfRewind API not ready; prepared evidence: {work}", file=sys.stderr)
        return 2
    records: list[dict[str, object]] = []
    run_variant(patched, work, fixtures, "patched", 0, None, records)
    run_variant(base, work, fixtures, "baselinewrap", 1, "DESIGNATED_BASELINE_WRAP\n", records)
    run_variant(patched, work, fixtures, "droppedforwardguard", 1,
                "DESIGNATED_DROPPED_FORWARD_GUARD\n", records)
    run_variant(patched, work, fixtures, "droppedrewindguard", 1,
                "DESIGNATED_DROPPED_REWIND_GUARD\n", records)
    run_variant(patched, work, fixtures, "callerrewindnotmigrated", 1,
                "DESIGNATED_CALLER_REWIND_NOT_MIGRATED\n", records)
    execution = {"status": "passed", "variants": records,
                 "source_snapshot": str(work / "source-snapshot.json")}
    (work / "execution-manifest.json").write_text(json.dumps(execution, indent=2) + "\n", encoding="utf-8")
    snapshot["status"] = "passed"
    (work / "source-snapshot.json").write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")
    print(f"PASS: checked BfSeek/BfRewind state, real XZ fixtures, controls=4")
    print(f"Retained evidence: {work}")
    return 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"xz seek: {error}", file=sys.stderr)
        raise SystemExit(1)
