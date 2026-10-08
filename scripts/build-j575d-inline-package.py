#!/usr/bin/env python3
"""Assemble retained J575d diagnostic artifacts; never install or boot them."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import platform
import struct
import tempfile
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOADER_TREE = ROOT / "scratch/m1n1-upstream-xz-seek-guards.m9h56j/m1n1-2460b604c6f016956ead711823605eea840c602e"
KERNEL_TREE = ROOT / "scratch/linux-j575d-kernel.HdzQNm"
INPUTS = {
    "loader": (LOADER_TREE / "build/m1n1.bin", "edb04ff16c0e467a6179392ac99674faa59005aeb9b89c9e062f8305fcb154cb"),
    "loader_elf": (LOADER_TREE / "build/m1n1-raw.elf", "67827c952c4e79268960597e31afd3f344fe1dd22d2854555bd5781ea0dc3b04"),
    "image": (KERNEL_TREE / "build/arch/arm64/boot/Image", "ad9b573e66738d13d7758619809cc7e8ff09cf9498e23ccec352dfe42b285f50"),
    "initramfs": (ROOT / "scratch/j575d-initramfs.lQ4Gr7/output/initramfs.cpio.gz", "7bfb73c02f74a285f6defb02741b85cb880fdbeb7d4a27f458c4c32b62383f30"),
}
BOARDS = {
    "candidate": (ROOT / "scratch/m1n1-board-dt/t6032-j575d.dtb", "e92e5c9dc86731d76dc060759bb622cbad073e4e32e831bf0ca68deef3ff4cd5"),
    "official": (KERNEL_TREE / "build/arch/arm64/boot/dts/apple/t6032-j575d.dtb", "abd4d0760dabe647048cb3c4ea3e68116e37fcb9dcdb022ded29449d6c43ee79"),
}
BOOTARGS = "earlycon console=ttySAC0 rdinit=/init"
INITRAMFS_MAGIC = b"m1n1_initramfs"  # 14 bytes, no NUL terminator.


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_record(path: Path) -> dict:
    data = path.read_bytes()
    return {"path": str(path.relative_to(ROOT)), "length": len(data), "sha256": digest(data)}


def checked_input(path: Path, expected: str) -> bytes:
    data = path.read_bytes()
    if digest(data) != expected:
        raise ValueError(f"retained input changed: {path}")
    return data


def image_header(image: bytes) -> dict:
    if image[0x38:0x3C] != b"ARM\x64":
        raise ValueError("expected the pinned arm64 Image header")
    offset, size, flags = struct.unpack_from("<QQQ", image, 8)
    if (offset, size, flags) != (0, 44040192, 0xC) or len(image) != 43010560:
        raise ValueError("unexpected pinned Image layout")
    return {
        "text_offset": offset,
        "image_size": size,
        "flags": flags,
        "file_size": len(image),
        "loader_reserved_tail_bytes": size - len(image),
        "page_size": 16384,
        "image_base_alignment": 2097152,
        "tail_zero_fill_proven": False,
    }


def run() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--board", choices=BOARDS, default="candidate")
    parser.add_argument("--bootargs", default=BOOTARGS)
    args = parser.parse_args()
    bootargs = args.bootargs.encode("ascii")
    if not bootargs or b"\n" in bootargs or b"\r" in bootargs or b"\0" in bootargs or len(bootargs) >= 1024:
        raise ValueError("bootargs must be a nonempty single ASCII line shorter than 1024 bytes")

    selected = {**INPUTS, "dtb": BOARDS[args.board]}
    data = {name: checked_input(path, expected) for name, (path, expected) in selected.items()}
    # The pinned raw ELF's _base=0, _end=_payload_start=0x3b0000. Its exact
    # hash binds those observed symbols; objcopy's raw prefix ends there.
    if len(data["loader"]) != 0x3B0000:
        raise ValueError("raw loader EOF no longer matches the pinned _payload_start")
    header = image_header(data["image"])
    magic, dtb_size = struct.unpack_from(">II", data["dtb"])
    if magic != 0xD00DFEED or dtb_size != len(data["dtb"]):
        raise ValueError("DTB must occupy exactly its declared FDT span")
    if not gzip.decompress(data["initramfs"]).startswith(b"070701"):
        raise ValueError("expected the retained gzip/newc module initramfs")

    compressed = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=compressed, mtime=0, compresslevel=9) as stream:
        stream.write(data["image"])
    image_gz = compressed.getvalue()
    wrapper = INITRAMFS_MAGIC + struct.pack("<I", len(data["initramfs"])) + data["initramfs"]
    pieces = [
        ("chosen.bootargs", b"chosen.bootargs=" + bootargs + b"\n"),
        ("gzip.Image", image_gz),
        ("dtb", data["dtb"]),
        ("m1n1_initramfs", wrapper),
        ("zero_terminal", bytes(64)),
    ]
    payload = b"".join(content for _, content in pieces)
    out = Path(tempfile.mkdtemp(prefix="j575d-inline-package.", dir=ROOT / "scratch"))
    (out / "Image.gz").write_bytes(image_gz)
    (out / "initramfs.wrapper").write_bytes(wrapper)
    (out / "payload.bin").write_bytes(payload)
    (out / "UNQUALIFIED-m1n1-inline.bin").write_bytes(data["loader"] + payload)
    components, offset = [], 0
    for kind, content in pieces:
        components.append({"kind": kind, "offset": offset, "length": len(content), "sha256": digest(content)})
        offset += len(content)
    manifest = {
        "schema": "j575d-inline-package-v1",
        "scope": "artifact assembly only; not a native boot or hardware qualification",
        "native_boot_approved": False,
        "loader_role": "retained full32 comparison artifact; does not replace the default loader",
        "board": args.board,
        "candidate_schema_diagnostics_remain": args.board == "candidate",
        "m1n1_revision": "2460b604c6f016956ead711823605eea840c602e",
        "linux_revision": "602042bf29f6efde39cfb5fdd9289bf4854bc0c5",
        "inputs": {name: file_record(path) for name, (path, _) in selected.items()},
        "recipe": file_record(Path(__file__).resolve()),
        "image_header": header,
        "bootargs": args.bootargs,
        "inline_payload_offset": len(data["loader"]),
        "raw_prefix_contract": {
            "base": 0,
            "end": 0x3B0000,
            "payload_start": 0x3B0000,
            "evidence": "canonical symbols in the hash-pinned m1n1-raw.elf; not a physical placement claim",
        },
        "components": components,
        "outputs": {name: file_record(out / name) for name in ("Image.gz", "initramfs.wrapper", "payload.bin", "UNQUALIFIED-m1n1-inline.bin")},
        "compression": {"python": platform.python_version(), "zlib": zlib.ZLIB_RUNTIME_VERSION, "mtime": 0, "level": 9},
        "remaining_native_contracts": [
            "verified backup, recovery readiness and separate native-action approval",
            "readable inline source backing through the firmware handoff extent",
            "disjoint source and decompression spans in usable mapped RAM",
            "physical Image/DTB/initrd placement and Linux entry/cache/MMU state",
            "post-fixup memory/reservations and live CPU release visibility",
            "physical SoC power, IRQ, DMA, RTKit firmware and storage behavior",
        ],
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (out / "README.txt").write_text(
        "NOT BOOT APPROVED. Build/package only; do not install or boot this comparison artifact.\n"
        "No firmware, NVRAM, partitions, devices or persistent VMs were changed.\n"
        "payload.bin starts at chosen.bootargs; inline file prepends the retained raw loader.\n"
        "Components are contiguous: do not insert alignment padding between them.\n"
        "The original Image is compressed unchanged; the loader reserves its declared tail.\n"
        "The DTB still contains loader placeholders. Native backing and entry remain unqualified.\n"
    )
    print(f"Assembled {args.board} package: {out.relative_to(ROOT)}")
    print(f"Manifest: {(out / 'manifest.json').relative_to(ROOT)}")
    print("Scope: assembly only; NOT BOOT APPROVED; no installation or launch")
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
