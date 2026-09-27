#!/usr/bin/env python3
"""Offline IM4P/LZFSE decoding and fileset inspection views, never installation.

Views preserve original file offsets but replace the outer header. They are
for nm/otool/objdump only, NOT reconstructed or loadable kernel extensions.
Outputs must be new files under this project's scratch/ directory. No keys,
signature bypass, kernel service, driver loading, or live memory access.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import pathlib
import stat
import struct

ROOT = pathlib.Path(__file__).resolve().parents[1]
LIMIT = 256 * 1024 * 1024


def tlv(data: bytes, pos: int, limit: int) -> tuple[int, int, int]:
    if not 0 <= pos <= limit <= len(data) or pos + 2 > limit:
        raise ValueError("truncated DER header")
    tag, size = data[pos:pos + 2]
    pos += 2
    if size & 0x80:
        count = size & 0x7f
        if not 1 <= count <= 4 or pos + count > limit:
            raise ValueError("invalid DER length")
        size = int.from_bytes(data[pos:pos + count], "big")
        pos += count
    if pos + size > limit:
        raise ValueError("truncated DER value")
    return tag, pos, pos + size


def payload(data: bytes) -> tuple[int, bytes]:
    tag, pos, limit = tlv(data, 0, len(data))
    if tag != 0x30 or limit != len(data):
        raise ValueError("expected one complete DER sequence")
    tag, start, end = tlv(data, pos, limit)
    if tag == 0x16 and data[start:end] == b"IMG4":
        tag, pos, limit = tlv(data, end, limit)
        if tag != 0x30:
            raise ValueError("missing nested IM4P")
    for expected in (b"IM4P", b"krnl"):
        tag, start, pos = tlv(data, pos, limit)
        if tag != 0x16 or data[start:pos] != expected:
            raise ValueError("unexpected IM4P type")
    tag, _, pos = tlv(data, pos, limit)
    if tag != 0x16:
        raise ValueError("missing IM4P description")
    tag, start, end = tlv(data, pos, limit)
    if tag != 4 or end - start < 4 or data[start:start + 4] != b"bvx2":
        raise ValueError("expected unencrypted LZFSE payload")
    return start, data[start:end]


def decode(data: bytes) -> tuple[bytes, dict]:
    offset, compressed = payload(data)
    library = ctypes.CDLL("/usr/lib/libcompression.dylib")
    function = library.compression_decode_buffer
    function.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
                         ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int]
    function.restype = ctypes.c_size_t
    buffer = ctypes.create_string_buffer(LIMIT)
    count = function(buffer, LIMIT, compressed, len(compressed), None, 0x801)
    # Apple's API returns capacity on truncation: never accept that as success.
    if not 0 < count < LIMIT:
        raise ValueError("decode failed or output limit reached")
    result = ctypes.string_at(buffer, count)
    if result[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("decoded payload is not Mach-O 64 little endian")
    commands(result, 0)
    return result, {"payload_offset": offset, "signature_verified": False}


def commands(data: bytes, offset: int) -> tuple[int, list[tuple[int, int, int]]]:
    if not 0 <= offset <= len(data) - 32:
        raise ValueError("truncated Mach-O header")
    fields = struct.unpack_from("<8I", data, offset)
    if fields[0] != 0xfeedfacf or fields[4] > 4096:
        raise ValueError("invalid Mach-O header")
    end = offset + 32 + fields[5]
    if end > len(data):
        raise ValueError("truncated load commands")
    entries = []
    pos = offset + 32
    for _ in range(fields[4]):
        if pos + 8 > end:
            raise ValueError("truncated load command")
        cmd, size = struct.unpack_from("<II", data, pos)
        if size < 8 or pos + size > end:
            raise ValueError("invalid load command")
        entries.append((cmd, pos, size))
        pos += size
    if pos != end:
        raise ValueError("load-command size mismatch")
    return end, entries


def view(data: bytes, entry_id: str) -> tuple[bytes, dict]:
    _, entries = commands(data, 0)
    if struct.unpack_from("<I", data, 12)[0] != 12:  # MH_FILESET
        raise ValueError("expected MH_FILESET")
    found = []
    for cmd, pos, size in entries:
        if cmd != 0x80000035:  # LC_FILESET_ENTRY
            continue
        if size < 32:
            raise ValueError("truncated fileset entry")
        vmaddr, fileoff, nameoff, _ = struct.unpack_from("<QQII", data, pos + 8)
        if not 32 <= nameoff < size:
            raise ValueError("invalid fileset name offset")
        raw_name = data[pos + nameoff:pos + size]
        if b"\0" not in raw_name:
            raise ValueError("unterminated fileset name")
        if raw_name.split(b"\0", 1)[0].decode("ascii") == entry_id:
            found.append((fileoff, vmaddr))
    if len(found) != 1:
        raise ValueError("entry not unique")
    offset, vmaddr = found[0]
    end, entries = commands(data, offset)
    replacement = data[offset:end]
    for cmd, pos, size in entries:
        if cmd == 0x19:  # LC_SEGMENT_64
            if size < 72:
                raise ValueError("truncated segment")
            fileoff, filesize = struct.unpack_from("<QQ", data, pos + 40)
            if filesize and (fileoff < len(replacement) or fileoff + filesize > len(data)):
                raise ValueError("segment overlaps replacement header or exceeds input")
    return replacement + data[len(replacement):], {
        "entry_id": entry_id, "entry_fileoff": offset, "entry_vmaddr": hex(vmaddr),
        "inspection_only_not_loadable": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("decode", "view"))
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--entry")
    args = parser.parse_args()
    try:
        scratch = ROOT / "scratch"
        output = args.output.resolve()
        if (scratch.is_symlink() or not scratch.resolve().is_relative_to(ROOT.resolve())
                or not output.is_relative_to(scratch.resolve()) or output.exists()):
            raise ValueError("output must be a new project scratch file")
        if bool(args.entry) != (args.mode == "view"):
            raise ValueError("--entry is required only in view mode")
        # Nonblocking open avoids hanging on a FIFO before fstat can reject it.
        descriptor = os.open(args.input, os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as source:
            if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                raise ValueError("input must be a regular file")
            data = source.read(LIMIT + 1)
        if len(data) > LIMIT:
            raise ValueError("input limit reached")
        result, details = decode(data) if args.mode == "decode" else view(data, args.entry)
        with output.open("xb") as stream:
            stream.write(result)
        print(json.dumps({"mode": args.mode, "input_sha256": hashlib.sha256(data).hexdigest(),
                          "output_sha256": hashlib.sha256(result).hexdigest(),
                          "output_bytes": len(result), "output": str(output), **details}, sort_keys=True))
        return 0
    except (OSError, ValueError, struct.error, AttributeError) as exc:
        parser.exit(1, f"offline inspection: {exc}\n")


if __name__ == "__main__":
    raise SystemExit(main())
