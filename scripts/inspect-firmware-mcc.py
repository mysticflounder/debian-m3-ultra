#!/usr/bin/env python3
"""Allowlisted, offline MCC geometry from Apple restore-firmware ADTs.

This reads files only. Firmware templates are not live/iBoot-final ADTs;
raw ADT addresses are bus addresses, not permission to access MMIO.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import importlib.util
import json
import pathlib
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
LIMIT = 4 * 1024**2
BOARDS = {"J516c": ("Mac15,9", 3, 8), "J575d": ("Mac15,14", 4, 16)}
HEADER_SIZES = (0x20000, 0x149c, 0x4000, 0x4000)
BANK_SIZE = 0x2000000


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def decode_im4p(raw: bytes) -> bytes:
    require(0 < len(raw) <= LIMIT, "IM4P size outside limit")
    spec = importlib.util.spec_from_file_location("kernelcache_inspector", ROOT / "scripts/inspect-local-kernelcache.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    tag, pos, end = module.tlv(raw, 0, len(raw))
    require(tag == 0x30 and end == len(raw), "expected complete IM4P sequence")
    for expected in (b"IM4P", b"dtre"):
        tag, start, pos = module.tlv(raw, pos, end)
        require(tag == 0x16 and raw[start:pos] == expected, "not a device-tree IM4P")
    tag, _, pos = module.tlv(raw, pos, end)
    require(tag == 0x16, "missing IM4P description")
    tag, start, stop = module.tlv(raw, pos, end)
    require(tag == 4 and raw[start:start + 4] == b"bvx2", "expected unencrypted LZFSE payload")
    compressed = raw[start:stop]
    library = ctypes.CDLL("/usr/lib/libcompression.dylib")
    function = library.compression_decode_buffer
    function.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
                         ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int]
    function.restype = ctypes.c_size_t
    buffer = ctypes.create_string_buffer(LIMIT)
    count = function(buffer, LIMIT, compressed, len(compressed), None, 0x801)
    require(0 < count < LIMIT, "LZFSE decode failed or exceeded limit")
    return ctypes.string_at(buffer, count)


def selected_nodes(data: bytes, paths: tuple[str, ...]) -> dict[str, dict[str, bytes]]:
    """Bounded ADT parser; callers must separately allowlist emitted properties."""
    require(0 < len(data) <= LIMIT, "ADT size outside limit")
    require(bool(paths) and len(paths) == len(set(paths)), "invalid selected paths")
    selected: dict[str, dict[str, bytes]] = {}
    node_count = 0

    def parse_node(pos: int, parent: str, depth: int = 0) -> int:
        nonlocal node_count
        node_count += 1
        require(depth < 64 and node_count <= 20000, "ADT nesting/node limit exceeded")
        require(pos + 8 <= len(data), "truncated ADT node")
        nprop, nchild = struct.unpack_from("<II", data, pos)
        require(nprop <= 4096 and nchild <= 4096, "ADT node count outside limit")
        pos += 8
        props = {}
        for _ in range(nprop):
            require(pos + 36 <= len(data), "truncated ADT property")
            field = data[pos:pos + 32]
            require(b"\0" in field, "unterminated ADT property name")
            encoded_name, padding = field.split(b"\0", 1)
            require(not any(padding), "nonzero ADT property-name padding")
            name = encoded_name.decode("ascii")
            length, = struct.unpack_from("<I", data, pos + 32)
            length &= 0x7fffffff
            pos += 36
            padded = (length + 3) & ~3
            require(name not in props, "duplicate ADT property")
            require(pos + padded <= len(data), "truncated ADT property value")
            props[name] = data[pos:pos + length]
            pos += padded
        name = cstring(props.get("name", b""))
        require("/" not in name and name, "invalid ADT node name")
        require(depth != 0 or name == "device-tree", "unexpected ADT root name")
        path = "/" if depth == 0 else parent.rstrip("/") + "/" + name
        if path in paths:
            require(path not in selected, "duplicate selected ADT node")
            selected[path] = props
        for _ in range(nchild):
            pos = parse_node(pos, path, depth + 1)
        return pos

    consumed = parse_node(0, "")
    require(not any(data[consumed:]), "nonzero trailing ADT data")
    require(set(selected) == set(paths), "missing selected ADT node")
    return selected


def inspect_adt(data: bytes) -> dict:
    selected = selected_nodes(data, ("/", "/chosen", "/arm-io/mcc"))
    root, chosen, mcc = (selected[p] for p in ("/", "/chosen", "/arm-io/mcc"))
    target = cstring(root.get("target-type", b""))
    require(target in BOARDS, "unsupported firmware target")
    model, offset, count = BOARDS[target]
    require(cstring(root.get("model", b"")) == model, "target/model mismatch")
    chip = u32(chosen.get("chip-id", b""))
    compatible = cstring(mcc.get("compatible", b""))
    require(compatible == "mcc,t6031", "unsupported MCC compatible")
    planes = u32(mcc.get("plane-count-per-amcc", b""))
    dcs = u32(mcc.get("dcs-count-per-amcc", b""))
    require(planes == 4 and dcs == 4, "unsupported MCC plane/DCS geometry")
    reg = mcc.get("reg", b"")
    require(len(reg) == (offset + count) * 16, "unexpected MCC reg byte length")
    entries = list(struct.iter_unpack("<QQ", reg))
    for i, (base, size) in enumerate(entries):
        expected = HEADER_SIZES[i] if i < offset else BANK_SIZE
        require(size == expected, "unexpected MCC register window size")
        require(base > 0 and base % 4 == 0, "invalid MCC address alignment")
        # Match the firmware's representable u64 exclusive-end contract.
        require(base + size < 1 << 64, "MCC address wrap")
        for old_base, old_size in entries[:i]:
            require(base + size <= old_base or old_base + old_size <= base, "overlapping MCC windows")
    return {
        "identity": {"target": target, "model": model, "template_chip_id": hex(chip)},
        "mcc": {"compatible": compatible, "planes_per_mcc": planes, "dcs_per_mcc": dcs,
                "reg_entry_count": len(entries), "header_count": offset, "instance_count": count,
                "header_sizes": [hex(size) for _, size in entries[:offset]],
                "instance_indices": list(range(offset, offset + count)),
                "instance_size": hex(BANK_SIZE),
                "raw_bus_windows": [{"index": i, "base": hex(base), "size": hex(size)}
                                    for i, (base, size) in enumerate(entries)]},
        "address_space": "raw ADT bus addresses; not translated MMIO addresses",
        "evidence_kind": "restore firmware template, not live or iBoot-final ADT",
        "hardware_validated": False,
    }


def cstring(raw: bytes) -> str:
    require(raw.endswith(b"\0") and b"\0" not in raw[:-1], "invalid single ADT string")
    return raw[:-1].decode("ascii")


def u32(raw: bytes) -> int:
    require(len(raw) == 4, "expected exact four-byte ADT scalar")
    return int.from_bytes(raw, "little")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", type=pathlib.Path, nargs="+")
    args = parser.parse_args()
    results = []
    for path in args.inputs:
        with path.open("rb") as stream:
            raw = stream.read(LIMIT + 1)
        data = decode_im4p(raw)
        result = inspect_adt(data)
        result.update({"input_filename": path.name, "im4p_sha256": hashlib.sha256(raw).hexdigest(),
                       "adt_sha256": hashlib.sha256(data).hexdigest(), "adt_size": len(data)})
        results.append(result)
    print(json.dumps({"schema_version": 1, "records": results,
                      "installed_or_executed": False}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError) as exc:
        print(f"firmware MCC inspection failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
