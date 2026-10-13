#!/usr/bin/env python3
"""Stage the four identity-153 FUD inputs without running the installer.

The output is an inert source tree for diagnostics.  This helper deliberately
does not mount images, invoke collectors, access host-private paths, or build a
Linux firmware package.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import shutil
import stat
import tempfile
from pathlib import Path


PROFILE = "26A428"
CANONICAL_PROJECT = Path(__file__).resolve().parents[1]
CANONICAL_SCRATCH = CANONICAL_PROJECT / "scratch/boot-stub-provisioning"
DEFAULT_RECEIPT = CANONICAL_SCRATCH / "assets-noi8v3w1/receipt.json"
RECEIPT_SHA256 = "1e7107d97cf8c0316df6aa27cdba3813103009a7cfa266bb2d981c5840168d35"
MANIFEST_SHA256 = "22949db91be2ddd0009a0047ceba37336452b76af3ff915f496d842b85cce6a7"
IDENTITY_INDEX = 153
PIN = {
    "board_id": "0x44",
    "chip_id": "0x6032",
    "device_class": "j575dap",
    "variant": "macOS Customer",
    "restore_behavior": "Erase",
    "build_number": PROFILE,
}
SKIP_KEYS = {
    "BaseSystem", "OS", "Ap,SystemVolumeCanonicalMetadata",
    "StaticTrustCache", "SystemVolume",
}
EXPECTED_FUD = {
    "Ap,ANE1": "Firmware/ane/t603x_ane1_fw_erebus_pc5x.im4p",
    "Ap,DCP2": "Firmware/dcp/t603xdcp.im4p",
    "Ap,SecurePageTableMonitor": "Firmware/sptm.t6031.release.im4p",
    "Ap,TrustedExecutionMonitor": "Firmware/txm.macosx.release.im4p",
}


def _safe_member(value: object) -> str:
    if (not isinstance(value, str) or not value or "\x00" in value
            or "\\" in value or value.startswith("/")):
        raise ValueError(f"unsafe member path: {value!r}")
    parts = value.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise ValueError(f"unsafe member path: {value!r}")
    return value


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _body_sha256(body: str) -> str:
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def _load_receipt(path: Path, root: Path) -> tuple[dict, dict[str, dict]]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ValueError(f"cannot read asset receipt: {exc}") from exc
    if not isinstance(raw, dict) or not isinstance(raw.get("members"), list):
        raise ValueError("asset receipt must contain a members list")
    if not str(raw.get("scope", "")).startswith("source member bytes only"):
        raise ValueError("asset receipt scope is not source-only")
    root = root.resolve()
    rows: dict[str, dict] = {}
    for row in raw["members"]:
        if not isinstance(row, dict):
            raise ValueError("asset receipt member must be an object")
        member = _safe_member(row.get("member"))
        if member in rows:
            raise ValueError(f"duplicate asset receipt member: {member}")
        local = row.get("local_path")
        if not isinstance(local, str) or not local:
            raise ValueError(f"missing local_path for {member}")
        candidate = Path(local)
        if not candidate.is_absolute():
            candidate = root / candidate
        try:
            resolved = candidate.resolve(strict=True)
            resolved.relative_to(root)
            info = resolved.stat()
        except (OSError, ValueError) as exc:
            raise ValueError(f"missing or escaping source for {member}") from exc
        if candidate.is_symlink() or not stat.S_ISREG(info.st_mode):
            raise ValueError(f"source is not a regular file: {member}")
        size, expected = row.get("bytes"), row.get("sha256")
        if (isinstance(size, bool) or not isinstance(size, int) or size < 0
                or info.st_size != size):
            raise ValueError(f"size mismatch for {member}")
        if (not isinstance(expected, str) or len(expected) != 64
                or any(c not in "0123456789abcdefABCDEF" for c in expected)):
            raise ValueError(f"bad sha256 in receipt for {member}")
        rows[member] = {
            "member": member,
            "path": resolved,
            "bytes": size,
            "sha256": expected.lower(),
        }
    return raw, rows


def _verify_source(row: dict) -> None:
    path = row["path"]
    if path.stat().st_size != row["bytes"] or _sha256(path) != row["sha256"]:
        raise ValueError(f"source bytes do not match asset receipt: {row['member']}")


def _load_pinned_identity(manifest_path: Path) -> dict:
    try:
        data = plistlib.loads(manifest_path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as exc:
        raise ValueError(f"invalid BuildManifest.plist: {exc}") from exc
    identities = data.get("BuildIdentities")
    if not isinstance(identities, list) or len(identities) <= IDENTITY_INDEX:
        raise ValueError("BuildManifest lacks identity index 153")
    identity = identities[IDENTITY_INDEX]
    info = identity.get("Info", {})
    actual = {
        "board_id": identity.get("ApBoardID"),
        "chip_id": identity.get("ApChipID"),
        "device_class": info.get("DeviceClass"),
        "variant": info.get("Variant"),
        "restore_behavior": info.get("RestoreBehavior"),
        "build_number": info.get("BuildNumber", data.get("ProductBuildVersion")),
    }
    if actual != PIN:
        raise ValueError(f"identity 153 pin mismatch: {actual!r}")
    if data.get("ProductBuildVersion") != PROFILE:
        raise ValueError("BuildManifest product build is not 26A428")
    return identity


def _selected_fud(identity: dict) -> dict[str, str]:
    manifest = identity.get("Manifest")
    if not isinstance(manifest, dict):
        raise ValueError("identity 153 has no manifest")
    selected: dict[str, str] = {}
    for key, value in manifest.items():
        if key in SKIP_KEYS:
            continue
        info = value.get("Info") if isinstance(value, dict) else None
        if not isinstance(info, dict):
            continue
        path = info.get("Path")
        if not isinstance(path, str):
            continue
        if (info.get("IsFUDFirmware", False)
                and not info.get("IsLoadedByiBoot", False)
                and not info.get("IsLoadedByiBootStage1", False)
                and path.endswith(".im4p")):
            selected[key] = _safe_member(path)
    if selected != EXPECTED_FUD:
        raise ValueError(f"identity 153 FUD selection mismatch: {selected!r}")
    return selected


def _alias_target(alias_path: str, source_member: str) -> str:
    """Return and validate the exact collector-relative alias body."""
    body = f"../{source_member}"
    alias = Path(alias_path)
    root = Path("fud_firmware")
    if alias.parts[:1] != (root.name,):
        raise ValueError(f"alias is outside fud_firmware: {alias_path}")
    alias_root = root / Path(*alias.parts[1:])
    target = (alias_root.parent / body).resolve()
    try:
        target.relative_to(root.resolve())
    except ValueError as exc:
        raise ValueError(f"alias escapes fud_firmware: {alias_path}") from exc
    return body


def _check_destinations(destinations: list[str]) -> None:
    normalized = [_safe_member(path) for path in destinations]
    if len(normalized) != len(set(normalized)):
        raise ValueError("destination collision in FUD staging")
    paths = {Path(path) for path in normalized}
    for path in paths:
        if any(parent in paths for parent in path.parents):
            raise ValueError("ancestor destination collision in FUD staging")


def _output_root(path: Path, scratch: Path) -> Path:
    scratch = scratch.resolve()
    path = path.resolve()
    try:
        path.relative_to(scratch)
    except ValueError as exc:
        raise ValueError("output must be a new subdirectory of boot-stub-provisioning") from exc
    if path == scratch or path.exists():
        raise FileExistsError(f"output must be exclusive and new: {path}")
    return path


def _scratch_root(project_root: Path) -> Path:
    project = project_root.resolve()
    scratch = (project / "scratch/boot-stub-provisioning").resolve()
    try:
        scratch.relative_to(project)
    except ValueError as exc:
        raise ValueError("canonical scratch is outside the project root") from exc
    return scratch


def stage(receipt: Path, project_root: Path, output: Path | None = None) -> Path:
    root = project_root.resolve()
    scratch = _scratch_root(root)
    if output is not None:
        output = _output_root(output, scratch)
    raw_receipt, rows = _load_receipt(receipt.resolve(), root)
    manifest_row = rows.get("BuildManifest.plist")
    if manifest_row is None:
        raise ValueError("asset receipt lacks BuildManifest.plist")
    _verify_source(manifest_row)
    identity = _load_pinned_identity(manifest_row["path"])
    selected = _selected_fud(identity)
    source_rows = []
    for source in selected.values():
        row = rows.get(source)
        if row is None:
            raise ValueError(f"asset receipt lacks selected FUD member: {source}")
        _verify_source(row)
        source_rows.append(row)
    if len(source_rows) != 4:
        raise ValueError("expected exactly four FUD source files")

    device_dir = identity["Info"]["DeviceClass"][:-2]
    entries: list[dict] = []
    destinations: list[str] = []
    for key, source in selected.items():
        file_dest = f"fud_firmware/{source}"
        alias_dest = f"fud_firmware/{device_dir}/{key}.im4p"
        destinations.extend((file_dest, alias_dest))
        body = _alias_target(alias_dest, source)
        row = rows[source]
        entries.append({
            "path": file_dest,
            "kind": "file",
            "source_member": source,
            "bytes": row["bytes"],
            "sha256": row["sha256"],
        })
        entries.append({
            "path": alias_dest,
            "kind": "symlink",
            "target": body,
            "bytes": len(body.encode("utf-8")),
            "sha256": _body_sha256(body),
            "source_member": source,
            "source_sha256": row["sha256"],
        })
    _check_destinations(destinations)

    if output is None:
        scratch.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix="fud-j575d-", dir=scratch))
    else:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.mkdir()
    try:
        for entry in entries:
            destination = output / entry["path"]
            destination.parent.mkdir(parents=True, exist_ok=True)
            if entry["kind"] == "file":
                source = rows[entry["source_member"]]
                shutil.copyfile(source["path"], destination)
                os.chmod(destination, 0o644)
                _verify_source({**source, "path": destination})
            else:
                os.symlink(entry["target"], destination)
        report = {
            "schema": "j575d-fud-inputs-receipt-v1",
            "profile": PROFILE,
            "identity_index": IDENTITY_INDEX,
            "identity": PIN,
            "device_directory": device_dir,
            "source_receipt_sha256": hashlib.sha256(receipt.read_bytes()).hexdigest(),
            "firmware_package_complete": False,
            "native_approved": False,
            "layout_experimental": True,
            "files": entries,
            "manifest_sha256": manifest_row["sha256"],
            "source_receipt_scope": raw_receipt["scope"],
        }
        (output / "fud-inputs-receipt.json").write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
    except Exception as exc:
        failure = {
            "schema": "j575d-fud-inputs-failure-v1",
            "profile": PROFILE,
            "firmware_package_complete": False,
            "native_approved": False,
            "error": f"{type(exc).__name__}: {exc}",
        }
        try:
            (output / "fud-inputs-failure.json").write_text(
                json.dumps(failure, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
        except OSError:
            pass
        raise
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    args = parser.parse_args()
    del args
    project = CANONICAL_PROJECT.resolve()
    scratch = _scratch_root(project)
    receipt = DEFAULT_RECEIPT.resolve()
    try:
        if _sha256(receipt) != RECEIPT_SHA256:
            raise ValueError("canonical source receipt SHA-256 pin mismatch")
        _, rows = _load_receipt(receipt, project)
        manifest = rows.get("BuildManifest.plist")
        if manifest is None or manifest["sha256"] != MANIFEST_SHA256:
            raise ValueError("canonical BuildManifest.plist SHA-256 pin mismatch")
        _verify_source(manifest)
        output = stage(receipt, project)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
