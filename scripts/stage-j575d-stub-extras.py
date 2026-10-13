#!/usr/bin/env python3
"""Assemble inert, offline boot-stub extras in a project scratch directory.

This command has no output-directory option by design.  It accepts only an
existing, verified stage under this checkout's boot-stub scratch tree and
creates a fresh ``extras-*`` directory there.  Nothing produced here is a
deployment or boot-qualified artifact.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import tempfile
from pathlib import Path


PROJECT = Path(__file__).resolve().parents[1]
SCRATCH = PROJECT / "scratch" / "boot-stub-provisioning"
PROFILE = "26A428"
INSTALLER_REVISION = "e93743d52178b3e26e428fa05174ef549abf30cb"
FAKE_UUID = "00000000-0000-4000-8000-000000000001"
SOURCE_ASSET_RECEIPT_SHA256 = "1e7107d97cf8c0316df6aa27cdba3813103009a7cfa266bb2d981c5840168d35"
STAGE_RECEIPT_SHA256 = "3ac2361891b4d61a1b8285ea4bdc47b7e03a173ac1b2dab0a607df981535210b"

INSTALLER_FILES = {
    "src/step2/step2.sh": "db313de97dcca93804d398f4bbdcf2d6f9647729c6853f36d9fa247e5730d4af",
    "src/step2/IAPhysicalMedia.plist": "1066a03164a6d0720730217f4015aed8a0411c668958530fbb64cf18a21cdd3a",
    "src/step2/Finish Installation.app/Contents/Info.plist": "cb81b007718e278b0c9d37df042b088875312e69456140c93480c49c1e3f2113",
    "src/step2/Finish Installation.app/Contents/MacOS/step2_launcher.sh": "a160bd8c5c98c42943190c06b5c3f8b12ef35dd4bcb2015de53e0c2942fe6a39",
    "src/step2/Finish Installation.app/Contents/Resources/en.lproj/InfoPlist.strings": "7fbbe415225c3352af947c3daabc073182cc108ab048a99bb4c85fa783810c11",
}
INLINE_MANIFEST = PROJECT / "scratch" / "j575d-inline-package.6uf7698y" / "manifest.json"
INLINE_SOURCE = PROJECT / "scratch" / "j575d-inline-package.6uf7698y" / "UNQUALIFIED-m1n1-inline.bin"
INLINE_SHA256 = "b2b2fbeefd35f953ca67b9d3315bd33a95df9ed8e447e7a5756d1899aa1ab30e"

STAGE_EXPORTS = {
    "installer-data/BuildManifest.plist": "Preboot/{uuid}/restore/BuildManifest.plist",
    "installer-data/RestoreVersion.plist": "Preboot/{uuid}/restore/RestoreVersion.plist",
    "installer-data/SystemVersion.plist": "System/System/Library/CoreServices/SystemVersion.plist",
    "installer-data/kernelcache.release.mac15j": "Preboot/{uuid}/restore/kernelcache.release.mac15j",
}


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def canonical_scratch() -> Path:
    """Return the canonical scratch root, rejecting symlinked components."""
    project = PROJECT.resolve(strict=True)
    current = project
    for part in SCRATCH.relative_to(PROJECT).parts:
        current /= part
        if current.is_symlink():
            raise ValueError("canonical scratch must not contain symlinked components")
    root = SCRATCH.resolve(strict=False)
    try:
        root.relative_to(project)
    except ValueError as exc:
        raise ValueError("canonical scratch escapes project root") from exc
    return root


def safe_relative(value: object, label: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value or "\\" in value:
        raise ValueError(f"invalid {label}")
    path = Path(value)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        raise ValueError(f"unsafe {label}: {value!r}")
    return value


def inside(path: Path, root: Path, label: str) -> Path:
    resolved = path.resolve(strict=True)
    try:
        resolved.relative_to(root.resolve(strict=True))
    except ValueError as exc:
        raise ValueError(f"{label} escapes project scratch") from exc
    return resolved


def regular(path: Path, label: str) -> Path:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"{label} is not a regular non-symlink file: {path}")
    return path


def checked_source(path: Path, expected: str, label: str) -> dict[str, object]:
    regular(path, label)
    actual = digest(path)
    if actual != expected:
        raise ValueError(f"{label} SHA-256 mismatch: expected {expected}, got {actual}")
    return {"path": str(path.relative_to(PROJECT)), "bytes": path.stat().st_size,
            "sha256": actual}


def load_stage(stage_arg: Path) -> tuple[Path, dict, dict[str, dict]]:
    scratch = canonical_scratch()
    stage = stage_arg if stage_arg.is_absolute() else PROJECT / stage_arg
    if stage.is_symlink():
        raise ValueError("stage must not be a symlink")
    stage = inside(stage, scratch, "stage")
    receipt_path = regular(stage / "stage-receipt.json", "stage receipt")
    actual_receipt_sha256 = digest(receipt_path)
    if actual_receipt_sha256 != STAGE_RECEIPT_SHA256:
        raise ValueError("stage receipt is not the pinned retained stage")
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ValueError(f"cannot read stage receipt: {exc}") from exc
    if not isinstance(receipt, dict) or receipt.get("schema") != "j575d-boot-stub-stage-receipt-v1":
        raise ValueError("wrong stage receipt schema")
    if receipt.get("profile") != PROFILE or receipt.get("fake_uuid") != FAKE_UUID:
        raise ValueError("stage receipt identity/profile mismatch")
    if receipt.get("identity_index") != 153:
        raise ValueError("stage receipt selected identity mismatch")
    if receipt.get("source_receipt_sha256") != SOURCE_ASSET_RECEIPT_SHA256:
        raise ValueError("stage receipt is not the verified 26A428 receipt")
    rows = receipt.get("files")
    if not isinstance(rows, list):
        raise ValueError("stage receipt lacks files")
    files: dict[str, dict] = {}
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("stage file row is not an object")
        rel = safe_relative(row.get("path"), "stage file path")
        if rel in files:
            raise ValueError(f"duplicate stage file path: {rel}")
        kind = row.get("kind")
        if kind not in ("file", "symlink"):
            raise ValueError(f"invalid stage file kind: {rel}")
        size, expected = row.get("bytes"), row.get("sha256")
        if isinstance(size, bool) or not isinstance(size, int) or size < 0:
            raise ValueError(f"invalid stage size: {rel}")
        if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", expected):
            raise ValueError(f"invalid stage hash: {rel}")
        source_path = stage / rel
        if kind == "symlink":
            if not source_path.is_symlink():
                raise ValueError(f"stage symlink is missing: {rel}")
            body = os.readlink(source_path)
            if len(body.encode("utf-8")) != size or hashlib.sha256(body.encode("utf-8")).hexdigest() != expected.lower():
                raise ValueError(f"stage symlink receipt mismatch: {rel}")
            files[rel] = {"path": source_path, "bytes": size, "sha256": expected.lower(),
                          "source_member": row.get("source_member"), "kind": kind}
            continue
        source = inside(source_path, stage, f"stage file {rel}")
        regular(source, f"stage file {rel}")
        if source.stat().st_size != size or digest(source) != expected.lower():
            raise ValueError(f"stage receipt hash/size mismatch: {rel}")
        files[rel] = {"path": source, "bytes": size, "sha256": expected.lower(),
                      "source_member": row.get("source_member"), "kind": kind}
    return stage, receipt, files


def inert_script(data: bytes) -> bytes:
    # Keep the original body for review, but make accidental execution fail
    # before any original command can be parsed/executed.
    return (b"#!/bin/sh\n"
            b"# INERT OFFLINE TEMPLATE: execution is forbidden.\n"
            b"exit 97\n" + data)


def copy_checked(source: Path, target: Path, expected: str) -> dict[str, object]:
    source = regular(source, "source")
    if digest(source) != expected:
        raise ValueError(f"source changed before copy: {source}")
    target.parent.mkdir(parents=True, exist_ok=True)
    with source.open("rb") as src, target.open("xb") as dst:
        while block := src.read(1024 * 1024):
            dst.write(block)
    os.chmod(target, 0o644)
    actual = digest(target)
    if actual != expected or target.stat().st_size != source.stat().st_size:
        raise ValueError(f"copied source changed: {source}")
    return {"path": str(target), "kind": "file", "bytes": target.stat().st_size,
            "sha256": actual, "source_sha256": expected, "executable": False}


def write_bytes(target: Path, data: bytes, source_info: dict[str, object], source_path: str) -> dict[str, object]:
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("xb") as stream:
        stream.write(data)
    os.chmod(target, 0o644)
    return {"path": str(target), "kind": "file", "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "source": source_path, "source_sha256": source_info["sha256"],
            "executable": False}


def assemble(stage_arg: Path, distro: str = "Debian") -> Path:
    if not re.fullmatch(r"[A-Za-z0-9 _().+:-]+", distro) or distro.strip() != distro:
        raise ValueError("distro must be a single safe diagnostic string")
    stage, stage_receipt, stage_files = load_stage(stage_arg)

    installer_root = inside(PROJECT / "scratch" / "boot-stub-provisioning" /
                             f"asahi-installer-{INSTALLER_REVISION}", canonical_scratch(),
                             "installer source")
    source_info: dict[str, dict[str, object]] = {}
    for relative, expected in INSTALLER_FILES.items():
        source_info[relative] = checked_source(installer_root / relative, expected, relative)

    manifest = json.loads(INLINE_MANIFEST.read_text(encoding="utf-8"))
    output = manifest.get("outputs", {}).get("UNQUALIFIED-m1n1-inline.bin", {})
    if (manifest.get("profile") != "fork-current" or output.get("path") != str(INLINE_SOURCE.relative_to(PROJECT))
            or output.get("length") != INLINE_SOURCE.stat().st_size or output.get("sha256") != INLINE_SHA256):
        raise ValueError("official fork-current inline manifest does not match pinned candidate")
    inline_info = checked_source(INLINE_SOURCE, INLINE_SHA256, "official UNQUALIFIED m1n1 inline")

    uuid = stage_receipt["fake_uuid"]
    required_stage = {dest: template.format(uuid=uuid) for dest, template in STAGE_EXPORTS.items()}
    for dest, rel in required_stage.items():
        if rel not in stage_files:
            raise ValueError(f"stage receipt lacks export source: {rel}")

    scratch = canonical_scratch()
    scratch.mkdir(parents=True, exist_ok=True)
    output_root = Path(tempfile.mkdtemp(prefix="extras-", dir=scratch))
    records: list[dict[str, object]] = []
    try:
        templates = output_root / "templates"
        app_root = templates / "Finish Installation.app.inert"
        for rel, target_rel in (
            ("src/step2/Finish Installation.app/Contents/Info.plist", "Contents/Info.plist"),
            ("src/step2/Finish Installation.app/Contents/Resources/en.lproj/InfoPlist.strings",
             "Contents/Resources/en.lproj/InfoPlist.strings"),
        ):
            records.append(copy_checked(installer_root / rel, app_root / target_rel,
                                        INSTALLER_FILES[rel]))
            records[-1].update({"path": str(Path("templates/Finish Installation.app.inert") / target_rel),
                                "source": rel, "source_sha256": INSTALLER_FILES[rel]})

        launcher_rel = "src/step2/Finish Installation.app/Contents/MacOS/step2_launcher.sh"
        launcher = (installer_root / launcher_rel).read_bytes()
        if hashlib.sha256(launcher).hexdigest() != INSTALLER_FILES[launcher_rel]:
            raise ValueError("launcher template changed after pin validation")
        launcher_target = app_root / "Contents/MacOS/step2_launcher.sh.inert"
        info = write_bytes(launcher_target, inert_script(launcher), source_info[launcher_rel], launcher_rel)
        info["path"] = str(Path("templates/Finish Installation.app.inert/Contents/MacOS/step2_launcher.sh.inert"))
        records.append(info)

        step_rel = "src/step2/step2.sh"
        step_source = (installer_root / step_rel).read_bytes()
        if hashlib.sha256(step_source).hexdigest() != INSTALLER_FILES[step_rel]:
            raise ValueError("step2 template changed after pin validation")
        rendered = step_source.replace(b"##DISTRO##", distro.encode("ascii"))
        rendered = rendered.replace(b"##VGID##", uuid.encode("ascii"))
        rendered = rendered.replace(b"##PREBOOT##", uuid.encode("ascii"))
        step_target = app_root / "Contents/Resources/step2.sh.inert"
        info = write_bytes(step_target, inert_script(rendered), source_info[step_rel], step_rel)
        info["path"] = str(Path("templates/Finish Installation.app.inert/Contents/Resources/step2.sh.inert"))
        info["render"] = {"DISTRO": distro, "VGID": uuid, "PREBOOT": uuid}
        records.append(info)

        iapm_rel = "src/step2/IAPhysicalMedia.plist"
        info = copy_checked(installer_root / iapm_rel, templates / ".IAPhysicalMedia",
                            INSTALLER_FILES[iapm_rel])
        info.update({"path": "templates/.IAPhysicalMedia", "source": iapm_rel,
                     "source_sha256": INSTALLER_FILES[iapm_rel]})
        records.append(info)

        for destination, rel in required_stage.items():
            row = stage_files[rel]
            info = copy_checked(row["path"], output_root / destination, row["sha256"])
            info.update({"path": destination, "source": str(Path("stage") / rel),
                         "source_sha256": row["sha256"],
                         "stage_source_member": row.get("source_member")})
            records.append(info)

        candidate = output_root / "candidates" / "UNQUALIFIED-boot.bin"
        info = copy_checked(INLINE_SOURCE, candidate, INLINE_SHA256)
        info.update({"path": "candidates/UNQUALIFIED-boot.bin",
                     "source": str(INLINE_SOURCE.relative_to(PROJECT)),
                     "source_sha256": inline_info["sha256"],
                     "candidate_kind": "official fork-current inline; unchanged; no chainload variables"})
        records.append(info)

        receipt = {
            "schema": "j575d-stub-extras-v1", "profile": PROFILE,
            "installer_revision": INSTALLER_REVISION,
            "synthetic_identity": {"index": 153, "fake_uuid": uuid, "distro": distro},
            "source_stage": str(stage.relative_to(PROJECT)),
            "source_stage_receipt_sha256": STAGE_RECEIPT_SHA256,
            "source_asset_receipt_sha256": SOURCE_ASSET_RECEIPT_SHA256,
            "source_inline_manifest": str(INLINE_MANIFEST.relative_to(PROJECT)),
            "source_inline_sha256": INLINE_SHA256,
            "native_approved": False, "boot_qualified": False,
            "deployment_approved": False,
            "omitted": ["AdminUserRecoveryInfo.plist", "all_firmware.tar.gz", "vendorfw",
                        "stub_info.json", "deployable boot.bin", "logo.icns",
                        "Apple personalization", "APFS/partition changes", "native boot"],
            "files": sorted(records, key=lambda row: str(row["path"])),
        }
        with (output_root / "extras-receipt.json").open("x", encoding="utf-8") as stream:
            json.dump(receipt, stream, indent=2, sort_keys=True)
            stream.write("\n")
    except Exception:
        (output_root / "EXTRAS-PARTIAL.txt").write_text(
            "partial inert extras assembly; not deployable\n", encoding="utf-8")
        raise
    return output_root


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", required=True, type=Path,
                        help="existing verified stage under scratch/boot-stub-provisioning")
    parser.add_argument("--distro", default="Debian",
                        help="safe diagnostic DISTRO substitution (default: Debian)")
    args = parser.parse_args(argv)
    try:
        print(assemble(args.stage, args.distro))
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=os.sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
