#!/usr/bin/env python3
"""Source-extracted, host-only regression for T6032 TZ carveout preflight."""
from __future__ import annotations

import hashlib
import pathlib
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
PINNED = ROOT / "scratch/m1n1-cpu-audit/m1n1-4184923ffb2dff079b384d6a32cc02142aa14572"
TEMPLATE = ROOT / "tests/m1n1-carveout-preflight.c"
ARCHIVE = ROOT / "scratch/m1n1-cpu-audit/source.tar.gz"
ARCHIVE_SHA256 = "6425983260ab96d55c36fdaab3b456830c3bd80f06b7759a61ed2bcca924d973"
CLANG = shutil.which("clang")
PATCH_DIR = ROOT / "patches/m1n1"
SOURCE_FILES = {
    "src/mcc.c", "src/mcc.h", "src/memory.c", "src/memory.h",
    "src/heapblock.c", "src/heapblock.h", "src/xnuboot.h", "src/utils.h",
    "src/main.c", "src/kboot.c", "src/hv.c", "src/hv.h", "src/smp.c",
    "src/smp.h", "src/soc.h", "src/proxy.c", "src/proxy.h",
    "src/payload.c", "src/startup.c",
}


def fail(message: str) -> None:
    raise RuntimeError(message)


def run(command: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=False)


def extract_function(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        fail(f"missing function: {signature}")
    brace = source.find("{", start)
    if brace < 0:
        fail(f"missing function body: {signature}")
    depth = 0
    quote = None
    escaped = False
    line_comment = block_comment = False
    for index in range(brace, len(source)):
        char = source[index]
        nxt = source[index + 1] if index + 1 < len(source) else ""
        if line_comment:
            if char == "\n": line_comment = False
        elif block_comment:
            if char == "*" and nxt == "/": block_comment = False
        elif quote:
            if escaped: escaped = False
            elif char == "\\": escaped = True
            elif char == quote: quote = None
        elif char in "\"'": quote = char
        elif char == "/" and nxt == "/": line_comment = True
        elif char == "/" and nxt == "*": block_comment = True
        elif char == "{": depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0: return source[start:index + 1]
    fail(f"unterminated function: {signature}")


def extract_until(source: str, start: str, end: str) -> str:
    begin = source.find(start)
    if begin < 0: fail(f"missing source block: {start}")
    finish = source.find(end, begin)
    if finish < 0: fail(f"unterminated source block: {start}")
    return source[begin:finish + len(end)]


def extract_define(source: str, name: str) -> str:
    start = source.find(f"#define {name}")
    if start < 0: fail(f"missing source define: {name}")
    lines = source[start:].splitlines(keepends=True)
    selected = [lines[0]]
    while selected[-1].rstrip().endswith("\\"):
        if len(selected) == len(lines): fail(f"unterminated define: {name}")
        selected.append(lines[len(selected)])
    return "".join(selected).rstrip("\n")


def materialize(tree: pathlib.Path) -> None:
    if hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() != ARCHIVE_SHA256:
        fail("pinned source archive hash mismatch")
    with tarfile.open(ARCHIVE) as archive:
        originals = {p: archive.extractfile(f"{PINNED.name}/{p}").read() for p in SOURCE_FILES}
    for relative in SOURCE_FILES:
        destination = tree / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        source = PINNED / relative
        if not source.is_file() or source.read_bytes() != originals[relative]:
            fail(f"pinned source mismatch: {relative}")
        destination.write_bytes(originals[relative])
    for index in range(1, 10):
        matches = sorted(PATCH_DIR.glob(f"000{index}-*.patch"))
        if len(matches) != 1:
            fail(f"missing or ambiguous patch 000{index}: {[p.name for p in matches]}")
        result = run(["patch", "-p1", "--batch", "--forward", "-i", str(matches[0])], tree)
        if result.returncode:
            fail(f"patch failed: {matches[0].name}\n{result.stdout}{result.stderr}")


def source_fragment(source: str) -> str:
    names = (
        "MAX_MCC_INSTANCES", "T6031_PLANE_OFFSET", "T6031_PLANE_STRIDE",
    )
    defines = "\n".join(extract_define(source, name) for name in names if f"#define {name}" in source)
    structs = "\n\n".join((
        extract_until(source, "struct tz_regs {", "};"),
        extract_until(source, "struct tz_regs t6031_tz_regs =", "};"),
        extract_until(source, "struct mcc_regs {", "};"),
    ))
    functions = "\n\n".join(extract_function(source, signature) for signature in (
        "static bool mcc_t6032_overlap(",
        "static bool mcc_t6032_or_range(",
        "static bool mcc_t6032_decode_carveout(",
        "int mcc_unmap_carveouts_t6032(",
        "int mcc_unmap_carveouts(",
    ))
    return defines + "\n\n" + structs + "\n\n" + functions


def harness_defines(mcc_source: str, memory_header: str) -> str:
    mcc_names = ("PLANE_TZ_MAX_REGS", "T6032_MCC_INSTANCE_COUNT")
    memory_names = ("REGION_RWX_EL0", "REGION_RW_EL0", "REGION_RX_EL1")
    return "\n".join(extract_define(mcc_source, name) for name in mcc_names) + "\n" + "\n".join(
        extract_define(memory_header, name) for name in memory_names
    )


def main() -> int:
    if CLANG is None: fail("clang is required")
    with tempfile.TemporaryDirectory(dir=ROOT / "scratch") as directory:
        tree = pathlib.Path(directory) / "m1n1"
        materialize(tree)
        source = (tree / "src/mcc.c").read_text(encoding="utf-8")
        fragment = source_fragment(source)
        memory_header = (tree / "src/memory.h").read_text(encoding="utf-8")
        harness = TEMPLATE.read_text(encoding="utf-8")
        harness = harness.replace("/* INSERT_MCC_DEFS */", harness_defines(source, memory_header))
        harness = harness.replace("/* INSERT_MCC_SOURCE */", fragment)
        source_path = pathlib.Path(directory) / "carveout-preflight.c"
        binary = pathlib.Path(directory) / "carveout-preflight"
        source_path.write_text(harness, encoding="utf-8")
        result = run([
            CLANG, "-std=c11", "-O1", "-g", "-fno-omit-frame-pointer",
            "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
            str(source_path), "-o", str(binary),
        ], ROOT)
        if result.returncode: fail(f"clang failed:\n{result.stderr}")
        result = run([str(binary)], ROOT)
        if result.returncode: fail(f"preflight harness failed:\n{result.stdout}{result.stderr}")
        if "T6032 carveout preflight tests passed:" not in result.stdout:
            fail(f"unexpected harness result summary: {result.stdout!r}")
        memory_source = (tree / "src/memory.c").read_text(encoding="utf-8")
        default_mappings = extract_function(memory_source, "static void mmu_add_default_mappings(")
        if default_mappings.index("mmu_remap_ranges()") >= default_mappings.index(
            "if (chip_id == T6032 && mcc_unmap_carveouts_t6032(ram_size) < 0)"):
            fail("T6032 carveout removal is not after default remap stages")
        if "if (chip_id != T6032)\n        mcc_unmap_carveouts();" not in default_mappings:
            fail("legacy carveout call was not preserved")
        if "mcc_unmap_carveouts_t6032(ram_size)" not in default_mappings:
            fail("T6032 alias-sized call is not at the late mapping stage")
        mmu_init = extract_function(memory_source, "void mmu_init(void)")
        order = [mmu_init.index(token) for token in
                 ("mmu_add_default_mappings();", "mmu_configure();", "write_sctlr(sctlr);")]
        if order != sorted(order):
            fail("carveout preflight is not before MMU/SCTLR enable")
        mcc_source = (tree / "src/mcc.c").read_text(encoding="utf-8")
        wrapper = extract_function(mcc_source, "int mcc_unmap_carveouts(")
        if not wrapper.lstrip().startswith("int mcc_unmap_carveouts(void)\n{") or "chip_id == T6032" not in wrapper:
            fail("legacy unmap wrapper or T6032 dispatch shape changed")
        original = extract_function((PINNED / "src/mcc.c").read_text(encoding="utf-8"),
                                    "int mcc_unmap_carveouts(")
        legacy = re.sub(r"\n    if \(chip_id == T6032\)\n        return -1;[^\n]*\n", "\n", wrapper, count=1)
        if legacy != original:
            fail("legacy mcc_unmap_carveouts body changed beyond the T6032 guard")
        header = (tree / "src/mcc.h").read_text(encoding="utf-8")
        if "int mcc_unmap_carveouts_t6032(u64 alias_size);" not in header:
            fail("alias-sized T6032 unmap API is not declared")
        heap_source = (tree / "src/heapblock.c").read_text(encoding="utf-8")
        for signature, expected in (("void *heapblock_get_cursor(", "return heap_base;"),
                                    ("void *heapblock_get_limit(", "return heap_limit;")):
            if expected not in extract_function(heap_source, signature):
                fail(f"heap getter source drift: {signature}")
        heap_header = (tree / "src/heapblock.h").read_text(encoding="utf-8")
        if "void *heapblock_get_cursor(void);" not in heap_header or "void *heapblock_get_limit(void);" not in heap_header:
            fail("heap getter declarations missing")
    print(result.stdout.strip())
    print("T6032 MCC carveout preflight source harness passed; no MMIO/native execution")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"error: {error}")
        raise SystemExit(1)
