#!/usr/bin/env python3
"""Offline ELF/Mach-O layout checks for the opt-in SMP shared-memory build.

These checks establish linked layout, not runtime relocation or MMIO safety.
Only locally built, bounded artifacts are accepted; nothing is executed.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import struct


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def bounded_file(path: pathlib.Path) -> bytes:
    require(path.stat().st_size <= 16 * 1024 * 1024, f"oversized artifact: {path}")
    return path.read_bytes()


def region(data: bytes, offset: int, size: int) -> bytes:
    require(0 <= offset <= len(data) and 0 <= size <= len(data) - offset,
            "artifact range outside file")
    return data[offset:offset + size]


def cstring(data: bytes, offset: int) -> str:
    require(0 <= offset < len(data), "invalid string offset")
    end = data.find(b"\0", offset)
    require(end >= 0, "unterminated string")
    return data[offset:end].decode("ascii")


PROFILE_PINNED = "pinned"
PROFILE_REVIEWED_UPSTREAM = (
    "reviewed-upstream-2460b604c6f016956ead711823605eea840c602e"
)


def source_text(path: pathlib.Path) -> str:
    data = bounded_file(path)
    return data.decode("utf-8")


def source_integer(source: str, name: str) -> int:
    match = re.search(rf"^#define\s+{re.escape(name)}\s+(0x[0-9a-fA-F]+|[0-9]+)\s*$",
                      source, re.MULTILINE)
    require(match is not None, f"source macro missing: {name}")
    return int(match.group(1), 0)


def reviewed_upstream_layout(source_tree: pathlib.Path) -> dict:
    asm = source_text(source_tree / "src/smp_asm.h")
    smp = source_text(source_tree / "src/smp.c")
    max_cpus = source_integer(asm, "MAX_CPUS")
    max_el3_cpus = source_integer(asm, "MAX_EL3_CPUS")
    stack_size = source_integer(asm, "SECONDARY_STACK_SIZE")
    require((max_cpus, max_el3_cpus, stack_size) == (32, 4, 0x10000),
            "reviewed upstream source revision has unexpected CPU/stack constants")
    declarations = re.findall(
        r"u8\s+(secondary_stacks(?:_el3)?)\s*\[\s*(MAX_CPUS|MAX_EL3_CPUS)\s*\]"
        r"\s*\[\s*SECONDARY_STACK_SIZE\s*\]\s*ALIGNED\(\s*"
        r"(0x[0-9a-fA-F]+|[0-9]+)\s*\)", smp,
    )
    require(len(declarations) == 2, "source static-stack declarations missing")
    declaration_map = {name: count for name, count, _alignment in declarations}
    require(declaration_map == {
        "secondary_stacks": "MAX_CPUS",
        "secondary_stacks_el3": "MAX_EL3_CPUS",
    }, "source static-stack dimensions disagree")
    alignments = {int(value, 0) for _name, _count, value in declarations}
    require(len(alignments) == 1, "source static-stack alignments disagree")
    alignment = alignments.pop()
    require(alignment == 0x4000, "reviewed upstream source has unexpected stack alignment")
    reset_match = re.search(r"struct\s+smp_reset_stack\s*\{([^}]*)\}", smp, re.DOTALL)
    require(reset_match is not None and len(re.findall(r"\bu64\s+\w+\s*;", reset_match.group(1))) == 2
            and "smp_reset_stacks[MAX_CPUS]" in smp,
            "source reset-stack table declaration missing or changed")
    layout = {
        "max_cpus": max_cpus,
        "max_el3_cpus": max_el3_cpus,
        "stack_size": stack_size,
        "stack_alignment": alignment,
        "static_stacks": {
            "secondary_stacks": (max_cpus * stack_size, alignment),
            "secondary_stacks_el3": (max_el3_cpus * stack_size, alignment),
        },
        "reset_stack_table": (max_cpus * 2 * 8, 8),
    }
    print(
        "reviewed upstream source layout: "
        f"MAX_CPUS={max_cpus}, MAX_EL3_CPUS={max_el3_cpus}, "
        f"SECONDARY_STACK_SIZE={stack_size:#x}, static alignment={alignment:#x}"
    )
    return layout


def inspect_elf(path: pathlib.Path, profile: str = PROFILE_PINNED,
                layout: dict | None = None) -> tuple[dict, tuple]:
    data = bounded_file(path)
    header = struct.unpack("<16sHHIQQQIHHHHHH", region(data, 0, 64))
    require(header[0][:7] == b"\x7fELF\x02\x01\x01" and header[2] == 183,
            "expected little-endian AArch64 ELF64")
    shoff, entsize, count, names_index = header[6], header[11], header[12], header[13]
    require(entsize == 64 and 0 < count < 4096 and names_index < count,
            "unsupported ELF section table")
    sections = [struct.unpack("<IIQQQQIIQQ", region(data, shoff + i * 64, 64))
                for i in range(count)]
    names_section = sections[names_index]
    names = region(data, names_section[4], names_section[5])
    data_sections = [(i, s) for i, s in enumerate(sections)
                     if cstring(names, s[0]) == ".data"]
    require(len(data_sections) == 1, "missing/ambiguous .data")
    data_index, data_section = data_sections[0]
    section_names = {i: cstring(names, section[0]) for i, section in enumerate(sections)}
    symbols = {}
    for section in sections:
        if section[1] != 2:  # SHT_SYMTAB, not the dynamic subset
            continue
        require(section[9] == 24 and section[5] % 24 == 0 and section[6] < count,
                "invalid symbol table")
        strings_section = sections[section[6]]
        strings = region(data, strings_section[4], strings_section[5])
        entries = region(data, section[4], section[5])
        for at in range(0, len(entries), 24):
            name, info, other, index, value, size = struct.unpack_from("<IBBHQQ", entries, at)
            if name:
                symbol = cstring(strings, name)
                symbols.setdefault(symbol, []).append((value, size, index))

    def unique(name: str) -> tuple[int, int, int]:
        matches = symbols.get(name, [])
        require(len(matches) == 1, f"missing/ambiguous symbol: {name}")
        return matches[0]

    values = {name: unique(name)[0] for name in
              ("_base", "_data_start", "_smp_shared_start", "_smp_shared_end",
               "_data_size", "_end", "_payload_start")}
    if "_va_off" in symbols:
        values["_va_off"] = unique("_va_off")[0]
    start, end = values["_smp_shared_start"], values["_smp_shared_end"]
    require(start < end and start % 65536 == end % 65536 == 0,
            "shared interval must be nonempty and 64-KiB aligned")
    require(values["_base"] <= values["_data_start"] == data_section[3] == start,
            "DATA start/alignment gap mismatch")
    require(end <= data_section[3] + data_section[5] <= values["_end"] <= values["_payload_start"],
            "shared/data/image/payload bounds mismatch")
    require(values["_data_size"] == values["_end"] - values["_data_start"],
            "DATA virtual size includes an alignment gap")
    if profile == PROFILE_PINNED:
        expected = {"_reset_stack": 8, "_reset_stack_el1": 8, "wfe_mode": 1,
                    "target_cpu": 4, "spin_table": 32 * 64, "secondary_stacks": 32 * 8,
                    "secondary_stacks_el3": 4 * 8, "boot_cpu_idx": 4, "boot_cpu_mpidr": 8}
    else:
        require(profile == PROFILE_REVIEWED_UPSTREAM and layout is not None,
                "unknown SMP layout profile")
        expected = {"_reset_stack": 8, "_reset_stack_el1": 8, "wfe_mode": 1,
                    "target_cpu": 4, "spin_table": layout["max_cpus"] * 64,
                    "smp_reset_stacks": layout["reset_stack_table"][0],
                    "boot_cpu_idx": 4, "boot_cpu_mpidr": 8}
        for name in layout["static_stacks"]:
            values[name] = unique(name)[0]
    for name, size in expected.items():
        address, actual_size, index = unique(name)
        require(actual_size == size and index == data_index and start <= address < end
                and address + size <= end, f"shared object outside interval or wrong size: {name}")
        require(address % min(size, 8) == 0, f"unaligned shared object: {name}")
    if profile == PROFILE_REVIEWED_UPSTREAM:
        bss_matches = [(i, section) for i, section in enumerate(sections)
                       if section_names[i] == ".bss"]
        require(len(bss_matches) == 1, "missing/ambiguous .bss")
        bss_index, bss = bss_matches[0]
        for name, (size, alignment) in layout["static_stacks"].items():
            address, actual_size, index = unique(name)
            require(actual_size == size and index == bss_index,
                    f"static stack section/size mismatch: {name}")
            require(address % alignment == 0,
                    f"static stack alignment mismatch: {name}")
            require(bss[3] <= address and address + size <= bss[3] + bss[5],
                    f"static stack outside .bss: {name}")
            require(address + size <= start or address >= end,
                    f"static stack overlaps shared interval: {name}")
        extents = [(name, unique(name)[0], size)
                   for name, (size, _alignment) in layout["static_stacks"].items()]
        for index, (left_name, left_start, left_size) in enumerate(extents):
            for right_name, right_start, right_size in extents[index + 1:]:
                require(left_start + left_size <= right_start
                        or right_start + right_size <= left_start,
                        f"static stack extents overlap: {left_name}, {right_name}")
        print(f"{path.name}: PASS; shared size={end - start:#x}, "
              f"objects={len(expected)}, static stacks={len(layout['static_stacks'])}")
    else:
        print(f"{path.name}: PASS; shared size={end - start:#x}, objects={len(expected)}")
    return values, data_section


def inspect_macho(path: pathlib.Path, symbols: dict, data_section: tuple,
                  profile: str = PROFILE_PINNED, layout: dict | None = None) -> None:
    data = bounded_file(path)
    header = struct.unpack("<8I", region(data, 0, 32))
    require(header[0] == 0xFEEDFACF and header[1] == 0x100000C, "expected arm64 Mach-O")
    require(0 < header[4] < 128, "invalid Mach-O command count")
    commands_end = 32 + header[5]
    region(data, 32, header[5])
    at, matches = 32, []
    for _ in range(header[4]):
        command, size = struct.unpack("<II", region(data, at, 8))
        require(size >= 8 and at + size <= commands_end, "invalid load command")
        if command == 0x19:
            require(size >= 72, "short segment command")
            fields = struct.unpack("<II16sQQQQIIII", region(data, at, 72))
            if fields[2].rstrip(b"\0") == b"DATA":
                matches.append(fields)
        at += size
    require(at == commands_end and len(matches) == 1, "invalid DATA command inventory")
    segment = matches[0]
    require("_va_off" in symbols, "missing Mach-O virtual address bias")
    # The pinned Mach-O VA bias is 16-KiB aligned, not 64-KiB aligned.
    # Runtime physical relocation is not established by this artifact audit.
    require(segment[3] == (data_section[3] + symbols["_va_off"]) % (1 << 64),
            "DATA virtual address mismatch")
    require(segment[4] == symbols["_data_size"] and segment[6] == data_section[5]
            and segment[5] == data_section[3] - symbols["_base"], "DATA segment layout mismatch")
    region(data, segment[5], segment[6])
    require(segment[3] % 16384 == 0, "Mach-O DATA virtual base misaligned")
    if profile == PROFILE_REVIEWED_UPSTREAM:
        start, end = symbols["_smp_shared_start"], symbols["_smp_shared_end"]
        va_off = symbols["_va_off"]
        require(segment[3] <= start + va_off and end + va_off <= segment[3] + segment[4],
                "Mach-O DATA segment excludes shared interval")
        for name, (size, alignment) in layout["static_stacks"].items():
            address = symbols[name]
            require(address % alignment == 0 and segment[3] <= address + va_off
                    and address + va_off + size <= segment[3] + segment[4],
                    f"Mach-O static stack segment/alignment mismatch: {name}")
    print(f"{path.name}: PASS; DATA segment size/file interval")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_directory", type=pathlib.Path, help="directory containing m1n1.elf")
    parser.add_argument("--profile", choices=(PROFILE_PINNED, PROFILE_REVIEWED_UPSTREAM),
                        default=PROFILE_PINNED,
                        help="linked-layout profile (default: pinned)")
    parser.add_argument("--source-tree", type=pathlib.Path,
                        help="upstream source tree used to derive stack sizes/alignment")
    args = parser.parse_args()
    layout = None
    if args.profile == PROFILE_REVIEWED_UPSTREAM:
        require(args.source_tree is not None, "--source-tree is required for upstream profile")
        layout = reviewed_upstream_layout(args.source_tree)
    symbols, data_section = inspect_elf(args.build_directory / "m1n1.elf", args.profile, layout)
    inspect_elf(args.build_directory / "m1n1-raw.elf", args.profile, layout)
    inspect_macho(args.build_directory / "m1n1.macho", symbols, data_section,
                  args.profile, layout)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, struct.error) as exc:
        raise SystemExit(f"SMP layout audit: ERROR: {exc}")
