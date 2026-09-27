#!/usr/bin/env python3
"""Offline, allowlisted J575d PMGR window translation; never accesses MMIO.

The map IDs, provider indices and ACC offset come from the separately documented
AppleT6031PMGR binary trace. This is not a generic register-map discovery tool.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import pathlib
import stat
import struct
import sys

SPEC = importlib.util.spec_from_file_location(
    "firmware_mcc", pathlib.Path(__file__).with_name("inspect-firmware-mcc.py"))
ADT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ADT)
require = ADT.require
U64_END = 1 << 64
# physical complex within a die, RegMap ID, provider reg index
BINDINGS = ((0, 9, 6), (1, 21, 15), (2, 33, 26))
ACC_OFFSET = 0xe20020
MAP_OFFSET = 0xe20000
ACCESS_SIZE = 8


def end_address(base: int, size: int) -> int:
    require(size > 0 and base + size < U64_END, "empty or overflowing address window")
    return base + size


def translate(base: int, size: int, ranges: list[tuple[int, int, int]]) -> tuple[int, int]:
    end = end_address(base, size)
    matches = [(i, parent + base - child) for i, (child, parent, length) in enumerate(ranges)
               if child <= base and end <= child + length]
    require(len(matches) == 1, "window needs exactly one containing translation range")
    index, translated = matches[0]
    end_address(translated, size)
    return index, translated


def inspect_adt(data: bytes) -> dict:
    paths = ("/", "/chosen", "/arm-io", "/arm-io/pmgr")
    nodes = ADT.selected_nodes(data, paths)
    root, chosen, arm_io, pmgr = (nodes[p] for p in paths)
    require(ADT.cstring(root.get("target-type", b"")) == "J575d", "unsupported target")
    require(ADT.cstring(root.get("model", b"")) == "Mac15,14", "target/model mismatch")
    # Restore templates may carry a placeholder chip-id; report, don't promote it
    # to live SoC identity or silently require the live 0x6032 value.
    chip = ADT.u32(chosen.get("chip-id", b""))
    for node in (root, arm_io):
        for key in ("#address-cells", "#size-cells"):
            require(ADT.u32(node.get(key, b"")) == 2, "unsupported address/size cells")
    require(ADT.cstring(pmgr.get("compatible", b"")) == "pmgr1,t6031",
            "unsupported PMGR compatible")
    raw_stride = pmgr.get("die-stride", b"")
    require(len(raw_stride) == 8, "expected eight-byte die-stride")
    stride, = struct.unpack("<Q", raw_stride)
    require(stride == 0x2000000000, "unexpected J575d die-stride")
    raw_ranges = arm_io.get("ranges", b"")
    require(0 < len(raw_ranges) <= 64 * 24 and len(raw_ranges) % 24 == 0,
            "malformed or excessive ranges")
    ranges = list(struct.iter_unpack("<QQQ", raw_ranges))
    # The restore template has overlapping ranges unrelated to these windows.
    # Require an unambiguous containing range for each selected window only.
    for child, parent, size in ranges:
        end_address(child, size)
        end_address(parent, size)
    raw_reg = pmgr.get("reg", b"")
    require(len(raw_reg) == 60 * 16, "unexpected J575d PMGR reg length")
    entries = list(struct.iter_unpack("<QQ", raw_reg))
    windows = []
    used_ranges = set()
    for complex_id, map_id, index in BINDINGS:
        base, size = entries[index]
        require(base % ACCESS_SIZE == 0, "unaligned selected PMGR window")
        require(size == 0x11e8, "unexpected selected PMGR window size")
        relative = ACC_OFFSET - MAP_OFFSET
        require(relative + ACCESS_SIZE <= size, "ACC access exceeds selected window")
        range_index, translated = translate(base, size, ranges)
        require(translated % ACCESS_SIZE == 0, "unaligned translated PMGR window")
        for old in windows:
            old_base = int(old["translated_base"], 16)
            require(translated + size <= old_base or old_base + size <= translated,
                    "overlapping selected translated windows")
        used_ranges.add(range_index)
        windows.append({"physical_complex_in_die": complex_id, "regmap_id": map_id,
                        "provider_reg_index": index, "raw_bus_base": hex(base),
                        "size": hex(size), "range_index": range_index,
                        "translated_base": hex(translated),
                        "candidate_pstate_address": hex(translated + relative)})
    # ApplePMGR::initRegMap reuses die-0's physical mapping and adds
    # die-stride * die for subsequent dies. Do not translate the result twice.
    candidates = []
    for die in (0, 1):
        for window in windows:
            base = int(window["translated_base"], 16) + stride * die
            size = int(window["size"], 16)
            end_address(base, size)
            for old in candidates:
                old_base = int(old["window_base"], 16)
                require(base + size <= old_base or old_base + size <= base,
                        "overlapping per-die candidate windows")
            candidates.append({"die": die, "physical_complex_in_die": window["physical_complex_in_die"],
                               "regmap_id": window["regmap_id"], "window_base": hex(base),
                               "pstate_address": hex(base + ACC_OFFSET - MAP_OFFSET)})
    return {"identity": {"target": "J575d", "model": "Mac15,14", "template_chip_id": hex(chip)},
            "pmgr_compatible": "pmgr1,t6031", "die_stride_property": hex(stride),
            "die_stride_applied": "only to per_die_candidates, after ADT translation",
            "reg_entry_count": len(entries), "ranges_entry_count": len(ranges),
            "selected_ranges": [{"index": i, "child": hex(ranges[i][0]),
                                 "parent": hex(ranges[i][1]), "size": hex(ranges[i][2])}
                                for i in sorted(used_ranges)],
            "acc_logical_offset": hex(ACC_OFFSET), "acc_mapping_base": hex(MAP_OFFSET),
            "register_access_bytes": ACCESS_SIZE, "windows": windows,
            "per_die_candidates": candidates,
            "evidence_kind": "restore-template translation plus separately traced binary bindings",
            "scope": "six static candidates; runtime mapping, state policy and early-boot safety unvalidated",
            "hardware_validated": False, "installed_or_executed": False}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path)
    args = parser.parse_args()
    require(stat.S_ISREG(args.input.stat().st_mode), "input must be a regular file")
    with args.input.open("rb") as stream:
        raw = stream.read(ADT.LIMIT + 1)
    data = ADT.decode_im4p(raw)
    report = inspect_adt(data)
    report.update({"schema_version": 1, "input_filename": args.input.name,
                   "im4p_sha256": hashlib.sha256(raw).hexdigest(),
                   "adt_sha256": hashlib.sha256(data).hexdigest(), "adt_size": len(data)})
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError) as exc:
        print(f"firmware DVFS inspection failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
