#!/usr/bin/env python3
"""Stage the bounded, offline J575d boot-stub layout.

This is an inert file copier.  It never mounts, blesses, personalizes, or
invokes a subprocess.  The result is an experimental layout, not an install.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
import stat
import sys
import tempfile
from pathlib import Path

PROFILE = "26A428"
CANONICAL_PROJECT = Path(__file__).resolve().parents[1]
CANONICAL_SCRATCH = CANONICAL_PROJECT / "scratch/boot-stub-provisioning"
FAKE_UUID = "00000000-0000-4000-8000-000000000001"
FRAMEWORK_MEMBER = (
    "BootabilityBundle/Restore/Bootability/BootabilityBrain.framework/"
    "Versions/A/BootabilityBrain"
)
FRAMEWORK_SHA256 = "a1e5d7b781698bc60cce96dc54aba9ab50780291b005e51a07a83d8818023706"
INSTALLER_REVISION = "e93743d52178b3e26e428fa05174ef549abf30cb"
BOOTABILITY_PREFIX = "BootabilityBundle/Restore/Bootability/"
RESTORE_MANIFEST_PREFIX = "Firmware/Manifests/restore/macOS Customer/"
TRUSTCACHE_MEMBER = "BootabilityBundle/Restore/Firmware/Bootability.dmg.trustcache"
SKIP = {"BaseSystem", "OS", "Ap,SystemVolumeCanonicalMetadata",
        "RestoreRamDisk", "RestoreTrustCache"}


def _safe(value: object) -> str:
    if not isinstance(value, str) or not value or "\x00" in value or "\\" in value:
        raise ValueError("invalid receipt member path")
    if value.startswith("/") or any(p in ("", ".", "..") for p in value.split("/")):
        raise ValueError(f"unsafe receipt member path: {value!r}")
    return value


def _planner(root: Path):
    path = root / "scripts/plan-j575d-boot-stub.py"
    spec = importlib.util.spec_from_file_location("j575d_stage_planner", path)
    if spec is None or spec.loader is None:
        raise ValueError("cannot load local boot-stub planner")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def load_receipt(path: Path, root: Path) -> dict[str, dict]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ValueError(f"cannot read receipt: {exc}") from exc
    rows = raw.get("members") if isinstance(raw, dict) else raw
    if not isinstance(rows, list):
        raise ValueError("receipt must contain a members list")
    result: dict[str, dict] = {}
    root = root.resolve()
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("receipt member must be an object")
        member = _safe(row.get("member"))
        if member in result:
            raise ValueError(f"duplicate receipt member: {member}")
        local = row.get("local_path")
        if not isinstance(local, str) or not local:
            raise ValueError(f"missing local_path for {member}")
        candidate = Path(local)
        candidate = candidate if candidate.is_absolute() else root / candidate
        try:
            resolved = candidate.resolve(strict=True)
            resolved.relative_to(root)
            info = resolved.stat()
        except (OSError, ValueError) as exc:
            raise ValueError(f"local_path escapes project root or is missing: {member}") from exc
        if candidate.is_symlink() or not stat.S_ISREG(info.st_mode):
            raise ValueError(f"local_path is not a regular non-symlink file: {member}")
        size, expected = row.get("bytes"), row.get("sha256")
        if isinstance(size, bool) or not isinstance(size, int) or size < 0 or info.st_size != size:
            raise ValueError(f"size mismatch for {member}")
        if not isinstance(expected, str) or len(expected) != 64 or _digest(resolved) != expected.lower():
            raise ValueError(f"sha256 mismatch for {member}")
        mode = row.get("unix_mode", 0o100644)
        if isinstance(mode, bool) or not isinstance(mode, int) or mode < 0:
            raise ValueError(f"bad unix_mode for {member}")
        result[member] = {"member": member, "path": resolved, "bytes": size,
                          "sha256": expected.lower(), "symlink": stat.S_ISLNK(mode),
                          "mode": mode}
    return result


def _plist(files: dict[str, dict], name: str) -> object:
    try:
        return plistlib.loads(files[name]["path"].read_bytes())
    except KeyError as exc:
        raise ValueError(f"receipt lacks required member: {name}") from exc
    except (OSError, plistlib.InvalidFileException) as exc:
        raise ValueError(f"invalid plist member: {name}") from exc


def _payloads(identity: dict) -> list[str]:
    entries = identity.get("Manifest")
    if not isinstance(entries, dict):
        raise ValueError("selected identity has no Manifest")
    result = []
    for key, value in entries.items():
        if key in SKIP or key.startswith("Cryptex"):
            continue
        info = value.get("Info") if isinstance(value, dict) else None
        path = _safe(info.get("Path") if isinstance(info, dict) else None)
        if path not in result:
            result.append(path)
    return result


def _destinations(files: dict[str, dict], identity: dict) -> dict[str, str]:
    """Return destination -> source member; generated members use '*'."""
    out: dict[str, str] = {}
    def add(destination: str, source: str) -> None:
        if destination in out:
            raise ValueError(f"destination collision in staged layout: {destination}")
        out[destination] = source
    add("System/usr/standalone/bootcaches.plist", "usr/standalone/bootcaches.plist")
    add("System/System/Library/CoreServices/PlatformSupport.plist", "PlatformSupport.plist")
    add("System/System/Library/CoreServices/SystemVersion.plist", "*SystemVersion*")
    add(f"Preboot/{FAKE_UUID}/restore/BuildManifest.plist", "*BuildManifest*")
    add(f"Preboot/{FAKE_UUID}/restore/SystemVersion.plist", "SystemVersion.plist")
    add(f"Preboot/{FAKE_UUID}/restore/RestoreVersion.plist", "RestoreVersion.plist")
    add(f"Preboot/{FAKE_UUID}/restore/usr/standalone/bootcaches.plist", "usr/standalone/bootcaches.plist")
    add(f"Preboot/{FAKE_UUID}/restore/Bootability/Bootability.trustcache", TRUSTCACHE_MEMBER)
    base = _safe(identity["Manifest"]["BaseSystem"]["Info"]["Path"])
    add(f"Recovery/{FAKE_UUID}/usr/standalone/firmware/arm64eBaseSystem.dmg", base)
    for member in files:
        if member.startswith(BOOTABILITY_PREFIX):
            add(f"Preboot/{FAKE_UUID}/restore/Bootability/{member[len(BOOTABILITY_PREFIX):]}", member)
        if member.startswith(RESTORE_MANIFEST_PREFIX):
            add(f"Preboot/{FAKE_UUID}/restore/{member[len(RESTORE_MANIFEST_PREFIX):]}", member)
    for member in _payloads(identity):
        add(f"Preboot/{FAKE_UUID}/restore/{member}", member)
    return out


def _copy(src: Path, dst: Path, expected_size: int, expected_sha256: str) -> dict:
    dst.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256()
    size = 0
    with src.open("rb") as source, dst.open("xb") as target:
        while True:
            block = source.read(16 * 1024 * 1024)
            if not block:
                break
            target.write(block)
            digest.update(block)
            size += len(block)
    if size != expected_size or digest.hexdigest() != expected_sha256:
        raise ValueError(f"copied source changed while staging: {src}")
    os.chmod(dst, 0o644)
    return {"path": dst, "kind": "file", "bytes": size, "sha256": digest.hexdigest()}


def _link_body(src: Path) -> str:
    try:
        body = src.read_bytes().decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise ValueError("Bootability symlink body is not UTF-8") from exc
    if not body or "\x00" in body or os.path.isabs(body):
        raise ValueError("Bootability symlink must have a non-empty relative body")
    return body


def _check_collision(destinations: dict[str, str]) -> None:
    keys = list(destinations)
    if len(keys) != len(set(keys)):
        raise ValueError("destination collision in staged layout")
    dest_set = set(keys)
    for path in keys:
        _safe(path)
        candidate = Path(path)
        if any(str(parent) in dest_set for parent in candidate.parents if str(parent) != "."):
            raise ValueError("destination collision in staged layout")


def stage(receipt: Path, project_root: Path, profile: str) -> Path:
    if profile != PROFILE:
        raise ValueError("staging requires explicit experimental profile 26A428")
    root = project_root.resolve()
    files = load_receipt(receipt.resolve(), root)
    if FRAMEWORK_MEMBER not in files or files[FRAMEWORK_MEMBER]["sha256"] != FRAMEWORK_SHA256:
        raise ValueError("BootabilityBrain framework SHA-256 is not the pinned 26A428 value")
    planner = _planner(root)
    manifest = _plist(files, "BuildManifest.plist")
    if not isinstance(manifest, dict):
        raise ValueError("BuildManifest.plist is not a dictionary")
    identity_index, identity = planner.select_identity(manifest)
    base_path = _safe(identity["Manifest"]["BaseSystem"]["Info"]["Path"])
    if base_path not in files:
        raise ValueError("receipt lacks selected BaseSystem member")
    payloads = _payloads(identity)
    required = {"BuildManifest.plist", "SystemVersion.plist", "RestoreVersion.plist",
                "PlatformSupport.plist", "usr/standalone/bootcaches.plist", TRUSTCACHE_MEMBER,
                base_path}
    required.update(payloads)
    if not required.issubset(files):
        raise ValueError("receipt lacks required selected staging members")
    if not any(name.startswith(BOOTABILITY_PREFIX) for name in files):
        raise ValueError("receipt lacks required Bootability tree")
    if not any(name.startswith(RESTORE_MANIFEST_PREFIX) for name in files):
        raise ValueError("receipt lacks required restore manifest tree")
    boot_links = [name for name, row in files.items() if name.startswith(BOOTABILITY_PREFIX) and row["symlink"]]
    if len(boot_links) != 3:
        raise ValueError(f"expected exactly 3 Bootability relative symlinks, found {len(boot_links)}")
    destinations = _destinations(files, identity)
    _check_collision(destinations)

    canonical_project = CANONICAL_PROJECT.resolve()
    parent = CANONICAL_SCRATCH
    try:
        parent.resolve(strict=False).relative_to(canonical_project)
    except ValueError as exc:
        raise ValueError("canonical staging scratch escapes project root") from exc
    parent.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix="stage-", dir=parent))
    try:
        records: list[dict] = []
        reduced = dict(manifest)
        reduced["BuildIdentities"] = [identity]
        generated: dict[str, bytes] = {}
        sysver = _plist(files, "SystemVersion.plist")
        if not isinstance(sysver, dict):
            raise ValueError("SystemVersion.plist is not a dictionary")
        stubver = dict(sysver)
        visible = stubver.get("ProductUserVisibleVersion")
        if not isinstance(visible, str):
            raise ValueError("SystemVersion.plist lacks ProductUserVisibleVersion")
        stubver["ProductUserVisibleVersion"] = visible + " (stub)"
        generated["System/System/Library/CoreServices/SystemVersion.plist"] = plistlib.dumps(stubver)
        generated[f"Preboot/{FAKE_UUID}/restore/BuildManifest.plist"] = plistlib.dumps(reduced)
        for destination, source in destinations.items():
            target = out / destination
            if destination in generated:
                data = generated[destination]
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open("xb") as stream:
                    stream.write(data)
                os.chmod(target, 0o644)
                records.append({"path": destination, "kind": "file", "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "source_member": "generated"})
            elif source.startswith(BOOTABILITY_PREFIX) and files[source]["symlink"]:
                body = _link_body(files[source]["path"])
                link_root = target.parent
                resolved = (link_root / body).resolve(strict=False)
                resolved.relative_to((out / f"Preboot/{FAKE_UUID}/restore/Bootability").resolve())
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(body)
                records.append({"path": destination, "kind": "symlink", "bytes": len(body.encode()), "sha256": hashlib.sha256(body.encode()).hexdigest(), "body": body, "source_member": source, "source_sha256": files[source]["sha256"]})
            else:
                record = _copy(files[source]["path"], target, files[source]["bytes"], files[source]["sha256"])
                record.update({"source_member": source, "source_sha256": files[source]["sha256"]})
                records.append({k: (str(v.relative_to(out)) if k == "path" else v) for k, v in record.items()})
        receipt_out = {
            "schema": "j575d-boot-stub-stage-receipt-v1", "profile": PROFILE,
            "source_receipt_sha256": _digest(receipt.resolve()),
            "identity_index": identity_index, "fake_uuid": FAKE_UUID,
            "source_framework_pin": {"member": FRAMEWORK_MEMBER, "sha256": FRAMEWORK_SHA256,
                                      "installer_revision": INSTALLER_REVISION},
            "layout_experimental": True, "boot_qualified": False, "fit_8gb": None,
            "recovery_representation": "unchanged AEA source bytes under the candidate filename; not decrypted and not the legacy installer's resource-fork compressed representation",
            "layout_note": "hybrid experimental erase layout; modern restore-bundle contents, Bootability packaging, and erase-vs-update differences remain unqualified; uses lowercase restore, not restore-staged",
            "explicit_missing_pieces": ["firmwarepackage", "personalization", "liveadmininfo", "step2", "boot.bin", "modern_restore_bundle_contents_qualification", "bootability_packaging_qualification", "erase_vs_update_restore_layout_qualification", "apfs_allocation", "boot_validation"],
            "files": sorted(records, key=lambda row: row["path"]),
        }
        with (out / "stage-receipt.json").open("x", encoding="utf-8") as stream:
            json.dump(receipt_out, stream, indent=2, sort_keys=True)
            stream.write("\n")
    except Exception as exc:
        (out / "STAGE-PARTIAL.txt").write_text(f"partial experimental stage; not installable\nerror: {exc}\n", encoding="utf-8")
        raise
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--profile", required=True)
    args = parser.parse_args(argv)
    try:
        print(stage(args.receipt, args.project_root, args.profile))
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
