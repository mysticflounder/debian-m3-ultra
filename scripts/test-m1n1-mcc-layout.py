#!/usr/bin/env python3
"""Source-extracted, host-only regression for the T6032 MCC correction."""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
PINNED = ROOT / "scratch/m1n1-cpu-audit/m1n1-4184923ffb2dff079b384d6a32cc02142aa14572"
TEMPLATE = ROOT / "tests/m1n1-mcc-layout.c"
PATCHES = [ROOT / "patches/m1n1" / f"000{i}-" for i in range(1, 9)]
CLANG = shutil.which("clang")
SOURCE_FILES = {
    "src/mcc.c", "src/main.c", "src/kboot.c", "src/hv.c", "src/hv.h",
    "src/smp.c", "src/smp.h", "src/soc.h", "src/proxy.c", "src/proxy.h",
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
    if begin < 0:
        fail(f"missing source block: {start}")
    finish = source.find(end, begin)
    if finish < 0:
        fail(f"unterminated source block: {start}")
    return source[begin:finish + len(end)]


def extract_define(source: str, name: str) -> str:
    start = source.find(f"#define {name}")
    if start < 0:
        fail(f"missing source define: {name}")
    lines = source[start:].splitlines(keepends=True)
    selected = [lines[0]]
    while selected[-1].rstrip("\n").rstrip().endswith("\\"):
        if len(selected) == len(lines):
            fail(f"unterminated source define: {name}")
        selected.append(lines[len(selected)])
    return "".join(selected).rstrip("\n")


def materialize(tree: pathlib.Path) -> pathlib.Path:
    archive = ROOT / "scratch/m1n1-cpu-audit/source.tar.gz"
    if hashlib.sha256(archive.read_bytes()).hexdigest() != "6425983260ab96d55c36fdaab3b456830c3bd80f06b7759a61ed2bcca924d973":
        fail("pinned source archive hash mismatch")
    with tarfile.open(archive) as tar:
        originals = {p: tar.extractfile(f"{PINNED.name}/{p}").read() for p in SOURCE_FILES}
    for relative in SOURCE_FILES:
        destination = tree / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        source = PINNED / relative
        if not source.is_file() or source.read_bytes() != originals[relative]:
            fail(f"pinned source mismatch: {relative}")
        destination.write_bytes(originals[relative])
    for prefix in PATCHES:
        choices = sorted(prefix.parent.glob(prefix.name + "*.patch"))
        if len(choices) != 1: fail(f"missing patch for {prefix.name}")
        result = run(["patch", "-p1", "--batch", "--forward", "-i", str(choices[0])], tree)
        if result.returncode: fail(f"patch failed: {choices[0].name}\n{result.stdout}{result.stderr}")
    return tree


def source_fragment(source: str) -> str:
    start = source.find("#define T6032_MCC_HEADER_COUNT")
    end = source.find("static u32 plane_read32", start)
    if start < 0 or end < 0: fail("T6032 MCC helper block missing")
    defines = "\n".join(extract_define(source, name) for name in (
        "MAX_MCC_INSTANCES", "T6031_PLANE_OFFSET", "T6031_PLANE_STRIDE",
        "T6031_GLOBAL_OFFSET", "T6031_DCS_OFFSET", "T6031_DCS_STRIDE",
        "PLANE_CACHE_ENABLE", "PLANE_CACHE_STATUS",
        "T6000_CACHE_STATUS_DATA_COUNT", "T6000_CACHE_STATUS_TAG_COUNT",
        "T6031_CACHE_WAYS", "T6031_CACHE_STATUS_MASK", "T6031_CACHE_STATUS_VAL",
        "CACHE_ENABLE_TIMEOUT",
    ))
    structs = "\n\n".join((
        extract_until(source, "struct tz_regs {", "};"),
        extract_until(source, "struct tz_regs t6031_tz_regs =", "};"),
        extract_until(source, "struct tz_regs t6030_tz_regs =", "};"),
        extract_until(source, "struct tz_regs t8122_tz_regs =", "};"),
        extract_until(source, "struct mcc_regs {", "};"),
    ))
    helpers = defines + "\n\n" + structs + "\n\n" + source[start:end]
    return helpers + "\n".join(extract_function(source, signature) for signature in (
        "static u32 plane_read32", "static void plane_write32", "static int plane_poll32",
        "int mcc_enable_cache(void)", "int mcc_init_t6031(",
        "int mcc_init_m3(", "int mcc_init(void)",
    ))


def fixture_source() -> str:
    raw = (ROOT / "docs/inventory/mcc-firmware-layout-2026-09-26.json").read_bytes()
    if hashlib.sha256(raw).hexdigest() != "a34ab7dd02cd56b8e24cfe7d3aa44d02bd04d94392668d06a16af4363a42fb69":
        fail("firmware geometry fixture hash mismatch")
    records = json.loads(raw)["records"]
    result = []
    for target in ("J516c", "J575d"):
        record, = [r for r in records if r["identity"]["target"] == target]
        windows = record["mcc"]["raw_bus_windows"]
        rows = ",\n".join("    {" + w["base"] + "ULL, " + w["size"] + "ULL}" for w in windows)
        result.append(f"static const u64 fixture_{target}[][2] = {{\n{rows}\n}};")
    return "\n".join(result)


def main() -> int:
    if CLANG is None: fail("clang is required")
    with tempfile.TemporaryDirectory(dir=ROOT / "scratch") as directory:
        tree = materialize(pathlib.Path(directory) / "m1n1")
        source = (tree / "src/mcc.c").read_text(encoding="utf-8")
        main_source = (tree / "src/main.c").read_text(encoding="utf-8")
        kboot_source = (tree / "src/kboot.c").read_text(encoding="utf-8")
        fragment = source_fragment(source)
        definitions, helper_source = fragment.split("#define T6032_MCC_HEADER_COUNT", 1)
        harness = TEMPLATE.read_text(encoding="utf-8")
        harness = harness.replace("/* INSERT_MCC_DEFS */", definitions)
        harness = harness.replace("/* INSERT_MCC_SOURCE */", "#define T6032_MCC_HEADER_COUNT" + helper_source)
        harness = harness.replace("/* INSERT_FIRMWARE_FIXTURES */", fixture_source())
        source_path = pathlib.Path(directory) / "mcc-layout.c"
        binary = pathlib.Path(directory) / "mcc-layout"
        source_path.write_text(harness, encoding="utf-8")
        compile_result = run([
            CLANG, "-std=c11", "-O1", "-g", "-fno-omit-frame-pointer",
            "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
            str(source_path), "-o", str(binary),
        ], ROOT)
        if compile_result.returncode:
            fail(f"clang failed:\n{compile_result.stderr}")
        result = run([str(binary)], ROOT)
        if result.returncode:
            fail(f"MCC source harness failed ({result.returncode}):\n{result.stdout}{result.stderr}")

        for signature in ("int mcc_init_m3(", "int mcc_init_t6031("):
            if extract_function(source, signature) != extract_function((PINNED / "src/mcc.c").read_text(), signature):
                fail("legacy M3 initializer changed")
        if not re.search(r"if \(chip_id == T6032\)\s*return mcc_init_t6032", source, re.S):
            fail("T6032 dispatch missing or not before legacy dispatch")
        if not re.search(r"int path\[8\];\s*if \(chip_id == T6032\)\s*mcc_t6032_invalidate\(\)", source, re.S):
            fail("T6032 entry invalidation missing")
        main_body = extract_function(main_source, "void m1n1_main(void)")
        if not re.search(r'if \(chip_id == T6032\)\s*\{\s*if \(mcc_init\(\) < 0\)\s*panic\("T6032 MCC initialization failed!\\n"\);\s*\} else \{\s*mcc_init\(\);\s*\}\s*mmu_init\(\);\s*aic_init\(\);', main_body):
            fail("T6032 main MCC failure gate/order missing")
        kboot_body = extract_function(kboot_source, "int kboot_boot(void *kernel)")
        if not re.search(r"int mcc_ret = mcc_enable_cache\(\);\s*if \(chip_id == T6032 && mcc_ret < 0\)\s*return -1;\s*tunables_apply_static", kboot_body, re.S):
            fail("T6032 kboot cache failure gate/order missing")
        startup = (tree / "src/startup.c").read_text()
        if startup.index("    get_device_info();") >= startup.index("    m1n1_main();"):
            fail("device identity not initialized before main")

    print("T6032 MCC layout source harness passed; caller gates checked; no MMIO/native execution")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"error: {error}")
        raise SystemExit(1)
