#!/usr/bin/env python3
"""Measure the source-logical J575d boot-stub input layout.

This is deliberately a receipt-only reader: it never opens the IPSW, copies a
member, creates a link, mounts a volume, or invokes an installer.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import plistlib
import stat
import sys
from pathlib import Path
SKIP = {"BaseSystem", "OS", "Ap,SystemVolumeCanonicalMetadata",
        "RestoreRamDisk", "RestoreTrustCache"}
BOOTABILITY = "BootabilityBundle/Restore/Bootability/"
RESTORE_MANIFESTS = "Firmware/Manifests/restore/macOS Customer/"
TRUSTCACHE = "BootabilityBundle/Restore/Firmware/Bootability.dmg.trustcache"
def safe_member(value: object) -> str:
    if not isinstance(value, str) or not value or "\x00" in value or "\\" in value:
        raise ValueError("invalid receipt member path")
    parts = value.split("/")
    if value.startswith("/") or any(part in ("", ".", "..") for part in parts):
        raise ValueError(f"unsafe member path: {value!r}")
    return value
def _planner(project_root: Path):
    path = project_root / "scripts/plan-j575d-boot-stub.py"
    spec = importlib.util.spec_from_file_location("j575d_boot_plan", path)
    if spec is None or spec.loader is None:
        raise ValueError("cannot load local boot-stub planner")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
def _receipt_rows(receipt: object) -> list[dict]:
    rows = receipt if isinstance(receipt, list) else receipt.get("members") if isinstance(receipt, dict) else None
    if not isinstance(rows, list):
        raise ValueError("receipt must contain a members list")
    return rows
def _load_receipt(path: Path, root: Path) -> dict[str, dict]:
    try:
        raw = json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        raise ValueError(f"cannot read receipt: {exc}") from exc
    result: dict[str, dict] = {}
    for row in _receipt_rows(raw):
        if not isinstance(row, dict):
            raise ValueError("receipt member must be an object")
        member = safe_member(row.get("member"))
        if member in result:
            raise ValueError(f"duplicate receipt member: {member}")
        local_value = row.get("local_path")
        if not isinstance(local_value, str) or not local_value:
            raise ValueError(f"missing local_path for {member}")
        candidate = Path(local_value)
        candidate = candidate if candidate.is_absolute() else root / candidate
        try:
            resolved = candidate.resolve(strict=True)
            resolved.relative_to(root)
        except (OSError, ValueError) as exc:
            raise ValueError(f"local_path escapes project root or is missing: {member}") from exc
        info = resolved.stat()
        if not stat.S_ISREG(info.st_mode) or candidate.is_symlink():
            raise ValueError(f"local_path is not a regular non-symlink file: {member}")
        size = row.get("bytes")
        if isinstance(size, bool) or not isinstance(size, int) or size < 0 or info.st_size != size:
            raise ValueError(f"size mismatch for {member}")
        with resolved.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        expected = row.get("sha256")
        if not isinstance(expected, str) or len(expected) != 64 or digest != expected.lower():
            raise ValueError(f"sha256 mismatch for {member}")
        mode = row.get("unix_mode", 0o100644)
        if isinstance(mode, bool) or not isinstance(mode, int) or mode < 0:
            raise ValueError(f"bad unix_mode for {member}")
        result[member] = {"member": member, "path": resolved, "bytes": size,
                          "symlink_body": stat.S_ISLNK(mode)}
    return result
def _plist(files: dict[str, dict], member: str) -> object:
    try:
        return plistlib.loads(files[member]["path"].read_bytes())
    except KeyError as exc:
        raise ValueError(f"receipt lacks required member: {member}") from exc
    except (OSError, plistlib.InvalidFileException) as exc:
        raise ValueError(f"invalid plist member: {member}") from exc
def _tree(files: dict[str, dict], prefix: str) -> dict:
    rows = [v for k, v in files.items() if k.startswith(prefix)]
    if not rows:
        raise ValueError(f"receipt lacks required tree: {prefix}")
    regular = [v for v in rows if not v["symlink_body"]]
    links = [v for v in rows if v["symlink_body"]]
    return {"member_count": len(rows), "regular_file_count": len(regular),
            "symlink_body_count": len(links), "regular_bytes": sum(v["bytes"] for v in regular),
            "symlink_body_bytes": sum(v["bytes"] for v in links),
            "logical_bytes": sum(v["bytes"] for v in regular)}
def _entry(files: dict[str, dict], member: str, generated: int | None = None) -> dict:
    if generated is not None:
        return {"member": member, "bytes": generated, "generated": True, "source_kind": "generated"}
    if member not in files:
        raise ValueError(f"receipt lacks required member: {member}")
    kind = "symlink_body" if files[member]["symlink_body"] else "regular_file"
    return {"member": member, "bytes": files[member]["bytes"], "generated": False, "source_kind": kind}
def measure(receipt: Path, project_root: Path) -> dict:
    root = project_root.resolve()
    files = _load_receipt(receipt.resolve(), root)
    planner = _planner(root)
    manifest = _plist(files, "BuildManifest.plist")
    if not isinstance(manifest, dict):
        raise ValueError("BuildManifest.plist is not a dictionary")
    identity_index, identity = planner.select_identity(manifest)
    reduced = dict(manifest)
    reduced["BuildIdentities"] = [identity]
    reduced_bytes = len(plistlib.dumps(reduced))
    sysver = _plist(files, "SystemVersion.plist")
    if not isinstance(sysver, dict) or not isinstance(sysver.get("ProductUserVisibleVersion"), str):
        raise ValueError("SystemVersion.plist lacks ProductUserVisibleVersion")
    modified = dict(sysver)
    modified["ProductUserVisibleVersion"] += " (stub)"
    modified_bytes = len(plistlib.dumps(modified))
    bootcaches = _plist(files, "usr/standalone/bootcaches.plist")
    if not isinstance(bootcaches, dict) or not isinstance(bootcaches.get("bless2"), dict):
        raise ValueError("bootcaches.plist lacks bless2")
    restore_path = bootcaches["bless2"].get("RestoreBundlePath")
    layout_gate = None
    try:
        if not isinstance(restore_path, str):
            raise ValueError("bootcaches bless2.RestoreBundlePath missing or invalid")
        restore_path = safe_member(restore_path)
        if restore_path.endswith("/"):
            raise ValueError("RestoreBundlePath must not end in /")
    except ValueError as exc:
        # Source-byte accounting remains useful when this bootcaches schema
        # cannot drive a real restore-bundle layout.
        layout_gate = str(exc)
        restore_path = None
    restore_version = _entry(files, "RestoreVersion.plist")
    platform = _entry(files, "PlatformSupport.plist")
    bootcaches_entry = _entry(files, "usr/standalone/bootcaches.plist")
    system = [_entry(files, "usr/standalone/bootcaches.plist"), platform,
              _entry(files, "SystemVersion.plist", modified_bytes)]
    payload_paths: list[str] = []
    manifest_rows = identity.get("Manifest")
    if not isinstance(manifest_rows, dict):
        raise ValueError("selected identity has no Manifest")
    for key, value in manifest_rows.items():
        if key in SKIP or key.startswith("Cryptex"):
            continue
        info = value.get("Info") if isinstance(value, dict) else None
        path = info.get("Path") if isinstance(info, dict) else None
        path = safe_member(path)
        if path not in payload_paths:
            payload_paths.append(path)
    for path in payload_paths:
        if path not in files:
            raise ValueError(f"receipt lacks selected payload: {path}")
    base_info = manifest_rows.get("BaseSystem", {}).get("Info", {})
    base_path = safe_member(base_info.get("Path"))
    base = _entry(files, base_path)
    trust = _entry(files, TRUSTCACHE)
    boot_tree = _tree(files, BOOTABILITY)
    restore_tree = _tree(files, RESTORE_MANIFESTS)
    preboot = [_entry(files, "SystemVersion.plist"), restore_version, bootcaches_entry,
               _entry(files, "BuildManifest.plist", reduced_bytes), trust]
    preboot.extend(_entry(files, p) for p in payload_paths)
    preboot_bytes = sum(x["bytes"] for x in preboot) + boot_tree["logical_bytes"] + restore_tree["logical_bytes"]
    system_bytes = sum(x["bytes"] for x in system)
    kernel_paths = list(dict.fromkeys(p for p in payload_paths if p.startswith("kernelcache.")))
    export = [_entry(files, p, reduced_bytes) for p in ["BuildManifest.plist"]]
    export += [restore_version, _entry(files, "SystemVersion.plist", modified_bytes)]
    export += [_entry(files, p) for p in kernel_paths]
    fud: list[tuple[str, str]] = []
    for key, value in manifest_rows.items():
        info = value.get("Info") if isinstance(value, dict) else None
        if key in {"BaseSystem", "OS", "Ap,SystemVolumeCanonicalMetadata", "StaticTrustCache", "SystemVolume"} or not isinstance(info, dict):
            continue
        path = info.get("Path")
        if (info.get("IsFUDFirmware", False) and not info.get("IsLoadedByiBoot", False)
                and not info.get("IsLoadedByiBootStage1", False) and isinstance(path, str)
                and path.endswith(".im4p")):
            fud.append((key, path))
    fud_paths = list(dict.fromkeys(p for _, p in fud))
    return {"schema": "j575d-stub-input-measurement-v1", "source_logical_estimate": True,
            "final_installed_requirements": False, "identity_index": identity_index,
            "restore_bundle_path": restore_path, "layout_qualified": False,
            "receipt_metadata_trust": "unix_mode supplied by the retained ZIP fetch receipt; not independently re-read",
            "structural_gate": {"restore_bundle_path_valid": layout_gate is None,
                                "reason": layout_gate},
            "system": {"bytes": system_bytes, "entries": system},
            "preboot": {"bytes": preboot_bytes, "entries": preboot,
                         "bootability_tree": boot_tree, "restore_manifest_tree": restore_tree,
                         "system_restore_bundle_symlink_count": 1},
            "recovery": {"bytes": base["bytes"], "entries": [base], "path": base_path},
            "installer_data_export": {"bytes": sum(x["bytes"] for x in export), "entries": export,
                                      "destination_known": False, "part_of_apfs_count": None},
            "fud_temporary": {"candidate_count": len(fud), "regular_file_count": len(fud_paths),
                               "symlink_count": len(fud), "bytes": sum(files[p]["bytes"] for p in fud_paths),
                               "source_readable": True, "excluded_from_apfs": True,
                               "paths": fud_paths},
            "excluded": ["local_installer_app", "logo", "step2", "boot.bin", "host_admin_info",
                         "generated_firmware_package", "apple_personalization", "apfs_allocation", "peak_space"],
            "boot_validated": False, "fit_8gb": None}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        result = measure(args.receipt, args.project_root)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("x") as handle:
            json.dump(result, handle, indent=2, sort_keys=True)
            handle.write("\n")
    except (OSError, ValueError, TypeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
