#!/usr/bin/env python3
"""Plan the inert archive inputs used by the J575d boot-stub installer.

This utility only reads a BuildManifest plist and a ZIP inventory.  It does
not open, extract, mount, personalize, bless, or install anything.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import sys
from pathlib import Path


EXPECTED = {
    "board": "0x44",
    "chip": "0x6032",
    "device": "j575dap",
    "variant": "macOS Customer",
    "behavior": "Erase",
    "build": "26A428",
    "product": "27.0",
}
SKIP_KEYS = {
    "BaseSystem",
    "OS",
    "Ap,SystemVolumeCanonicalMetadata",
    "RestoreRamDisk",
    "RestoreTrustCache",
}
ROOT_FILES = {
    "BuildManifest.plist": "build_manifest_input",
    "SystemVersion.plist": "system_version",
    "RestoreVersion.plist": "restore_version",
    "PlatformSupport.plist": "platform_support",
    "usr/standalone/bootcaches.plist": "bootcaches",
    "BootabilityBundle/Restore/Firmware/Bootability.dmg.trustcache":
        "bootability_trustcache",
}
PREFIXES = {
    "BootabilityBundle/Restore/Bootability/": "bootability_tree",
    "Firmware/Manifests/restore/macOS Customer/": "restore_manifest_tree",
}
CRC_RE = re.compile(r"^[0-9a-fA-F]{8}$")


def safe_member(path: object) -> str:
    if not isinstance(path, str) or not path:
        raise ValueError("ZIP member path must be a non-empty string")
    if "\x00" in path or "\\" in path:
        raise ValueError(f"unsafe ZIP member path: {path!r}")
    if path.startswith("/") or any(part in ("", ".", "..") for part in path.rstrip("/").split("/")):
        raise ValueError(f"unsafe ZIP member path: {path!r}")
    return path


def _size(value: object, field: str, path: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"bad {field} for ZIP member {path!r}")
    return value


def _crc(value: object, path: str) -> str:
    if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= 0xFFFFFFFF:
        return f"{value:08x}"
    if isinstance(value, str) and CRC_RE.fullmatch(value):
        return value.lower()
    raise ValueError(f"bad crc32 for ZIP member {path!r}")


def index_by_path(raw: object) -> dict[str, dict]:
    if not isinstance(raw, list):
        raise ValueError("ZIP index must be a list of rows")
    result: dict[str, dict] = {}
    for row in raw:
        if not isinstance(row, dict):
            raise ValueError("ZIP index row must be an object")
        path = safe_member(row.get("path"))
        if path in result:
            raise ValueError(f"duplicate ZIP member name: {path!r}")
        is_dir = row.get("is_dir")
        if not isinstance(is_dir, bool):
            raise ValueError(f"bad is_dir for ZIP member {path!r}")
        size = _size(row.get("bytes"), "bytes", path)
        compressed = _size(row.get("compressed_bytes"), "compressed_bytes", path)
        if is_dir and (size != 0 or compressed != 0):
            raise ValueError(f"directory has non-zero size: {path!r}")
        result[path] = {
            "path": path,
            "bytes": size,
            "compressed_bytes": compressed,
            "crc32": _crc(row.get("crc32"), path),
            "is_dir": is_dir,
        }
    return result


def _required(index: dict[str, dict], path: str) -> dict:
    row = index.get(path)
    if row is None or row["is_dir"]:
        raise ValueError(f"missing required ZIP file: {path}")
    return row


def _item(row: dict, *roles: str) -> dict:
    return {
        "path": row["path"],
        "bytes": row["bytes"],
        "compressed_bytes": row["compressed_bytes"],
        "crc32": row["crc32"],
        "roles": list(roles),
    }


def select_identity(manifest: dict) -> tuple[int, dict]:
    if manifest.get("ProductBuildVersion") != EXPECTED["build"]:
        raise ValueError("manifest ProductBuildVersion is not pinned to 26A428")
    if manifest.get("ProductVersion") != EXPECTED["product"]:
        raise ValueError("manifest ProductVersion is not pinned to 27.0")
    identities = manifest.get("BuildIdentities")
    if not isinstance(identities, list):
        raise ValueError("manifest has no BuildIdentities list")
    found: list[tuple[int, dict]] = []
    def numeric_id(value: object, expected: str) -> bool:
        try:
            if isinstance(value, bool):
                return False
            if isinstance(value, int):
                return value == int(expected, 16)
            if isinstance(value, str):
                return int(value, 0) == int(expected, 16)
        except ValueError:
            pass
        return False

    for pos, identity in enumerate(identities):
        if not isinstance(identity, dict):
            continue
        info = identity.get("Info", {})
        if not isinstance(info, dict):
            continue
        if (
            numeric_id(identity.get("ApBoardID"), EXPECTED["board"])
            and numeric_id(identity.get("ApChipID"), EXPECTED["chip"])
            and info.get("DeviceClass") == EXPECTED["device"]
            and info.get("Variant") == EXPECTED["variant"]
            and info.get("RestoreBehavior") == EXPECTED["behavior"]
            and info.get("BuildNumber") == EXPECTED["build"]
        ):
            found.append((pos, identity))
    if len(found) != 1:
        raise ValueError(f"expected exactly one pinned build identity, found {len(found)}")
    return found[0]


def make_plan(manifest: dict, raw_index: object) -> dict:
    identity_pos, identity = select_identity(manifest)
    index = index_by_path(raw_index)
    base_info = identity.get("Manifest", {}).get("BaseSystem", {}).get("Info", {})
    base_path = base_info.get("Path") if isinstance(base_info, dict) else None
    base_path = safe_member(base_path)
    base_row = _required(index, base_path)

    rows: dict[str, dict] = {}
    roles: dict[str, list[str]] = {}

    def add(row: dict, role: str) -> None:
        path = row["path"]
        if path not in rows:
            rows[path] = row
            roles[path] = []
        if role not in roles[path]:
            roles[path].append(role)

    for path, role in ROOT_FILES.items():
        add(_required(index, path), role)
    for prefix, role in PREFIXES.items():
        matches = [row for path, row in index.items()
                   if path.startswith(prefix) and not row["is_dir"]]
        if not matches:
            raise ValueError(f"missing required ZIP prefix: {prefix}")
        for row in matches:
            add(row, role)

    manifest_rows = identity.get("Manifest")
    if not isinstance(manifest_rows, dict):
        raise ValueError("selected identity has no Manifest dictionary")
    for key, value in manifest_rows.items():
        if key in SKIP_KEYS or key.startswith("Cryptex"):
            continue
        if not isinstance(value, dict) or not isinstance(value.get("Info"), dict):
            raise ValueError(f"manifest entry {key!r} has no Info dictionary")
        path = safe_member(value["Info"].get("Path"))
        add(_required(index, path), "identity_payload")

    members = []
    for path in sorted(rows):
        members.append(_item(rows[path], *roles[path]))
    source_bytes = sum(row["bytes"] for row in members)
    compressed_bytes = sum(row["compressed_bytes"] for row in members)
    return {
        "schema": "j575d-boot-stub-plan-v1",
        "selection": {
            "identity_index": identity_pos,
            "board_id": EXPECTED["board"],
            "chip_id": EXPECTED["chip"],
            "device_class": EXPECTED["device"],
            "variant": EXPECTED["variant"],
            "restore_behavior": EXPECTED["behavior"],
            "build_number": EXPECTED["build"],
            "product_version": EXPECTED["product"],
        },
        "members": members,
        "base_system": _item(base_row, "base_system"),
        "totals": {
            "member_count": len(members),
            "source_bytes": source_bytes,
            "compressed_bytes": compressed_bytes,
            "base_system_source_bytes": base_row["bytes"],
            "base_system_compressed_bytes": base_row["compressed_bytes"],
        },
        "accounting": {
            "source_bytes_only": True,
            "installed": False,
            "peak_disk_bytes": None,
            "boot_qualified": False,
            "blocked": ["firmwarepackage", "personalization", "liveadmininfo"],
        },
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--zip-index", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        with args.manifest.open("rb") as stream:
            manifest = plistlib.load(stream)
        with args.zip_index.open("r", encoding="utf-8") as stream:
            raw_index = json.load(stream)
        plan = make_plan(manifest, raw_index)
        with args.output.open("x", encoding="utf-8") as stream:
            json.dump(plan, stream, indent=2, sort_keys=True)
            stream.write("\n")
    except (OSError, ValueError, plistlib.InvalidFileException, json.JSONDecodeError) as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
