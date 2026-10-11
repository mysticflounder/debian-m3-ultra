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
FORK_TREE = ROOT / "scratch/m1n1-fork.xd2NO8"
FORK_INPUTS = {
    "loader": (FORK_TREE / "build/m1n1.bin", "7c1c0ef40b0ce7a578fd3fba74333655f89f3ee234968db44ae3fde4e0ba1c70"),
    "loader_elf": (FORK_TREE / "build/m1n1-raw.elf", "427d01dc8df26aa9d9f56e5593b50dbc7a26b72f6f840039d2921b5b24f22d7a"),
    "image": INPUTS["image"],
    "initramfs": (ROOT / "scratch/j575d-initramfs.AxUPO0/output/initramfs.cpio.gz", "807b823e87a53304106e5f49e48ed5fc918040f21570cbc77e87df26df5613ee"),
}
FORK_BOARDS = {
    "official": BOARDS["official"],
    "event": (ROOT / "scratch/j575d-usb2-event-dt.93istlf1/candidate.dtb", "be4ab6f0f5dcd508a5aa25df4e7692246715ce356142b2c8bcc9b1aff1dab861"),
}
PROFILES = {
    "historical": {"inputs": INPUTS, "boards": BOARDS},
    "fork-current": {"inputs": FORK_INPUTS, "boards": FORK_BOARDS},
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


def elf_symbols(elf: bytes) -> dict[str, int]:
    """Read the small set of ELF symbols needed for the raw-prefix contract."""
    if len(elf) < 64 or elf[:4] != b"\x7fELF" or elf[4:6] != b"\x02\x01":
        raise ValueError("expected a little-endian ELF64 raw loader")
    header = struct.unpack_from("<16sHHIQQQIHHHHHH", elf, 0)
    _, _, _, _, _, _, shoff, _, _, _, _, shentsize, shnum, shstrndx = header
    if shentsize < 64 or shoff + shentsize * shnum > len(elf):
        raise ValueError("invalid ELF section table")
    sections = [struct.unpack_from("<IIQQQQIIQQ", elf, shoff + i * shentsize)
                for i in range(shnum)]
    found: dict[str, int] = {}
    for sec in sections:
        _, sh_type, _, _, sec_off, sec_size, link, _, _, entsize = sec
        if sh_type not in (2, 11) or entsize < 24 or sec_off + sec_size > len(elf):
            continue
        if link >= len(sections):
            raise ValueError("invalid ELF symbol string-table link")
        strsec = sections[link]
        str_off, str_size = strsec[4], strsec[5]
        strings = elf[str_off:str_off + str_size]
        for pos in range(sec_off, sec_off + sec_size, entsize):
            name_off, _, _, _, value, _ = struct.unpack_from("<IBBHQQ", elf, pos)
            if name_off < len(strings):
                end = strings.find(b"\0", name_off)
                name = strings[name_off:end if end >= 0 else len(strings)].decode("ascii", "ignore")
                if name in {"_base", "_end", "_payload_start"}:
                    found[name] = value
    return found


def profile_config(name: str) -> dict:
    try:
        return PROFILES[name]
    except KeyError as exc:
        raise ValueError(f"unknown package profile: {name}") from exc


def board_metadata(board: str) -> dict:
    if board == "event":
        return {
            "board_role": "explicit event candidate; retained PHY disabled state; no automatic enablement",
            "candidate_schema_diagnostics_remain": True,
        }
    if board == "candidate":
        return {"candidate_schema_diagnostics_remain": True}
    return {
        "board_role": "official kernel board DTB; no event-candidate substitution",
        "candidate_schema_diagnostics_remain": False,
    }


def raw_prefix_contract(symbols: dict[str, int], loader_length: int) -> dict:
    required = {"_base", "_end", "_payload_start"}
    missing = sorted(required - symbols.keys())
    if missing:
        raise ValueError(f"raw ELF missing required symbols: {', '.join(missing)}")
    if symbols["_base"] != 0 or symbols["_end"] != symbols["_payload_start"]:
        raise ValueError("raw ELF symbols do not define a contiguous raw prefix")
    if loader_length != symbols["_payload_start"] - symbols["_base"]:
        raise ValueError("raw loader EOF no longer matches ELF _payload_start")
    return {
        "base": symbols["_base"],
        "end": symbols["_end"],
        "payload_start": symbols["_payload_start"],
        "evidence": "canonical symbols parsed from the hash-pinned raw ELF; not a physical placement claim",
    }


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
    parser.add_argument("--profile", choices=PROFILES, default="historical")
    parser.add_argument("--board")
    parser.add_argument("--bootargs", default=BOOTARGS)
    args = parser.parse_args()
    profile = profile_config(args.profile)
    if args.board is None:
        args.board = "candidate" if args.profile == "historical" else "official"
    if args.board not in profile["boards"]:
        raise ValueError(f"board {args.board!r} is not available in profile {args.profile!r}")
    bootargs = args.bootargs.encode("ascii")
    if not bootargs or b"\n" in bootargs or b"\r" in bootargs or b"\0" in bootargs or len(bootargs) >= 1024:
        raise ValueError("bootargs must be a nonempty single ASCII line shorter than 1024 bytes")

    selected = {**profile["inputs"], "dtb": profile["boards"][args.board]}
    data = {name: checked_input(path, expected) for name, (path, expected) in selected.items()}
    symbols = elf_symbols(data["loader_elf"])
    prefix_contract = raw_prefix_contract(symbols, len(data["loader"]))
    board_info = board_metadata(args.board)
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
        "candidate_schema_diagnostics_remain": board_info["candidate_schema_diagnostics_remain"],
        "m1n1_revision": "2460b604c6f016956ead711823605eea840c602e" if args.profile == "historical" else "b4f5284e193489ffcb7bce399443966f67d929df",
        "linux_revision": "602042bf29f6efde39cfb5fdd9289bf4854bc0c5",
        "inputs": {name: file_record(path) for name, (path, _) in selected.items()},
        "recipe": file_record(Path(__file__).resolve()),
        "image_header": header,
        "bootargs": args.bootargs,
        "inline_payload_offset": len(data["loader"]),
        "raw_prefix_contract": prefix_contract,
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
    if args.profile == "fork-current":
        manifest.update({
            "profile": "fork-current",
            "source": {
                "repository": "scratch/m1n1-fork.xd2NO8",
                "code_commit": "b4f5284e193489ffcb7bce399443966f67d929df",
                "fork_head": "b91ede42c1eabe5feaebe575df0016191f003ac5",
            },
            **board_info,
            "qualification": "UNQUALIFIED",
            "raw_elf_symbols": {name: hex(value) for name, value in symbols.items()},
        })
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
