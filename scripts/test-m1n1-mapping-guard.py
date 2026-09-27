#!/usr/bin/env python3
"""Source-extracted host regression for the T6032 post-carveout mapping guard."""
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
ARCHIVE = ROOT / "scratch/m1n1-cpu-audit/source.tar.gz"
TEMPLATE = ROOT / "tests/m1n1-mapping-guard.c"
PATCH_DIR = ROOT / "patches/m1n1"
ARCHIVE_SHA256 = "6425983260ab96d55c36fdaab3b456830c3bd80f06b7759a61ed2bcca924d973"
CLANG = shutil.which("clang")
SOURCE_FILES = {
    "src/mcc.c", "src/mcc.h", "src/memory.c", "src/memory.h", "src/utils.h",
    "src/types.h", "src/cpu_regs.h", "src/xnuboot.h", "src/heapblock.h",
    "src/heapblock.c", "src/main.c", "src/kboot.c", "src/hv.c", "src/hv.h",
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
    if start < 0: fail(f"missing function: {signature}")
    brace = source.find("{", start)
    if brace < 0: fail(f"missing body: {signature}")
    depth = 0; quote = None; escaped = False; line = block = False
    for index in range(brace, len(source)):
        char, nxt = source[index], source[index + 1] if index + 1 < len(source) else ""
        if line:
            if char == "\n": line = False
        elif block:
            if char == "*" and nxt == "/": block = False
        elif quote:
            if escaped: escaped = False
            elif char == "\\": escaped = True
            elif char == quote: quote = None
        elif char in "\"'": quote = char
        elif char == "/" and nxt == "/": line = True
        elif char == "/" and nxt == "*": block = True
        elif char == "{": depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0: return source[start:index + 1]
    fail(f"unterminated function: {signature}")


def extract_define(source: str, name: str) -> str:
    match = re.search(rf"^#define\s+{re.escape(name)}(?:\s|$)", source, re.MULTILINE)
    if match is None: fail(f"missing define: {name}")
    start = match.start()
    lines = source[start:].splitlines(keepends=True)
    selected = [lines[0]]
    while selected[-1].rstrip().endswith("\\"):
        if len(selected) == len(lines): fail(f"unterminated define: {name}")
        selected.append(lines[len(selected)])
    return "".join(selected).rstrip("\n")


def extract_block(source: str, signature: str) -> str:
    """Extract a brace-delimited type/initializer using the same safe scanner."""
    return extract_function(source, signature) + ";"


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
    for index in range(1, 14):
        matches = sorted(PATCH_DIR.glob(f"{index:04d}-*.patch"))
        if len(matches) != 1: fail(f"missing/ambiguous patch {index}: {matches}")
        result = run(["patch", "-p1", "--batch", "--forward", "-i", str(matches[0])], tree)
        if result.returncode: fail(f"patch failed: {matches[0].name}\n{result.stdout}{result.stderr}")


def source_fragment(mcc: str, memory: str, memory_h: str) -> tuple[str, str]:
    mcc_defs = "\n\n".join(extract_block(mcc, signature) for signature in (
        "struct tz_regs {",
        "struct tz_regs t6031_tz_regs =",
        "struct mcc_regs {",
    ))
    mcc_functions = "\n\n".join(extract_function(mcc, signature) for signature in (
        "static bool mcc_t6032_overlap(",
        "static bool mcc_t6032_or_range(",
        "static bool mcc_t6032_decode_carveout(",
        "void mcc_t6032_begin_carveout_setup(",
        "bool mcc_t6032_range_allowed(",
        "int mcc_unmap_carveouts_t6032(",
    ))
    memory_functions = "\n\n".join(extract_function(memory, signature) for signature in (
        "static bool mmu_t6032_mapping_allowed(",
        "int mmu_map(",
        "void mmu_add_mapping(",
        "void mmu_map_framebuffer(",
    ))
    defines = []
    for name in ("VADDR_L3_OFFSET_BITS", "VADDR_L2_OFFSET_BITS", "VADDR_L1_OFFSET_BITS",
                 "VADDR_L0_OFFSET_BITS", "VADDR_L1_ALIGN_MASK", "VADDR_L2_ALIGN_MASK",
                 "PTE_TARGET_MASK"):
        defines.append(extract_define(memory, name))
    for name in ("PLANE_TZ_MAX_REGS", "T6032_MCC_INSTANCE_COUNT", "T6031_PLANE_STRIDE"):
        defines.append(extract_define(mcc, name))
    for name in ("PTE_VALID", "PTE_ACCESS", "PTE_PXN", "PTE_UXN", "PTE_AP_RO",
                 "PTE_AP_EL0", "PTE_SH_OS", "PERM_RWX", "PERM_RW_EL0",
                 "MAIR_IDX_NORMAL", "MAIR_IDX_NORMAL_NC", "REGION_RWX_EL0",
                 "REGION_RW_EL0", "REGION_RX_EL1"):
        defines.append(extract_define(memory_h, name))
    return mcc_defs + "\n\n" + "\n".join(defines), mcc_functions + "\n\n" + memory_functions


def main() -> int:
    if CLANG is None: fail("clang is required")
    with tempfile.TemporaryDirectory(dir=ROOT / "scratch") as directory:
        tree = pathlib.Path(directory) / "m1n1"
        materialize(tree)
        mcc = (tree / "src/mcc.c").read_text(encoding="utf-8")
        memory = (tree / "src/memory.c").read_text(encoding="utf-8")
        memory_h = (tree / "src/memory.h").read_text(encoding="utf-8")
        defines, fragment = source_fragment(mcc, memory, memory_h)
        harness = TEMPLATE.read_text(encoding="utf-8")
        harness = harness.replace("/* INSERT_GUARD_DEFS */", defines)
        harness = harness.replace("/* INSERT_GUARD_SOURCE */", fragment)
        source_path = pathlib.Path(directory) / "mapping-guard.c"
        binary = pathlib.Path(directory) / "mapping-guard"
        source_path.write_text(harness, encoding="utf-8")
        result = run([CLANG, "-std=c11", "-O1", "-g", "-fno-omit-frame-pointer",
                      "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                      str(source_path), "-o", str(binary)], ROOT)
        if result.returncode: fail(f"clang failed:\n{result.stderr}")
        result = run([str(binary)], ROOT)
        if result.returncode: fail(f"mapping harness failed:\n{result.stdout}{result.stderr}")
        mmu_add = extract_function(memory, "void mmu_add_mapping(")
        if mmu_add.find("mmu_t6032_mapping_allowed") > mmu_add.find("mmu_map("):
            fail("mapping guard occurs after mmu_map")
        fb = extract_function(memory, "void mmu_map_framebuffer(")
        if fb.find("mmu_t6032_mapping_allowed") > fb.find("dc_civac_range"):
            fail("framebuffer guard occurs after cache maintenance")
        if not re.search(r"void mmu_add_mapping\([^}]+mmu_t6032_mapping_allowed", mmu_add, re.S):
            fail("mmu_add_mapping guard missing")
        original_memory = (PINNED / "src/memory.c").read_text(encoding="utf-8")
        additions = {
            "int mmu_map(": (
                "    /* Check the physical target, not descriptor attributes or the virtual alias. */\n"
                "    if (chip_id == T6032 && (to & PTE_VALID) &&\n"
                "        !mmu_t6032_mapping_allowed(from, to & PTE_TARGET_MASK, size))\n"
                "        return -1;\n"),
            "void mmu_add_mapping(": (
                "    /* Validate raw physical addresses before descriptor bits can disguise them. */\n"
                "    if (chip_id == T6032 && !mmu_t6032_mapping_allowed(from, to, size))\n"
                '        panic("T6032: rejected MMU mapping 0x%lx -> 0x%lx (0x%lx)\\n", from, to, size);\n'),
            "void mmu_map_framebuffer(": (
                "    if (chip_id == T6032 && !mmu_t6032_mapping_allowed(addr, addr, size))\n"
                '        panic("T6032: rejected framebuffer mapping 0x%lx (0x%zx)\\n", addr, size);\n'),
        }
        for signature, addition in additions.items():
            body = extract_function(memory, signature)
            original = extract_function(original_memory, signature)
            if body.count(addition) != 1 or body.replace(addition, "", 1) != original:
                fail(f"legacy mapper changed beyond the T6032 guard: {signature}")
        unmap = extract_function(mcc, "int mcc_unmap_carveouts_t6032(")
        begin = extract_function(mcc, "void mcc_t6032_begin_carveout_setup(")
        if "if (mcc_carveouts_ready)" not in unmap:
            fail("repeat-call readiness guard missing")
        if unmap.find("mcc_carveout_count = count;") < 0 or unmap.find(
                "mcc_carveouts_ready = true;") < unmap.find("mcc_carveout_count = count;"):
            fail("publication order is not count then ready")
        if not all(token in begin for token in ("mcc_carveouts_ready = false",
                                                "mcc_carveout_count = 0",
                                                "memset(mcc_carveouts")):
            fail("setup reset does not clear all published state")
        mmu_init = extract_function(memory, "void mmu_init(")
        begin_at = mmu_init.find("mcc_t6032_begin_carveout_setup()")
        active_at = mmu_init.find("if (read_sctlr() & SCTLR_M)")
        active_return = mmu_init.find("return;", active_at)
        if (begin_at < 0 or active_at < 0 or active_return < 0 or begin_at < active_return or
                begin_at > mmu_init.find("mmu_init_pagetables()")):
            fail("MMU rebuild does not begin carveout setup before page tables")
        configure = extract_function(memory, "static void mmu_configure(")
        if not all(token in configure for token in (
                "FIELD_PREP(TCR_IPS, TCR_IPS_4TB)",
                "FIELD_PREP(TCR_T0SZ, TCR_T0SZ_48BIT)",
                "FIELD_PREP(TCR_T1SZ, TCR_T1SZ_48BIT)")):
            fail("MMU geometry is not tied to the pinned 4TB/48-bit configuration")
        for signature in ("u64 mmu_disable(", "void mmu_restore("):
            body = extract_function(memory, signature)
            if "mcc_t6032_begin_carveout_setup" in body:
                fail(f"{signature} unexpectedly clears published state")
    print(result.stdout.strip())
    print("T6032 mapping guard source harness passed; no MMIO/native execution")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"error: {error}")
        raise SystemExit(1)
