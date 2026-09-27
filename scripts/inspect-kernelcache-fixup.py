#!/usr/bin/env python3
"""Resolve one format-8, cache-level-0 pointer after proving chain membership.

Offline files only. Not a PAC authenticator, loader, or complete Mach-O verifier.
Unsupported formats, cache levels and multi-start pages fail closed.
"""

import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import stat
import struct

SPEC = importlib.util.spec_from_file_location(
    "inspection", pathlib.Path(__file__).with_name("inspect-local-kernelcache.py"))
INSPECT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSPECT)


def unpack(data, fmt, offset):
    if offset < 0 or offset + struct.calcsize(fmt) > len(data):
        raise ValueError("truncated fixup data")
    return struct.unpack_from(fmt, data, offset)


def segments_and_fixups(data):
    _, commands = INSPECT.commands(data, 0)
    if unpack(data, "<I", 12)[0] != 12:
        raise ValueError("expected fileset")
    segments, fixups = [], []
    for cmd, pos, size in commands:
        if cmd == 0x19:
            if size < 72:
                raise ValueError("short segment")
            name, vm, vmsize, off, length = unpack(data, "<16sQQQQ", pos + 8)
            if off + length > len(data) or length > vmsize:
                raise ValueError("invalid segment extent")
            segments.append((name.split(b"\0")[0].decode("ascii"), vm, off, length))
        elif cmd == 0x80000034:
            if size != 16:
                raise ValueError("invalid fixups command")
            off, length = unpack(data, "<II", pos + 8)
            if off + length > len(data):
                raise ValueError("fixups exceed input")
            fixups.append(data[off:off + length])
    bases = [vm for _, vm, off, length in segments if off == 0 and length >= 32]
    if len(bases) != 1 or len(fixups) != 1:
        raise ValueError("ambiguous collection base or fixups")
    return segments, bases[0], fixups[0]


def mapping(segments, address, size=8):
    matches = [(index, address - vm) for index, (_, vm, _, length) in enumerate(segments)
               if vm <= address and address + size <= vm + length]
    if len(matches) != 1:
        raise ValueError("address must have one file-backed mapping")
    return matches[0]


def resolve(data, address):
    segments, base, blob = segments_and_fixups(data)
    segment_index, within = mapping(segments, address)
    version, starts, _, _, imports, _, _ = unpack(blob, "<7I", 0)
    if version != 0 or imports != 0 or starts < 28:
        raise ValueError("unsupported fixup header")
    count = unpack(blob, "<I", starts)[0]
    if count != len(segments):
        raise ValueError("segment count mismatch")
    offsets = unpack(blob, f"<{count}I", starts + 4)
    if offsets[segment_index] < 4 + 4 * count:
        raise ValueError("segment has no valid starts table")
    pos = starts + offsets[segment_index]
    size, page_size, form, segment_offset, _, pages = unpack(blob, "<IHHQIH", pos)
    if size < 22 + 2 * pages or pos + size > len(blob):
        raise ValueError("invalid segment starts size")
    if form != 8 or page_size not in (0x1000, 0x4000):
        raise ValueError("unsupported pointer format or page size")
    name, vm, fileoff, length = segments[segment_index]
    if segment_offset != vm - base:
        raise ValueError("segment offset does not match VM layout")
    page = within // page_size
    if page >= pages:
        raise ValueError("missing page starts")
    start = unpack(blob, "<H", pos + 22 + 2 * page)[0]
    if start == 0xffff or start & 0x8000:
        raise ValueError("empty or unsupported multi-start page")
    cursor = start
    word = None
    steps = 0
    while True:
        relative = page * page_size + cursor
        if cursor % 4 or cursor + 8 > page_size or relative + 8 > length:
            raise ValueError("chain escapes page or segment")
        current = unpack(data, "<Q", fileoff + relative)[0]
        steps += 1
        if relative == within:
            word = current
        delta = ((current >> 51) & 0xfff) * 4
        if not delta:
            break
        cursor += delta
    if word is None:
        raise ValueError("address is not a chained pointer")
    level = (word >> 30) & 3
    if level != 0:
        raise ValueError("external cache level requires a separate base")
    target = base + (word & ((1 << 30) - 1))
    mapping(segments, target, 1)
    return {"pointer_vmaddr": hex(address), "pointer_fileoff": fileoff + within,
            "segment": name, "page_index": page, "page_chain_entries": steps,
            "pointer_format": form, "cache_level": level, "raw_word": hex(word),
            "chain_membership_validated": True, "collection_base": hex(base),
            "target_vmaddr": hex(target), "authenticated_encoding": bool(word >> 63),
            "pac_authenticated": False, "live_memory_read": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("address", type=lambda value: int(value, 0))
    args = parser.parse_args()
    try:
        descriptor = os.open(args.input, os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise ValueError("input must be a regular file")
            data = stream.read(INSPECT.LIMIT + 1)
        if len(data) > INSPECT.LIMIT:
            raise ValueError("input limit exceeded")
        result = resolve(data, args.address)
        result["input_sha256"] = hashlib.sha256(data).hexdigest()
        print(json.dumps(result, sort_keys=True))
        return 0
    except (OSError, ValueError, struct.error):
        parser.exit(1, "unsupported or invalid offline fixup input\n")


if __name__ == "__main__":
    raise SystemExit(main())
