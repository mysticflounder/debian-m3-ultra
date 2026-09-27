#!/usr/bin/env python3
"""Offline, bounded structural inspector for Apple IM4P boot payloads.

This tool parses the container and reports hashes.  Decompression is opt-in;
the decoded bytes are written only to a new directory below this repository's
scratch/ tree.  No firmware is executed or interpreted as code.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import pathlib
from typing import Any


LIMIT = 4 * 1024 * 1024
DECODE_LIMIT = 16 * 1024 * 1024
COMPRESSION_MARKER = 1
REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRATCH_ROOT = REPO_ROOT / "scratch"


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def _tlv(data: bytes, offset: int, limit: int) -> tuple[int, int, int, int]:
    """Read one strict, definite-length, low-tag-number DER TLV."""
    _require(0 <= offset < limit, "truncated DER tag")
    tag = data[offset]
    _require(tag & 0x1F != 0x1F, "high-tag-number DER is not supported")
    position = offset + 1
    _require(position < limit, "truncated DER length")
    first = data[position]
    position += 1
    if first & 0x80:
        count = first & 0x7F
        _require(1 <= count <= 4, "invalid DER length")
        _require(position + count <= limit, "truncated DER length")
        length_bytes = data[position:position + count]
        _require(length_bytes[0] != 0, "nonminimal DER length")
        length = int.from_bytes(length_bytes, "big")
        _require(length >= 0x80, "nonminimal DER length")
        position += count
    else:
        length = first
    end = position + length
    _require(end <= limit, "truncated DER value")
    return tag, position, end, end


def _ia5(data: bytes, start: int, end: int, label: str) -> bytes:
    value = data[start:end]
    _require(1 <= len(value) <= 128, f"invalid {label} length")
    _require(all(0x20 <= byte <= 0x7E for byte in value),
             f"{label} is not printable ASCII")
    return value


def _nonnegative_integer(data: bytes, start: int, end: int, label: str) -> int:
    value = data[start:end]
    _require(value, f"empty {label} integer")
    _require(value[0] & 0x80 == 0, f"negative {label} integer")
    if len(value) > 1:
        _require(not (value[0] == 0 and value[1] < 0x80),
                 f"nonminimal {label} integer")
    return int.from_bytes(value, "big")


def _parse_optional_payp(data: bytes, start: int, end: int) -> None:
    """Validate the optional A0 wrapper without interpreting its opaque body."""
    tag, sequence_start, sequence_end, next_offset = _tlv(data, start, end)
    _require(tag == 0x30 and next_offset == end, "malformed A0 trailer sequence")
    if sequence_start == sequence_end:
        return
    tag, value_start, value_end, position = _tlv(data, sequence_start, sequence_end)
    _require(tag == 0x16 and data[value_start:value_end] == b"PAYP",
             "malformed A0 PAYP trailer")
    if position < sequence_end:
        # The remaining PAYP record is intentionally opaque; only its DER
        # envelope and bounded extent are checked.
        _, _, _, position = _tlv(data, position, sequence_end)
        _require(position == sequence_end, "trailing bytes in A0 PAYP trailer")


def parse_container(data: bytes) -> dict[str, Any]:
    """Parse one complete IM4P container and return structural metadata."""
    _require(isinstance(data, bytes), "container must be bytes")
    _require(0 < len(data) <= LIMIT, "container exceeds 4 MiB limit")
    tag, outer_start, outer_end, next_offset = _tlv(data, 0, len(data))
    _require(tag == 0x30 and next_offset == len(data),
             "expected one complete DER sequence")
    position = outer_start

    tag, value_start, value_end, position = _tlv(data, position, outer_end)
    _require(tag == 0x16 and data[value_start:value_end] == b"IM4P",
             "missing IM4P type")

    tag, value_start, value_end, position = _tlv(data, position, outer_end)
    _require(tag == 0x16 and data[value_start:value_end] in (b"ibot", b"illb"),
             "unsupported IM4P payload type")
    payload_type = data[value_start:value_end].decode("ascii")

    tag, value_start, value_end, position = _tlv(data, position, outer_end)
    _require(tag == 0x16, "missing IM4P description")
    description = _ia5(data, value_start, value_end, "IM4P description").decode("ascii")

    tag, payload_start, payload_end, position = _tlv(data, position, outer_end)
    _require(tag == 0x04, "missing IM4P payload")
    _require(payload_end - payload_start >= 4 and data[payload_start:payload_start + 4] == b"bvx2",
             "expected bvx2 payload")

    tag, trailer_start, trailer_end, position = _tlv(data, position, outer_end)
    _require(tag == 0x30, "missing IM4P size trailer")
    trailer_position = trailer_start
    integers: list[int] = []
    for label in ("compression marker", "decoded size"):
        integer_tag, value_start, value_end, trailer_position = _tlv(
            data, trailer_position, trailer_end
        )
        _require(integer_tag == 2, f"missing {label} integer")
        integers.append(_nonnegative_integer(data, value_start, value_end, label))
    _require(trailer_position == trailer_end, "extra fields in IM4P size trailer")
    compression_marker, decoded_size = integers
    _require(compression_marker == COMPRESSION_MARKER, "unknown compression marker")
    _require(0 < decoded_size < DECODE_LIMIT, "decoded size exceeds 16 MiB limit")

    if position < outer_end:
        tag, trailer_start, trailer_end, position = _tlv(data, position, outer_end)
        _require(tag == 0xA0, "unexpected IM4P trailing field")
        _parse_optional_payp(data, trailer_start, trailer_end)
    _require(position == outer_end, "trailing bytes in IM4P container")

    return {
        "type": payload_type,
        "description": description,
        "payload_offset": payload_start,
        "payload_size": payload_end - payload_start,
        "decoded_size": decoded_size,
        "compression_marker": compression_marker,
    }


def _load_compression() -> Any:
    return ctypes.CDLL("/usr/lib/libcompression.dylib")


def decode_payload(data: bytes, info: dict[str, Any]) -> bytes:
    """Decode bvx2 through libcompression into a bounded output buffer."""
    _require(0 < len(data) <= LIMIT, "container exceeds 4 MiB limit")
    _require(0 < info["decoded_size"] < DECODE_LIMIT,
             "decoded size exceeds 16 MiB limit")
    offset = info["payload_offset"]
    size = info["payload_size"]
    _require(info["compression_marker"] == COMPRESSION_MARKER,
             "unknown compression marker")
    _require(size >= 4 and 0 <= offset <= len(data) and offset + size <= len(data),
             "payload range is outside container")
    payload = data[offset:offset + size]
    _require(payload[:4] == b"bvx2", "expected bvx2 payload")

    library = _load_compression()
    decoder = library.compression_decode_buffer
    decoder.argtypes = [
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    decoder.restype = ctypes.c_size_t
    output = ctypes.create_string_buffer(DECODE_LIMIT)
    source = ctypes.create_string_buffer(payload)
    returned = decoder(output, DECODE_LIMIT, source, len(payload), None, 0x801)
    _require(0 < returned < DECODE_LIMIT, "decompression failed or output limit reached")
    _require(returned == info["decoded_size"], "decoded size disagrees with metadata")
    return output.raw[:returned]


def validate_output_dir(path: str | pathlib.Path) -> pathlib.Path:
    """Return a new, resolved output directory strictly below repository scratch/."""
    _require(not SCRATCH_ROOT.is_symlink() and SCRATCH_ROOT.resolve() == SCRATCH_ROOT,
             "repository scratch/ must not redirect through a symlink")
    candidate = pathlib.Path(path)
    if not candidate.is_absolute():
        candidate = REPO_ROOT / candidate
    _require(not candidate.exists() and not candidate.is_symlink(),
             "output directory already exists")
    resolved = candidate.resolve()
    _require(resolved != SCRATCH_ROOT and SCRATCH_ROOT in resolved.parents,
             "output directory must be below repository scratch/")
    return resolved


def _read_input(path: pathlib.Path) -> bytes:
    _require(not path.is_symlink(), "input symlink is not allowed")
    _require(path.is_file(), "input is not a regular file")
    size = path.stat().st_size
    _require(size <= LIMIT, "input exceeds 4 MiB limit")
    with path.open("rb") as stream:
        data = stream.read(LIMIT + 1)
    _require(len(data) <= LIMIT, "input exceeds 4 MiB limit")
    _require(len(data) == size, "input changed while being read")
    return data


def _report(path: pathlib.Path, data: bytes, info: dict[str, Any]) -> dict[str, Any]:
    payload = data[info["payload_offset"]:info["payload_offset"] + info["payload_size"]]
    return {
        "input": str(path),
        "container_bytes": len(data),
        "container_sha256": hashlib.sha256(data).hexdigest(),
        "container_sha384": hashlib.sha384(data).hexdigest(),
        **info,
        "payload_sha256": hashlib.sha256(payload).hexdigest(),
        "payload_sha384": hashlib.sha384(payload).hexdigest(),
        "decoded_sha256": None,
        "decoded_sha384": None,
        "decoded_first16_hex": None,
        "decoded": False,
        "installed_or_executed": False,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("--output-dir", type=pathlib.Path,
                        help="new directory below repository scratch/; enables decode")
    args = parser.parse_args(argv)

    data = _read_input(args.input)
    info = parse_container(data)
    report = _report(args.input, data, info)
    if args.output_dir is not None:
        output_dir = validate_output_dir(args.output_dir)
        decoded = decode_payload(data, info)
        report.update({
            "decoded_sha256": hashlib.sha256(decoded).hexdigest(),
            "decoded_sha384": hashlib.sha384(decoded).hexdigest(),
            "decoded_first16_hex": decoded[:16].hex(),
            "decoded_bytes": len(decoded),
            "decoded": True,
            "output_dir": str(output_dir),
        })
        payload_output = output_dir / f"{args.input.stem}.bin"
        report_output = output_dir / f"{args.input.stem}.json"
        _require(not payload_output.exists() and not report_output.exists(),
                 "output file already exists")
        output_dir.mkdir(parents=True, exist_ok=False)
        with payload_output.open("xb") as output:
            output.write(decoded)
        with report_output.open("x") as output:
            json.dump(report, output, indent=2)
            output.write("\n")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
