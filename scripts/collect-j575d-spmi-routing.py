#!/usr/bin/env python3
"""Observe public SPMI and optional USB provider metadata; never access registers.

IORegistry archives are consumed in memory. Only the two named firmware banks,
matching SPMI services and their ancestors are retained, with allow-listed
properties. --usb-providers also retains the twelve named USB/ATCPHY providers
and DART providers explicitly referenced by their iommu-parent properties.
Physical resource descriptors are metadata, not register reads.
No firmware, IORegistry, disk, VM or boot configuration is changed.
"""
from __future__ import annotations

import hashlib
import json
import plistlib
import re
import subprocess
import sys
from typing import Any


BANK_NAME = re.compile(r"^nub-spmi-a[02](?:@.*)?$")
USB_PROVIDER_NAME = re.compile(r"^(?:atc-phy|usb-drd)[0-5](?:@.*)?$")
PUBLIC_KEYS = frozenset({
    "name", "compatible", "device_type", "reg", "ranges", "AAPL,phandle",
    "phandle", "#address-cells", "#size-cells", "interrupt-parent", "interrupts",
    "IOInterruptControllers", "IOInterruptSpecifiers", "IODeviceMemory",
    "IOProviderClass", "IOClass", "IOObjectClass", "IOName", "IONameMatched",
    "power-domains", "power-domain", "pmgr-parent", "pmgr-device-id", "ps-reg",
    "clock-gates", "clocks", "die", "die-id", "die-index", "die-number",
    "die-count", "AAPL,address", "AAPL,addresses",
    "port-number", "iommu-parent", "atc-phy-parent", "#iommu-cells",
})
POWER_STATE_KEYS = frozenset({
    "CurrentPowerState", "DevicePowerState", "MaxPowerState", "CapabilityFlags",
})
RESOURCE_KEYS = frozenset({"address", "length", "size", "start", "end"})


def public_value(value: Any, *, map_keys: frozenset[str] = frozenset()) -> Any:
    if isinstance(value, bytes):
        return {"hex": value.hex(), "byte_length": len(value),
                "sha256": hashlib.sha256(value).hexdigest()}
    if isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, list):
        result = [public_value(item, map_keys=map_keys) for item in value]
        return [item for item in result if item is not None]
    if isinstance(value, dict) and map_keys:
        return {key: item for key in sorted(map_keys & value.keys())
                if (item := public_value(value[key])) is not None}
    return None


def node_name(node: dict[str, Any]) -> str:
    name = node.get("IORegistryEntryName")
    return name if isinstance(name, str) else "<unnamed>"


def is_target(node: dict[str, Any], plane: str,
              ancestors: tuple[dict[str, Any], ...] = (), *, include_usb: bool = False) -> bool:
    if BANK_NAME.fullmatch(node_name(node)):
        return True
    if include_usb and USB_PROVIDER_NAME.fullmatch(node_name(node)):
        return True
    if plane != "IOService":
        return False
    for key in ("IOName", "IONameMatched"):
        value = node.get(key)
        if isinstance(value, str) and BANK_NAME.fullmatch(value):
            return True
    # Controller service names need not contain the firmware bank name.
    return any(BANK_NAME.fullmatch(node_name(ancestor)) for ancestor in ancestors) and any(
        isinstance(node.get(key), str) and node[key].startswith("AppleSPMIController")
        for key in ("IOObjectClass", "IOClass", "IORegistryEntryName"))


def clean_node(node: dict[str, Any], path: tuple[str, ...], *, target: bool) -> dict[str, Any]:
    properties = {}
    for key in sorted(PUBLIC_KEYS & node.keys()):
        value = public_value(node[key], map_keys=RESOURCE_KEYS if key == "IODeviceMemory"
                             else frozenset())
        if value is not None:
            properties[key] = value
    power = node.get("IOPowerManagement")
    if isinstance(power, dict):
        properties["IOPowerManagement"] = public_value(power, map_keys=POWER_STATE_KEYS)
    result = {"node": node_name(node), "path": list(path), "target": target,
              "properties": properties}
    if target:
        # Names only let a later review identify missing public routing fields.
        # No values outside PUBLIC_KEYS are retained.
        result["available_property_names"] = sorted(
            key for key in node if key not in {"IORegistryEntryChildren", "IORegistryEntryID"})
    return result


def filter_archive(archive: Any, plane: str, *, include_usb: bool = False) -> dict[str, Any]:
    # Modern ioreg archives a single root as a dictionary, while fixtures and
    # older archive producers may wrap roots in a list.
    if isinstance(archive, dict):
        archive = [archive]
    if not isinstance(archive, list) or any(
            not isinstance(root, dict) or not isinstance(root.get("IORegistryEntryName"), str)
            for root in archive):
        raise ValueError("IORegistry archive must contain named root dictionaries")
    selected: dict[tuple[str, ...], tuple[dict[str, Any], bool]] = {}
    nodes: list[tuple[dict[str, Any], tuple[dict[str, Any], ...]]] = []
    targets = 0

    def select(node: dict[str, Any], ancestors: tuple[dict[str, Any], ...]) -> None:
        nonlocal targets
        chain = (*ancestors, node)
        targets += 1
        for index, ancestor in enumerate(chain):
            path = tuple(node_name(item) for item in chain[:index + 1])
            prior = selected.get(path)
            target = index == len(chain) - 1 or (prior is not None and prior[1])
            selected[path] = (ancestor, target)

    def visit(node: dict[str, Any], ancestors: tuple[dict[str, Any], ...]) -> None:
        nodes.append((node, ancestors))
        chain = (*ancestors, node)
        children = node.get("IORegistryEntryChildren", [])
        if not isinstance(children, list) or any(not isinstance(child, dict) for child in children):
            raise ValueError("IORegistry children must be dictionaries")
        for child in children:
            visit(child, chain)

    for root in archive:
        visit(root, ())
    references: set[bytes] = set()
    for node, ancestors in nodes:
        if is_target(node, plane, ancestors, include_usb=include_usb):
            select(node, ancestors)
        if include_usb and USB_PROVIDER_NAME.fullmatch(node_name(node)):
            value = node.get("iommu-parent")
            if isinstance(value, bytes) and len(value) % 4 == 0:
                references.update(value[index:index + 4] for index in range(0, len(value), 4))
    if include_usb:
        for node, ancestors in nodes:
            phandle = node.get("AAPL,phandle")
            dart_provider = node_name(node).startswith("dart-") or (
                node_name(node).startswith("mapper-usb") and
                any(node_name(ancestor).startswith("dart-") for ancestor in ancestors))
            if (dart_provider and isinstance(phandle, bytes)
                    and len(phandle) == 4 and phandle in references):
                select(node, ancestors)
    return {"target_count": targets,
            "records": [clean_node(node, path, target=target)
                        for path, (node, target) in sorted(selected.items())]}


def main() -> int:
    if sys.argv[1:] not in ([], ["--usb-providers"]):
        raise SystemExit("usage: collect-j575d-spmi-routing.py [--usb-providers]")
    include_usb = bool(sys.argv[1:])
    planes = {}
    for plane in ("IODeviceTree", "IOService"):
        command = ["/usr/sbin/ioreg", "-p", plane, "-a", "-l", "-w0"]
        result = subprocess.run(command, check=True, capture_output=True)
        planes[plane] = {"command": command,
                         **filter_archive(plistlib.loads(result.stdout), plane,
                                          include_usb=include_usb)}
    banks = {record["node"].split("@", 1)[0]
             for record in planes["IODeviceTree"]["records"]
             if record["target"] and BANK_NAME.fullmatch(record["node"])}
    if banks != {"nub-spmi-a0", "nub-spmi-a2"}:
        raise SystemExit(f"expected J575d a0/a2 banks, observed {sorted(banks)}")
    if include_usb:
        providers = {record["node"].split("@", 1)[0]
                     for record in planes["IODeviceTree"]["records"]
                     if record["target"] and USB_PROVIDER_NAME.fullmatch(record["node"])}
        expected = {f"{kind}{index}" for kind in ("atc-phy", "usb-drd") for index in range(6)}
        if providers != expected:
            raise SystemExit("expected six USB and six ATCPHY firmware providers")
    output = {"schema": "j575d-spmi-routing-observation-v1",
              "scope": "read-only macOS registry observation; not Linux/native qualification",
              "native_boot_approved": False, "unfiltered_archives_retained": False,
              "mmio_register_access": False, "usb_providers_included": include_usb,
              "planes": planes}
    json.dump(output, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
