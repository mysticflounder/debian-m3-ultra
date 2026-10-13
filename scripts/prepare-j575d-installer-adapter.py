#!/usr/bin/env python3
"""Prepare a hash-pinned, non-executed installer source adaptation.

The generated tree is an audit/development artifact.  It is not an installer,
does not read host state, and never mounts or mutates a target volume.
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
import plistlib
import re
import shutil
import tempfile
from pathlib import Path
from typing import Any


PROJECT = Path(__file__).resolve().parents[1]
SCRATCH = PROJECT / "scratch" / "boot-stub-provisioning"
INSTALLER_REVISION = "e93743d52178b3e26e428fa05174ef549abf30cb"
INSTALLER = SCRATCH / f"asahi-installer-{INSTALLER_REVISION}"
PROFILE = "26A428-j575d"
SYNTHETIC_UUID = "00000000-0000-4000-8000-000000000001"
INLINE_MANIFEST = PROJECT / "scratch/j575d-inline-package.6uf7698y/manifest.json"
INLINE_MANIFEST_SHA256 = "2bb08f03ad6ecb90d6f369b821ec5172bc184cbbd9f77f742b112aacca5a6997"
INLINE_SOURCE = PROJECT / "scratch/j575d-inline-package.6uf7698y/UNQUALIFIED-m1n1-inline.bin"
INLINE_SHA256 = "b2b2fbeefd35f953ca67b9d3315bd33a95df9ed8e447e7a5756d1899aa1ab30e"
STAGE = SCRATCH / "stage-ohgqmpjl"
STAGE_MANIFEST = STAGE / "Preboot/00000000-0000-4000-8000-000000000001/restore/BuildManifest.plist"
STAGE_MANIFEST_SHA256 = "268afbfaf305931efba6a55e299bffeb0f759eff2e4698209f6612761b4dbd78"
STAGE_SYSTEM_VERSION = STAGE / "Preboot/00000000-0000-4000-8000-000000000001/restore/SystemVersion.plist"
STAGE_SYSTEM_VERSION_SHA256 = "49533878051e489e93e6302a63c1f4758c41f3aeea203fc4dc41744f21f9133e"

SOURCE_PINS = {
    "src/stub.py": "b4a0dd897ec9c3dc2d9d47b661a2c41ecd58adf0b33e2ad43cec6c2266a1ff8c",
    "src/osinstall.py": "2d6d682d11d9ff5636a4146c5b11d720ce10990acfaee212139b497d3a1dde63",
    "src/m1n1.py": "7aacc62b348f1f66cc3aad6aa698443c37efdc0f3ed8271adb70387fa4b3a4af",
}
TEMPLATE_PINS = {
    "step2/step2.sh": "db313de97dcca93804d398f4bbdcf2d6f9647729c6853f36d9fa247e5730d4af",
    "step2/IAPhysicalMedia.plist": "1066a03164a6d0720730217f4015aed8a0411c668958530fbb64cf18a21cdd3a",
    "step2/Finish Installation.app/Contents/Info.plist": "cb81b007718e278b0c9d37df042b088875312e69456140c93480c49c1e3f2113",
    "step2/Finish Installation.app/Contents/MacOS/step2_launcher.sh": "a160bd8c5c98c42943190c06b5c3f8b12ef35dd4bcb2015de53e0c2942fe6a39",
    "step2/Finish Installation.app/Contents/Resources/en.lproj/InfoPlist.strings": "7fbbe415225c3352af947c3daabc073182cc108ab048a99bb4c85fa783810c11",
}


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def canonical_scratch() -> Path:
    project = PROJECT.resolve(strict=True)
    current = project
    for component in SCRATCH.relative_to(PROJECT).parts:
        current /= component
        if current.is_symlink():
            raise ValueError("canonical scratch contains a symlink")
    root = SCRATCH.resolve(strict=False)
    try:
        root.relative_to(project)
    except ValueError as exc:
        raise ValueError("scratch escapes project") from exc
    return root


def _regular(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"{label} must be a regular file: {path}")


def _inside(path: Path, root: Path, label: str) -> Path:
    resolved = path.resolve(strict=True)
    try:
        resolved.relative_to(root.resolve(strict=True))
    except ValueError as exc:
        raise ValueError(f"{label} escapes its root") from exc
    return resolved


def validate_source(source_root: Path) -> dict[str, str]:
    """Validate the three source files whose contracts are adapted."""
    source_root = source_root.resolve(strict=True)
    if not source_root.is_dir():
        raise ValueError("source root is not a directory")
    actual: dict[str, str] = {}
    for relative, expected in SOURCE_PINS.items():
        path = source_root / relative
        _regular(path, relative)
        digest = sha256(path)
        if digest != expected:
            raise ValueError(f"{relative} SHA-256 mismatch: {digest}")
        actual[relative] = digest
    return actual


def restore_bundle_rel(bootcaches: dict[str, Any], profile: str) -> str:
    """Resolve the restore directory without weakening legacy profiles."""
    if profile == PROFILE:
        return "restore"
    # Deliberately preserve the pinned installer's legacy lookup semantics.
    value = bootcaches["bless2"]["RestoreBundlePath"]
    if not isinstance(value, str) or not value or value.startswith("/") or "\\" in value:
        raise ValueError("unsafe legacy RestoreBundlePath")
    if any(part in ("", ".", "..") for part in Path(value).parts):
        raise ValueError("unsafe legacy RestoreBundlePath")
    return value


def resolve_restore_root(preboot_root: Path, vgid: str, bootcaches: dict[str, Any], profile: str) -> Path:
    if not vgid or Path(vgid).name != vgid or vgid in (".", ".."):
        raise ValueError("unsafe volume-group identifier")
    root = (preboot_root / vgid / restore_bundle_rel(bootcaches, profile)).resolve()
    try:
        root.relative_to(preboot_root.resolve())
    except ValueError as exc:
        raise ValueError("restore root escapes Preboot") from exc
    return root


def patch_stub_source(source: bytes, profile: str = PROFILE) -> bytes:
    """Patch only the three restore-root call sites in a copied stub.py."""
    if profile != PROFILE:
        raise ValueError("only the pinned modern profile is adaptable")
    marker = b'bless2["RestoreBundlePath"]'
    if source.count(marker) != 3:
        raise ValueError("unexpected RestoreBundlePath call-site count")
    symlink_block = (
        b'        sys_restore_bundle = os.path.join(self.osi.system, bless2["RestoreBundlePath"])\n'
        b"        if os.path.lexists(sys_restore_bundle):\n"
        b"            os.unlink(sys_restore_bundle)\n"
        b"        os.symlink(restore_bundle, sys_restore_bundle)"
    )
    if source.count(symlink_block) != 1:
        raise ValueError("unexpected legacy System restore symlink block")
    modern_safe_symlink_block = (
        b'        if getattr(self, "restore_profile", None) != "26A428-j575d":\n'
        + symlink_block.replace(b"        ", b"            ")
    )
    source = source.replace(symlink_block, modern_safe_symlink_block, 1)
    source = source.replace(marker, b"self.restore_bundle_rel()")
    anchor = b"    def get_paths(self):\n"
    if source.count(anchor) != 1:
        raise ValueError("unexpected get_paths anchor count")
    function = (
        b"    def restore_bundle_rel(self):\n"
        b"        \"\"\"Resolve the modern explicit restore directory.\"\"\"\n"
        b"        if getattr(self, \"restore_profile\", None) == \"26A428-j575d\":\n"
        b"            identity = getattr(self, \"identity\", {})\n"
        b"            info = identity.get(\"Info\", {})\n"
        b"            if (info.get(\"BuildNumber\") != \"26A428\" or\n"
        b"                info.get(\"Variant\") != \"macOS Customer\" or\n"
        b"                info.get(\"RestoreBehavior\") != \"Erase\" or\n"
        b"                info.get(\"DeviceClass\") != \"j575dap\" or\n"
        b"                identity.get(\"ApBoardID\") != \"0x44\" or\n"
        b"                identity.get(\"ApChipID\") != \"0x6032\"):\n"
        b"                raise ValueError(\"26A428-j575d restore profile identity mismatch\")\n"
        b"            return \"restore\"\n"
        b"        return self.bootcaches[\"bless2\"][\"RestoreBundlePath\"]\n\n"
    )
    return source.replace(anchor, function + anchor, 1)


def copy_source_tree(source_root: Path, destination: Path) -> list[dict[str, Any]]:
    """Copy source bytes, resolving only the pinned in-tree firmware link."""
    records: list[dict[str, Any]] = []
    source_root = source_root.resolve(strict=True)
    source_entries = list(sorted(source_root.rglob("*")))
    # The checkout's src/asahi_firmware link points to the sibling vendored
    # package.  Materialize that directory in the copy, never retain a link.
    link = source_root / "asahi_firmware"
    if link.is_symlink():
        target = link.resolve(strict=True)
        try:
            target.relative_to(source_root.parent)
        except ValueError as exc:
            raise ValueError("source firmware link escapes pinned tree") from exc
        source_entries = [entry for entry in source_entries if link not in entry.parents]
        source_entries.extend(sorted(target.rglob("*")))
        link_target = target
    else:
        link_target = None
    for source in source_entries:
        if link_target is not None and source in (link, link_target):
            continue
        if link_target is not None and source.is_relative_to(link_target):
            relative = Path("asahi_firmware") / source.relative_to(link_target)
        else:
            relative = source.relative_to(source_root)
        if "__pycache__" in relative.parts:
            continue
        target = destination / relative
        if source.is_symlink():
            raise ValueError(f"source subtree contains symlink: {relative}")
        if source.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        if not source.is_file():
            raise ValueError(f"unsupported source entry: {relative}")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        os.chmod(target, 0o644)
        records.append({"path": str(relative), "bytes": target.stat().st_size,
                        "sha256": sha256(target)})
    return records


def source_derived_stub_info(system_version: dict[str, Any], identity: dict[str, Any]) -> dict[str, Any]:
    """Emit ``install_files``' field shape from pinned manifest inputs."""
    info = identity["Info"]
    system_version = dict(system_version)
    system_version["ProductUserVisibleVersion"] += " (stub)"
    return {
        "schema": "j575d-synthetic-stub-info-v1",
        "synthetic": True,
        "complete": False,
        "vgid": SYNTHETIC_UUID,
        "system_version": system_version,
        "manifest_info": {
            "build_number": info["BuildNumber"],
            "variant": info["Variant"],
            "device_class": info["DeviceClass"],
            "board_id": identity["ApBoardID"],
            "chip_id": identity["ApChipID"],
        },
        "omitted": ["admin_users", "real target VGID", "Apple personalization"],
    }


def load_pinned_stub_inputs() -> tuple[dict[str, Any], dict[str, Any]]:
    """Read only the pinned reduced manifest and SystemVersion fixture."""
    for path, expected in ((STAGE_MANIFEST, STAGE_MANIFEST_SHA256),
                           (STAGE_SYSTEM_VERSION, STAGE_SYSTEM_VERSION_SHA256)):
        _regular(path, str(path))
        if sha256(path) != expected:
            raise ValueError(f"pinned stage input changed: {path}")
    manifest = plistlib.loads(STAGE_MANIFEST.read_bytes())
    identities = manifest.get("BuildIdentities", [])
    if len(identities) != 1:
        raise ValueError("reduced manifest must contain exactly one identity")
    identity = identities[0]
    return plistlib.loads(STAGE_SYSTEM_VERSION.read_bytes()), identity


def synthetic_stub_info() -> dict[str, Any]:
    system_version, identity = load_pinned_stub_inputs()
    return source_derived_stub_info(system_version, identity)


def inline_profile() -> dict[str, Any]:
    _regular(INLINE_MANIFEST, "inline manifest")
    if sha256(INLINE_MANIFEST) != INLINE_MANIFEST_SHA256:
        raise ValueError("inline manifest SHA-256 mismatch")
    manifest = json.loads(INLINE_MANIFEST.read_text(encoding="utf-8"))
    output = manifest.get("outputs", {}).get("UNQUALIFIED-m1n1-inline.bin", {})
    _regular(INLINE_SOURCE, "inline candidate")
    if (output.get("sha256") != INLINE_SHA256 or
            output.get("path") != str(INLINE_SOURCE.relative_to(PROJECT)) or
            output.get("length") != INLINE_SOURCE.stat().st_size or
            sha256(INLINE_SOURCE) != INLINE_SHA256 or
            manifest.get("qualification") != "UNQUALIFIED"):
        raise ValueError("inline candidate pin/profile mismatch")
    return {
        "kind": "direct-inline-diagnostic",
        "candidate_sha256": INLINE_SHA256,
        "qualification": "UNQUALIFIED",
        "efi_chainload": False,
        "m1n1_variables": [],
        "evidence": [
            "scratch/j575d-inline-package.6uf7698y/README.txt: payload starts at chosen.bootargs",
            "src/osinstall.py: chainload is only for template next_object",
            "candidate is not installer-generated boot.bin",
        ],
    }


def _uuid(value: str, label: str) -> str:
    import uuid
    if not isinstance(value, str) or not re.fullmatch(
            r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", value):
        raise ValueError(f"{label} must be a UUID")
    try:
        uuid.UUID(value)
    except (ValueError, AttributeError, TypeError) as exc:
        raise ValueError(f"{label} must be a UUID") from exc
    return value.upper()


def render_candidate_files(vgid: str, preboot_vgid: str,
                           distro: str = "Debian") -> dict[str, Any]:
    """Return verified original templates and direct-inline bytes without writes."""
    vgid = _uuid(vgid, "VGID")
    preboot_vgid = _uuid(preboot_vgid, "Preboot VGID")
    if not distro or any(char not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .+():_-" for char in distro):
        raise ValueError("unsafe distro")
    source_root = _inside(INSTALLER / "src", canonical_scratch(), "installer source")
    files: dict[str, bytes] = {}
    pins: dict[str, str] = {}
    for relative, expected in TEMPLATE_PINS.items():
        source = source_root / relative
        _regular(source, relative)
        if sha256(source) != expected:
            raise ValueError(f"template SHA-256 mismatch: {relative}")
        data = source.read_bytes()
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError(f"template changed during read: {relative}")
        if relative == "step2/step2.sh":
            for marker, value in ((b"##DISTRO##", distro.encode("ascii")),
                                  (b"##VGID##", vgid.encode("ascii")),
                                  (b"##PREBOOT##", preboot_vgid.encode("ascii"))):
                if marker not in data:
                    raise ValueError(f"missing template marker: {marker!r}")
                data = data.replace(marker, value)
            destination = "Finish Installation.app/Contents/Resources/step2.sh"
        elif relative.startswith("step2/Finish Installation.app/"):
            destination = relative[len("step2/"):]
        else:
            destination = ".IAPhysicalMedia"
        files[destination] = data
        pins[destination] = hashlib.sha256(data).hexdigest()
    inline = INLINE_SOURCE.read_bytes()
    if hashlib.sha256(inline).hexdigest() != INLINE_SHA256:
        raise ValueError("inline candidate changed")
    boot_path = "Finish Installation.app/Contents/Resources/boot.bin"
    files[boot_path] = inline
    pins[boot_path] = INLINE_SHA256
    return {"profile": PROFILE, "vgid": vgid, "preboot_vgid": preboot_vgid,
            "files": files, "pins": pins, "native_approved": False,
            "deployment_approved": False}


def assemble() -> Path:
    scratch = canonical_scratch()
    source_root = _inside(INSTALLER, scratch, "installer source")
    source_hashes = validate_source(source_root)
    inline = inline_profile()
    output = Path(tempfile.mkdtemp(prefix="provisioning-adaptation-", dir=scratch))
    try:
        copied = copy_source_tree(source_root / "src", output / "source-adapted" / "src")
        stub = output / "source-adapted" / "src/stub.py"
        original = stub.read_bytes()
        if sha256(stub) != source_hashes["src/stub.py"]:
            raise ValueError("copied stub.py changed before patch")
        adapted = patch_stub_source(original)
        stub.write_bytes(adapted)
        os.chmod(stub, 0o644)
        for row in copied:
            if row["path"] == "stub.py":
                row["source_sha256"] = row.pop("sha256")
                row["sha256"] = sha256(stub)
                row["patched"] = True
        (output / "stub_info.synthetic.json").write_text(
            json.dumps(synthetic_stub_info(), indent=2, sort_keys=True) + "\n",
            encoding="utf-8")
        (output / "adapter-profile.json").write_text(json.dumps({
            "profile": PROFILE,
            "restore_profile_attribute": "26A428-j575d",
            "caller_must_set": "StubInstaller.restore_profile after target metadata validation",
            "source_execution": "not performed by this adapter",
        }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        template = {
            "schema": "j575d-installer-deployment-template-v1",
            "profile": PROFILE,
            "restore_bundle_rel": "restore",
            "vgid": "${REAL_VGID}",
            "preboot_vgid": "${REAL_PREBOOT_VGID}",
            "preboot_mount": "${REAL_PREBOOT_MOUNT}",
            "system_mount": "${REAL_SYSTEM_MOUNT}",
            "recovery_mount": "${REAL_RECOVERY_MOUNT}",
            "admin_user_recovery_info": {
                "required": True,
                "path": "${ADMIN_USER_RECOVERY_INFO}",
                "source_reference": "src/stub.py:171-192",
            },
            "logo": {
                "required": False,
                "offline_action": "skip",
                "source_reference": "src/stub.py:273-290",
                "reason": "cosmetic Finder metadata; no bytes fabricated",
            },
            "system_restore_symlink": {
                "required": False,
                "offline_action": "skip-modern-profile",
                "source_reference": "src/stub.py:345-348",
            },
            "boot": inline,
            "native_approved": False,
            "deployment_approved": False,
            "omitted": ["mounts", "bputil", "bless", "kmutil", "firmware", "admin credentials"],
        }
        (output / "deployment-template.json").write_text(
            json.dumps(template, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        (output / "adapter-contract.md").write_text(
            "# j575d installer adapter contract\n\n"
            "This copied source is not executed by the adapter. Set `restore_profile` "
            "to `26A428-j575d` only after target metadata validation; the copied "
            "method independently checks build 26A428, device j575dap, board 0x44, "
            "and chip 0x6032. The modern "
            "profile uses explicit Preboot `<VGID>/restore` and skips the legacy "
            "System restore symlink. Other profiles retain the original plist "
            "lookup and symlink behavior.\n\n"
            "`stub_info.synthetic.json` is a source-shaped diagnostic fixture: it "
            "omits `admin_users` and is incomplete. The logo remains an optional "
            "cosmetic target-volume operation. The direct-inline candidate is "
            "UNQUALIFIED and has no EFI/chainload variables; this is not a finished "
            "installer `boot.bin`. No mounts, disk operations, personalization, "
            "or host-private reads occur here. `render_candidate_files()` returns "
            "verified original template bytes for a caller-owned disposable image; "
            "it performs no writes.\n",
            encoding="utf-8")
        receipt = {
            "schema": "j575d-installer-adapter-v1",
            "profile": PROFILE,
            "installer_revision": INSTALLER_REVISION,
            "source_hashes": source_hashes,
            "stub_info_inputs": {
                "manifest": {"path": str(STAGE_MANIFEST.relative_to(PROJECT)),
                              "sha256": STAGE_MANIFEST_SHA256},
                "system_version": {"path": str(STAGE_SYSTEM_VERSION.relative_to(PROJECT)),
                                    "sha256": STAGE_SYSTEM_VERSION_SHA256},
            },
            "copied_files": copied,
            "patched": {"path": "source-adapted/src/stub.py", "restore_calls": 3,
                         "adapted_sha256": sha256(stub)},
            "synthetic_stub_info": "stub_info.synthetic.json",
            "deployment_template": "deployment-template.json",
            "native_approved": False,
            "deployment_approved": False,
        }
        (output / "adapter-receipt.json").write_text(
            json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return output
    except Exception as exc:
        (output / "adapter-failed.txt").write_text(
            f"assembly failed before completion: {type(exc).__name__}: {exc}\n",
            encoding="utf-8")
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    output = assemble()
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
