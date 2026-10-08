#!/usr/bin/env python3
"""Build a disabled J575d DT candidate with generic and USB-only calibration.

This extends the frozen Fabric builder without modifying its inputs or outputs.
USB records are separate from generic, lane, CIO80-default and USB2 channels.
"""

from __future__ import annotations

import importlib.util
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
FABRIC = ROOT / "scripts/build-j575d-phy-fabric-dt.py"
FABRIC_SHA = "813c55a65af4dda2161c9aeabbbfa22328f101681d41a9fd208e44bcac0f92e7"
PATCH = ROOT / "patches/linux/j575d-602042bf/0005-apple-atcphy-m3-usb-common-calibration.patch"
PATCH_SHA = "ab77204e6dadbd78163eb604592aaf683d67c061e826ac0c3f56a5f815606551"
USB_PROPERTY = "apple,tunable-usb-common"
USB_GROUPS = ("tunable_AUS40CMN_SHM", "tunable_AUSPLL_CORE", "tunable_CIO4PLL_CORE")
USB_ROWS = (1, 7, 4)
PROOFS = {
    "scratch/j575d-usb-mode-scope-2026-10-08/report.md":
        "0c5e22f2ecfcf9da8a0fdcdfd638e50c28d47fa7a0ebebdb22706b06a6cac4c1",
    "scratch/j575d-usb-mode-scope-2026-10-08/verify-usb-helper-v4.py":
        "f4ff3bf34a26611281c586100f3190fe2e87631529d6d4908cf4f43a469181d7",
    "scratch/j575d-usb-mode-scope-2026-10-08/verify-usb-helper-v4.out":
        "96e00cf92ab6aeb99b783fe885e22de79f8ea13c4fb0c41b8e879c5750d5498b",
}


class CandidateError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise CandidateError(message)


def load_inputs() -> tuple[Any, Any, dict, dict, dict]:
    import hashlib

    require(hashlib.sha256(FABRIC.read_bytes()).hexdigest() == FABRIC_SHA,
            "frozen Fabric builder changed")
    spec = importlib.util.spec_from_file_location("j575d_frozen_fabric", FABRIC)
    require(spec is not None and spec.loader is not None, "Fabric builder import")
    fabric = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fabric)
    require(fabric.sha(PATCH) == PATCH_SHA, "USB-common driver patch changed")
    for relative, expected in PROOFS.items():
        require(fabric.sha(ROOT / relative) == expected, f"USB proof changed: {relative}")
    decoder = fabric.load_decoder()
    usb, before, capture, decoded = fabric.receipts(decoder)
    return fabric, usb, before, capture, decoded


def plan(fabric: Any, usb: Any, before: dict, decoded: dict) -> dict[str, dict[str, bytes]]:
    changes = fabric.plan(usb, before, decoded)
    for port in decoded["ports"]:
        path = usb.symbol(before, port["linux_label"])
        require(USB_PROPERTY not in before[path], "existing USB tunable overwritten")
        blocks = {block["source_property"]: block for block in port["blocks"]}
        ordered = [blocks[name] for name in USB_GROUPS]
        require(tuple(len(block["records"]) for block in ordered) == USB_ROWS,
                "USB group row counts changed")
        core = next(window for window in port["linux_windows"] if window["name"] == "core")
        raw = fabric.tuples(ordered, core["base"], core["size"])
        require(len(raw) == 12 * 12, "expected twelve USB rows per port")
        changes[path][USB_PROPERTY] = raw
    require(len(changes) == 6, "expected six USB PHY paths")
    return changes


def validate(fabric: Any, usb: Any, before: dict, after: dict, decoded: dict) -> dict[str, int]:
    expected = plan(fabric, usb, before, decoded)
    require(set(before) == set(after), "DT node set changed")
    changed = 0
    generic_after = {}
    for path, properties in before.items():
        wanted = {**properties, **expected.get(path, {})}
        require(after[path] == wanted, f"unexpected property delta: {path}")
        changed += sum(properties.get(name) != value for name, value in wanted.items())
        generic_after[path] = dict(after[path])
        if path in expected:
            generic_after[path].pop(USB_PROPERTY)
    generic = fabric.validate(usb, before, generic_after, decoded)
    usb_rows = sum(len(properties[USB_PROPERTY]) // 12 for properties in expected.values())
    require(usb_rows == 72 and changed == generic["changed_properties"] + 6 == 42,
            "USB/generic candidate counts changed")
    return {**generic, "usb_common_records": usb_rows,
            "total_records": generic["generic_records"] + usb_rows,
            "changed_properties": changed}


def main() -> int:
    require(len(sys.argv) == 1, "this fixed-evidence builder takes no arguments")
    fabric, usb, before, _, decoded = load_inputs()
    changes = plan(fabric, usb, before, decoded)
    fdtput, dtc = shutil.which("fdtput"), shutil.which("dtc")
    require(bool(fdtput) and bool(dtc), "fdtput/dtc unavailable")
    work = pathlib.Path(tempfile.mkdtemp(prefix="j575d-phy-usb-common-dt.", dir=ROOT / "scratch"))
    candidate = work / "candidate.dtb"
    decoder = fabric.load_decoder()
    shutil.copyfile(ROOT / decoder.DTB, candidate)
    commands = []
    for path, properties in changes.items():
        for name, raw in properties.items():
            numeric = name == "reg" or name in (*fabric.ASSIGNED, USB_PROPERTY)
            values = [f"{value:x}" for value in fabric.cells(raw)] if numeric else list(fabric.strings(raw))
            command = [fdtput, "-t", "x" if numeric else "s", str(candidate), path, name, *values]
            run = subprocess.run(command, text=True, capture_output=True)
            require(run.returncode == 0, f"fdtput failed for {path}/{name}: {run.stderr[:300]}")
            commands.append(command)
    after = usb.read_dtb(candidate)
    counts = validate(fabric, usb, before, after, decoded)
    require(fabric.reservations(candidate) == fabric.reservations(ROOT / decoder.DTB),
            "DTB version, boot CPU or reservations changed")
    for args, output, error_log in (
        (["-I", "dtb", "-O", "dts"], work / "candidate.dts", "dtc.stderr"),
        (["-I", "dts", "-O", "dtb"], work / "roundtrip.dtb", "roundtrip.stderr"),
    ):
        source = candidate if args[1] == "dtb" else work / "candidate.dts"
        command = [dtc, *args, "-o", str(output), str(source)]
        run = subprocess.run(command, text=True, capture_output=True)
        (work / error_log).write_text(run.stderr)
        require(run.returncode == 0, f"candidate DTC failed: {error_log}")
        commands.append(command)
    roundtrip = work / "roundtrip.dtb"
    require(usb.read_dtb(roundtrip) == after and
            fabric.reservations(roundtrip) == fabric.reservations(candidate),
            "DTC roundtrip changed candidate")
    manifest = {
        "scope": "disabled generic and USB-mode calibration candidate, not boot approved",
        "inputs": {**decoder.INPUTS, **PROOFS,
                   str(fabric.DECODER.relative_to(ROOT)): fabric.DECODER_SHA,
                   str(fabric.PATCH.relative_to(ROOT)): fabric.PATCH_SHA,
                   str(FABRIC.relative_to(ROOT)): FABRIC_SHA,
                   str(PATCH.relative_to(ROOT)): PATCH_SHA},
        "script_sha256": fabric.sha(pathlib.Path(__file__)),
        "decoded_sha256": fabric.DECODED_SHA,
        "candidate_sha256": fabric.sha(candidate),
        "roundtrip_sha256": fabric.sha(roundtrip),
        "roundtrip_tree_identical": True,
        "reservations_and_boot_cpu_preserved": True,
        "counts": counts,
        "usb_common_source_order": list(USB_GROUPS),
        "usb_common_rows_per_port": list(USB_ROWS),
        "usb_common_linux_modes": ["APPLE_ATCPHY_MODE_USB3", "APPLE_ATCPHY_MODE_USB3_DP"],
        "numeric_native_enum_identity_claimed": False,
        "cio80_default_records_unconverted": 30,
        "usb2_records_unconverted": 12,
        "native_validated": False,
        "mmio_performed": False,
        "phy_nodes_disabled": True,
        "commands": commands,
    }
    (work / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"output": str(work.relative_to(ROOT)),
                      "dtb_sha256": fabric.sha(candidate), **counts,
                      "native_validated": False}, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (CandidateError, OSError, KeyError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
