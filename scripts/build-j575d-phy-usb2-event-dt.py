#!/usr/bin/env python3
"""Build the disabled, six-port USB2 event-resource DT candidate.

This extends only the frozen USB-common DTB.  It does not enable a PHY or
alter calibration properties; the captured resource-1 windows are added as a
new named resource for the six witnessed ports.
"""
from __future__ import annotations

import copy
import importlib.util
import json
import pathlib
import shutil
import struct
import subprocess
import tempfile
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[1]
CANONICAL_DTB = ROOT / "scratch/j575d-phy-usb-common-dt.04qu7uzz/candidate.dtb"
CANONICAL_DTB_SHA = "9b46e8022b11e7fa9c79601325eccfa415d0ddacf0568b1263d155b6aebe1e4c"
SERVICE = ROOT / "scratch/j575d-select-irq-audit.dzecri/host-registry/ioreg-service-text.txt"
SERVICE_SHA = "cf4f681047520d666fea5f9ddfbb4b4b87875240740ecde3cc147e29c524ebad"
RESOURCE_VERIFIER = ROOT / "scratch/j575d-usb2-resource1-2026-10-10/verify.py"
RESOURCE_VERIFIER_SHA = "04eb822d95cf6f7e0b104956c465ec2ac240c8c70c56c3ac495b091bd356c26a"
LAYOUT_SCRIPT = ROOT / "scripts/build-j575d-usb-layout.py"
LAYOUT_SCRIPT_SHA = "5617d5bf3ddf7c0c0fce7e8aa2a17a0a8dd264c4bc73b3f258b624c26efcbc2d"
PCIE_SCRIPT = ROOT / "scripts/build-j575d-pcie-dt.py"
PCIE_SCRIPT_SHA = "574e2cf4a5cac153180b4a137cc1d8c6fc1048f147cc51620abc8634338a8f63"
BASELINE_DTB = ROOT / "scratch/j575d-ace3-candidate.dif94rf2/candidate.dtb"
BASELINE_DTB_SHA = "832bdc15bcc9c0d5204a62e5d18b72574890b4df8e48b41dd2da5cf1f4c3d265"
EVENT_NAME = "usb2-event"
PORT_LABELS = ("atcphy0", "atcphy1", "atcphy2", "atcphy3",
               "atcphy0_die1", "atcphy1_die1")
EXPECTED_CAPTURE = {
    0: (0x702800000, 0x4000), 1: (0xB02800000, 0x4000),
    2: (0xF02800000, 0x4000), 3: (0x1302800000, 0x4000),
    4: (0x2702800000, 0x4000), 5: (0x2B02800000, 0x4000),
}


class CandidateError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise CandidateError(message)


def load_module(name: str, path: pathlib.Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    require(spec is not None and spec.loader is not None, f"cannot import {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_inputs() -> tuple[Any, Any, dict[int, tuple[int, int]], dict[str, dict[str, bytes]]]:
    import hashlib
    require(hashlib.sha256(CANONICAL_DTB.read_bytes()).hexdigest() == CANONICAL_DTB_SHA,
            "canonical USB-common DTB changed")
    require(hashlib.sha256(SERVICE.read_bytes()).hexdigest() == SERVICE_SHA,
            "captured service text changed")
    require(hashlib.sha256(RESOURCE_VERIFIER.read_bytes()).hexdigest() == RESOURCE_VERIFIER_SHA,
            "resource-1 verifier changed")
    require(hashlib.sha256(LAYOUT_SCRIPT.read_bytes()).hexdigest() == LAYOUT_SCRIPT_SHA,
            "USB layout helper changed")
    require(hashlib.sha256(PCIE_SCRIPT.read_bytes()).hexdigest() == PCIE_SCRIPT_SHA,
            "PCIe transitive helper changed")
    require(hashlib.sha256(BASELINE_DTB.read_bytes()).hexdigest() == BASELINE_DTB_SHA,
            "frozen baseline DTB changed")
    layout = load_module("j575d_usb_layout_for_event", LAYOUT_SCRIPT)
    verifier = load_module("j575d_resource1_verifier_for_event", RESOURCE_VERIFIER)
    captured = verifier.same_node_resource1(SERVICE.read_text().splitlines())
    require(captured == EXPECTED_CAPTURE, "captured resource-1 banks changed")
    before = layout.read_dtb(CANONICAL_DTB)
    return layout, before, captured, copy.deepcopy(before)


def cells(raw: bytes) -> tuple[int, ...]:
    require(len(raw) % 4 == 0, "non-cell property")
    return struct.unpack(f">{len(raw) // 4}I", raw)


def strings(raw: bytes) -> tuple[str, ...]:
    require(raw.endswith(b"\0"), "unterminated strings")
    return tuple(value.decode() for value in raw[:-1].split(b"\0"))


def physical_to_child(layout: Any, tree: dict[str, dict[str, bytes]], path: str,
                      physical: int, size: int) -> int:
    parent = path.rsplit("/", 1)[0]
    ranges = cells(tree[parent]["ranges"])
    require(len(ranges) % 6 == 0, f"{path}: malformed ranges")
    matches = []
    for i in range(0, len(ranges), 6):
        child = (ranges[i] << 32) | ranges[i + 1]
        host = (ranges[i + 2] << 32) | ranges[i + 3]
        extent = (ranges[i + 4] << 32) | ranges[i + 5]
        if host <= physical and physical + size <= host + extent:
            matches.append(child + physical - host)
    require(len(matches) == 1, f"{path}: physical event bank not in one parent range")
    return matches[0]


def plan(layout: Any, before: dict[str, dict[str, bytes]],
         captured: dict[int, tuple[int, int]]) -> dict[str, dict[str, bytes]]:
    require(tuple(captured) == tuple(range(6)), "event capture must have six numbered ports")
    require(captured == EXPECTED_CAPTURE, "event capture bank/port mapping changed")
    changes: dict[str, dict[str, bytes]] = {}
    for port, label in enumerate(PORT_LABELS):
        path = layout.symbol(before, label)
        props = before[path]
        require(strings(props["compatible"]) ==
                ("apple,t6031-atcphy", "apple,t8122-atcphy"), f"{label}: M3 compatible pair")
        require(EVENT_NAME not in strings(props["reg-names"]), f"{label}: event name already exists")
        require(strings(props["reg-names"]) ==
                ("core", "lpdptx", "axi2af", "usb2phy", "pipehandler", "fabric"),
                f"{label}: legacy resource names changed")
        require(props.get("status") == b"disabled\0", f"{label}: status is not disabled")
        require(len(props["reg"]) == 6 * 16, f"{label}: original resource shape")
        physical, size = captured[port]
        require(size == 0x4000, f"{label}: event window size")
        child = physical_to_child(layout, before, path, physical, size)
        changes[path] = {
            "reg": props["reg"] + struct.pack(">QQ", child, size),
            "reg-names": props["reg-names"] + EVENT_NAME.encode() + b"\0",
        }
    for path, props in before.items():
        if EVENT_NAME in strings(props.get("reg-names", b"\0")) and path not in changes:
            raise CandidateError(f"unexpected existing event resource at {path}")
    require(len(changes) == 6, "expected exactly six event-resource nodes")
    return changes


def reservations(path: pathlib.Path) -> tuple[tuple[int, ...], tuple[tuple[int, int], ...]]:
    raw = path.read_bytes()
    header = struct.unpack_from(">10I", raw)
    pos, entries = header[4], []
    while True:
        address, length = struct.unpack_from(">QQ", raw, pos)
        pos += 16
        if address == length == 0:
            return header[5:8], tuple(entries)
        entries.append((address, length))


def sha(path: pathlib.Path) -> str:
    return __import__("hashlib").sha256(path.read_bytes()).hexdigest()


def property_delta(before: dict[str, dict[str, bytes]],
                  after: dict[str, dict[str, bytes]]) -> int:
    require(set(before) == set(after), "baseline node set changed")
    return sum(before[path].get(name) != after[path].get(name)
               for path in before for name in set(before[path]) | set(after[path]))


def validate(layout: Any, before: dict[str, dict[str, bytes]],
             after: dict[str, dict[str, bytes]], captured: dict[int, tuple[int, int]]) -> dict[str, int]:
    expected = plan(layout, before, captured)
    require(set(before) == set(after), "DT node set changed")
    for path, props in before.items():
        wanted = {**props, **expected.get(path, {})}
        require(after[path] == wanted, f"unexpected property change: {path}")
    for port, label in enumerate(PORT_LABELS):
        path = layout.symbol(after, label)
        names = strings(after[path]["reg-names"])
        require(names[-1] == EVENT_NAME and len(names) == 7, f"{label}: event name position")
        require(len(names) == len(set(names)), f"{label}: duplicate resource name")
        require(len(after[path]["reg"]) == 7 * 16, f"{label}: event resource is not 16 bytes")
        physical = layout.translated_regs(after, path)
        require(physical[-1] == captured[port], f"{label}: translated event range")
        require(after[path]["status"] == b"disabled\0", f"{label}: enabled")
    untouched = set(after) - set(expected)
    require(all(EVENT_NAME not in strings(after[path].get("reg-names", b"\0"))
            for path in untouched), "event resource leaked to an inherited node")
    current = property_delta(before, after)
    baseline = layout.read_dtb(BASELINE_DTB)
    original = property_delta(baseline, after)
    require(current == 12 and original == 42, f"property counts changed: {current}/{original}")
    return {"event_nodes": 6, "changed_properties_relative_common": current,
            "changed_properties_relative_original": original}


def main() -> int:
    layout, before, captured, _ = load_inputs()
    require(not __import__("sys").argv[1:], "this fixed-evidence builder takes no arguments")
    fdtput, dtc = shutil.which("fdtput"), shutil.which("dtc")
    require(fdtput and dtc, "fdtput/dtc unavailable")
    work = pathlib.Path(tempfile.mkdtemp(prefix="j575d-usb2-event-dt.", dir=ROOT / "scratch"))
    candidate = work / "candidate.dtb"
    shutil.copyfile(CANONICAL_DTB, candidate)
    changes = plan(layout, before, captured)
    for path, props in changes.items():
        for name, raw in props.items():
            numeric = name == "reg"
            values = [f"{value:x}" for value in cells(raw)] if numeric else list(strings(raw))
            run = subprocess.run([fdtput, "-t", "x" if numeric else "s", str(candidate),
                                  path, name, *values], capture_output=True, text=True)
            require(run.returncode == 0, f"fdtput {path}/{name}: {run.stderr[:200]}")
    after = layout.read_dtb(candidate)
    counts = validate(layout, before, after, captured)
    require(reservations(candidate) == reservations(CANONICAL_DTB), "reservations changed")
    dts = work / "candidate.dts"
    run = subprocess.run([dtc, "-I", "dtb", "-O", "dts", "-o", str(dts), str(candidate)],
                         capture_output=True, text=True)
    (work / "dtc.stderr").write_text(run.stderr)
    require(run.returncode == 0, f"dtc decompile: {run.stderr[:200]}")
    roundtrip = work / "roundtrip.dtb"
    run = subprocess.run([dtc, "-I", "dts", "-O", "dtb", "-o", str(roundtrip), str(dts)],
                         capture_output=True, text=True)
    (work / "roundtrip.stderr").write_text(run.stderr)
    require(run.returncode == 0, f"dtc roundtrip: {run.stderr[:200]}")
    roundtrip_tree = layout.read_dtb(roundtrip)
    validate(layout, before, roundtrip_tree, captured)
    require(reservations(roundtrip) == reservations(candidate),
            "roundtrip reservations changed")
    require(roundtrip_tree == layout.read_dtb(candidate), "roundtrip tree changed")
    candidate_sha = sha(candidate)
    roundtrip_sha = sha(roundtrip)
    manifest = {"schema_version": 1, "status": "offline_disabled_usb2_event_candidate",
                "scope": "DT resource packaging only; no enablement or hardware qualification",
                "workspace": str(work.relative_to(ROOT)), "canonical_dtb_sha256": CANONICAL_DTB_SHA,
                "baseline_dtb_sha256": BASELINE_DTB_SHA,
                "service_sha256": SERVICE_SHA, "resource_verifier": str(RESOURCE_VERIFIER.relative_to(ROOT)),
                "resource_verifier_sha256": RESOURCE_VERIFIER_SHA,
                "layout_script_sha256": LAYOUT_SCRIPT_SHA, "pcie_script_sha256": PCIE_SCRIPT_SHA,
                "builder_sha256": sha(pathlib.Path(__file__)),
                "labels": list(PORT_LABELS), "event_name": EVENT_NAME,
                "captured_resource1": {str(k): [hex(v[0]), hex(v[1])] for k, v in captured.items()},
                "reservations_preserved": True, "roundtrip_tree_identical": True,
                "candidate_dtb_sha256": candidate_sha, "roundtrip_dtb_sha256": roundtrip_sha,
                "dtc_stderr_sha256": sha(work / "dtc.stderr"),
                "roundtrip_stderr_sha256": sha(work / "roundtrip.stderr"),
                "event_reg_bytes": 16, **counts}
    (work / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"output": str(work.relative_to(ROOT)), **counts}, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CandidateError as exc:
        raise SystemExit(f"ERROR: {exc}")
