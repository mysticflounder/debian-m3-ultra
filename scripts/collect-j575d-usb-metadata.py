#!/usr/bin/env python3
"""Collect bounded public J575d USB/ATC/SPMI metadata from macOS ioreg.

The complete ioreg text stream is consumed in memory and never written.  Only
allow-listed public node properties and the named ATC tuning-table bytes are
printed as JSON.  This is observation-only; no IORegistry writes are possible.
"""
from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
from typing import Any

NODE_RE = re.compile(r"^(.*?)\+-o (?P<node>[^ ]+)")
PROP_RE = re.compile(r'^[^\"]*"(?P<key>[^\"]+)" = (?P<value>.*)$')
ATC_RE = re.compile(r"^atc-phy[0-5]@")
USB_RE = re.compile(r"^usb-drd[0-5]@")
HPM_RE = re.compile(r"^hpm[0-5]@")
SPMI_ANCESTOR_RE = re.compile(r"^nub-spmi-a[0-2]@")

COMMON_KEYS = {
    "name", "compatible", "device_type", "AAPL,phandle", "phandle", "reg",
    "interrupt-parent", "interrupts", "IOInterruptSpecifiers", "port-number",
    "port-type", "acio-parent", "dock", "spmi-parent", "iommu-parent",
    "atc-phy-parent", "atc-phy", "provider", "role", "transport-index",
    "transport-type", "spi-flash-parent",
}
HPM_KEYS = COMMON_KEYS | {"features-supported", "transports-supported", "rid"}
HOST_KEYS = {"target-sub-type", "compatible", "model", "OS Build Version", "IOKitBuildVersion"}


def chunks(value: str) -> list[str]:
    return re.findall(r"<([0-9a-fA-F]*)>", value)


def byte_payload(value: str) -> bytes | None:
    found = chunks(value)
    if not found:
        return None
    try:
        return b"".join(bytes.fromhex(part) for part in found)
    except ValueError:
        return None


def public_property(key: str, raw: str) -> dict[str, Any] | str | None:
    payload = byte_payload(raw)
    if payload is not None:
        return {
            "byte_length": len(payload),
            "hex": payload.hex(),
            "sha256": hashlib.sha256(payload).hexdigest(),
        }
    if raw.startswith('<"') or raw.startswith('"'):
        return raw.strip()
    return None


def parse_ioreg(text: str) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    stack: list[tuple[int, str]] = []
    records: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    for line in text.splitlines():
        node_match = NODE_RE.match(line)
        if node_match:
            indent = line.index("+-o")
            while stack and stack[-1][0] >= indent:
                stack.pop()
            node = node_match.group("node")
            stack.append((indent, node))
            target = (
                ATC_RE.match(node) or USB_RE.match(node) or HPM_RE.match(node)
                or SPMI_ANCESTOR_RE.match(node)
            )
            current = {"node": node, "path": [part for _, part in stack],
                       "properties": {}, "target": bool(target)}
            records.append(current)
            continue
        if current is None:
            continue
        property_match = PROP_RE.match(line)
        if property_match is None:
            continue
        key, raw = property_match.group("key"), property_match.group("value")
        if key in HOST_KEYS:
            current["properties"][key] = raw.strip()
        if key.startswith("tunable_") or key in {"tunable-device", "tunable-host"}:
            current["properties"][key] = public_property(key, raw)
        elif key in COMMON_KEYS or key in HPM_KEYS:
            value = public_property(key, raw)
            if value is not None:
                current["properties"][key] = value

    root_record = next((record for record in records if record["node"] == "Root"), None)
    root = {} if root_record is None else {
        key: value for key, value in root_record["properties"].items() if key in HOST_KEYS
    }
    device_tree = next((record for record in records if record["node"] == "device-tree"), None)
    if device_tree is not None and "compatible" in device_tree["properties"]:
        root["device-tree-compatible"] = device_tree["properties"]["compatible"]
    return records, root


def ref_tokens(value: dict[str, Any] | str | None) -> set[str]:
    if not isinstance(value, dict):
        return set()
    raw = value.get("hex")
    if not isinstance(raw, str):
        return set()
    return {raw[index:index + 8] for index in range(0, len(raw), 8)}


def little_u32(value: dict[str, Any] | str | None) -> int | None:
    if not isinstance(value, dict) or not isinstance(value.get("hex"), str):
        return None
    raw = bytes.fromhex(value["hex"])
    return int.from_bytes(raw[:4], "little") if len(raw) >= 4 else None


def first_string(value: str | None) -> str | None:
    if not isinstance(value, str):
        return None
    match = re.search(r'"([^"\\]+)"', value)
    return match.group(1) if match else None


def clean_record(record: dict[str, Any], *, hpm: bool = False,
                 include_tunables: bool = False) -> dict[str, Any]:
    props = {}
    for key, value in sorted(record["properties"].items()):
        if include_tunables and key.startswith("tunable_") and key not in {"tunable-device", "tunable-host"}:
            props[key] = value
        elif key in (HPM_KEYS if hpm else COMMON_KEYS):
            props[key] = value
    return {"node": record["node"], "path": record["path"], "properties": props}


def main() -> int:
    command = ["/usr/sbin/ioreg", "-p", "IODeviceTree", "-l", "-w0"]
    completed = subprocess.run(command, check=True, capture_output=True, text=True, encoding="utf-8")
    records, root = parse_ioreg(completed.stdout)
    hpm = [record for record in records if HPM_RE.match(record["node"])]
    atc = [record for record in records if ATC_RE.match(record["node"])]
    usb = [record for record in records if USB_RE.match(record["node"])]
    hpm_ancestor_names = {
        ancestor for record in hpm for ancestor in record["path"]
        if SPMI_ANCESTOR_RE.match(ancestor)
    }
    ancestors = [record for record in records if record["node"] in hpm_ancestor_names]

    hpm.sort(key=lambda record: record["node"])
    atc.sort(key=lambda record: record["node"])
    usb.sort(key=lambda record: record["node"])
    ancestors.sort(key=lambda record: record["node"])
    if len(hpm) != 6 or len(atc) != 6:
        raise SystemExit(f"expected six HPM and ATC nodes, got hpm={len(hpm)} atc={len(atc)}")
    expected_tunables = {
        key for key in atc[0]["properties"] if key.startswith("tunable_")
        and key not in {"tunable-device", "tunable-host"}
    }
    if len(expected_tunables) != 14:
        raise SystemExit(f"expected 14 named ATC tunables, got {len(expected_tunables)}")
    if any({key for key in record["properties"] if key.startswith("tunable_")
            and key not in {"tunable-device", "tunable-host"}} != expected_tunables
           for record in atc):
        raise SystemExit("ATC tunable name sets differ across ports")

    # Resolve only provider nodes actually named by retained HPM/USB/ATC links.
    references: set[str] = set()
    for record in hpm + atc + usb:
        for key, value in record["properties"].items():
            if key in {"AAPL,phandle", "phandle", "interrupt-parent", "acio-parent", "dock",
                       "spmi-parent", "iommu-parent", "atc-phy-parent", "atc-phy", "spi-flash-parent"}:
                references |= ref_tokens(value)
    provider_records = []
    for record in records:
        phandle = record["properties"].get("AAPL,phandle")
        if ref_tokens(phandle) & references:
            provider_records.append(clean_record(record))
    provider_records.sort(key=lambda record: record["node"])
    provider_by_phandle = {}
    for record in provider_records:
        phandle = record["properties"].get("AAPL,phandle")
        for token in ref_tokens(phandle):
            provider_by_phandle[token] = record["node"]
    atc_by_port = {
        little_u32(record["properties"].get("port-number")): record["node"]
        for record in atc
    }
    hpm_port_join = []
    for record in hpm:
        port_number = little_u32(record["properties"].get("port-number"))
        dock_ref = next(iter(ref_tokens(record["properties"].get("dock"))), None)
        hpm_port_join.append({
            "hpm": record["node"],
            "port_number": port_number,
            "dock_provider": provider_by_phandle.get(dock_ref),
            "atc_phy_same_port_number": atc_by_port.get(port_number),
            "direct_hpm_atc_reference": False,
        })

    output = {
        "schema": "j575d-usb-metadata-v1",
        "scope": "macOS read-only IODeviceTree observation; not iBoot or native boot evidence",
        "native_boot_approved": False,
        "collector": "collect-j575d-usb-metadata.py",
        "command": " ".join(command),
        "host_identity": {
            "target_type": first_string(root.get("target-sub-type"))
            or first_string(root.get("device-tree-compatible"))
            or first_string(root.get("compatible")),
            "model_or_compatible": root.get("device-tree-compatible", root.get("compatible")),
            "os_build": root.get("OS Build Version"),
            "kernel": root.get("IOKitBuildVersion"),
        },
        "validation": {
            "hpm_count": len(hpm), "atc_phy_count": len(atc),
            "named_atc_tunable_count": len(expected_tunables),
            "unfiltered_stream_retained": False,
        },
        "hpm": [clean_record(record, hpm=True) for record in hpm],
        "atc_phy": [clean_record(record, include_tunables=True) for record in atc],
        "usb_drd": [clean_record(record) for record in usb],
        "spmi_ancestors": [clean_record(record) for record in ancestors],
        "provider_links": provider_records,
        "hpm_port_join": hpm_port_join,
    }
    json.dump(output, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
