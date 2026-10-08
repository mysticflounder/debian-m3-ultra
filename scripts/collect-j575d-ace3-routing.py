#!/usr/bin/env python3
"""Read public J575d HPM/SPMI routing descriptors, without register access.

Full IORegistry archives stay in memory. Retain only named HPM providers under
the two witnessed banks, their direct Apple service children, explicit dock
references, SPMI controllers, and ancestor context. No configuration changes.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import pathlib
import plistlib
import re
import subprocess
import sys
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE_PATH = ROOT / "scripts/collect-j575d-spmi-routing.py"
BASE_SHA = "a434dd9e3cfc516227c42b998e7b1afef8204e7ded098adcaf39a7295f7ae599"
spec = importlib.util.spec_from_file_location("j575d_spmi_public_metadata", BASE_PATH)
assert spec and spec.loader
BASE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(BASE)
HPM_NAME = re.compile(r"^hpm[0-5](?:@.*)?$")
EXTRA_KEYS = frozenset({
    "#interrupt-cells", "interrupt-names", "dock", "spmi-parent", "hpm-parent",
    "hpm-class-type", "port-type", "rid", "features-supported", "transports-supported",
    "reset-gpios", "reset-gpio", "power-gpios", "power-gpio", "gpio-parent",
})


def hpm_name(node: dict[str, Any]) -> str | None:
    for key in ("IORegistryEntryName", "IOName", "IONameMatched"):
        value = node.get(key)
        if isinstance(value, str) and HPM_NAME.fullmatch(value):
            return value.split("@", 1)[0]
    return None


def bank_node(node: dict[str, Any]) -> bool:
    return any(isinstance(node.get(key), str) and BASE.BANK_NAME.fullmatch(node[key])
               for key in ("IORegistryEntryName", "IOName", "IONameMatched"))


def clean_node(node: dict[str, Any], path: tuple[str, ...], *, target: bool) -> dict[str, Any]:
    record = BASE.clean_node(node, path, target=target)
    for key in sorted(EXTRA_KEYS & node.keys()):
        value = BASE.public_value(node[key])
        if value is not None:
            record["properties"][key] = value
    return record


def filter_archive(archive: Any, plane: str) -> dict[str, Any]:
    if isinstance(archive, dict):
        archive = [archive]
    if not isinstance(archive, list) or any(not isinstance(root, dict) or
            not isinstance(root.get("IORegistryEntryName"), str) for root in archive):
        raise ValueError("IORegistry archive must contain named root dictionaries")
    nodes: list[tuple[dict[str, Any], tuple[dict[str, Any], ...]]] = []
    selected: dict[tuple[str, ...], tuple[dict[str, Any], bool]] = {}
    targets = 0

    def visit(node: dict[str, Any], ancestors: tuple[dict[str, Any], ...]) -> None:
        nodes.append((node, ancestors))
        children = node.get("IORegistryEntryChildren", [])
        if not isinstance(children, list) or any(not isinstance(child, dict) for child in children):
            raise ValueError("IORegistry children must be dictionaries")
        for child in children:
            visit(child, (*ancestors, node))

    def select(node: dict[str, Any], ancestors: tuple[dict[str, Any], ...]) -> None:
        nonlocal targets
        chain = (*ancestors, node)
        targets += 1
        for index, ancestor in enumerate(chain):
            path = tuple(BASE.node_name(item) for item in chain[:index + 1])
            prior = selected.get(path)
            target = index == len(chain) - 1 or (prior is not None and prior[1])
            selected[path] = (ancestor, target)

    for root in archive:
        visit(root, ())
    docks: set[bytes] = set()
    for node, ancestors in nodes:
        under_bank = any(bank_node(ancestor) for ancestor in ancestors)
        hpm = under_bank and hpm_name(node) is not None
        # Observe real registered service children; do not invent ACE3 classes
        # or descend into downstream devices with user-supplied registry names.
        direct_service = (plane == "IOService" and under_bank and bool(ancestors) and
                          hpm_name(ancestors[-1]) is not None and
                          BASE.node_name(node).startswith("Apple") and any(
                              isinstance(node.get(key), str) and node[key].startswith("Apple")
                              for key in ("IOClass", "IOObjectClass")))
        if BASE.is_target(node, plane, ancestors) or hpm or direct_service:
            select(node, ancestors)
        if hpm:
            dock = node.get("dock")
            if isinstance(dock, bytes) and len(dock) == 4:
                docks.add(dock)
    for node, ancestors in nodes:
        phandle = node.get("AAPL,phandle")
        if isinstance(phandle, bytes) and len(phandle) == 4 and phandle in docks:
            select(node, ancestors)
    return {"target_count": targets,
            "records": [clean_node(node, path, target=target)
                        for path, (node, target) in sorted(selected.items())]}


def main() -> int:
    if sys.argv[1:]:
        raise SystemExit("usage: collect-j575d-ace3-routing.py")
    if hashlib.sha256(BASE_PATH.read_bytes()).hexdigest() != BASE_SHA:
        raise SystemExit("frozen public SPMI collector dependency changed")
    planes = {}
    for plane in ("IODeviceTree", "IOService"):
        command = ["/usr/sbin/ioreg", "-p", plane, "-a", "-l", "-w0"]
        run = subprocess.run(command, check=True, capture_output=True)
        planes[plane] = {"command": command,
                         **filter_archive(plistlib.loads(run.stdout), plane)}
    observed = {record["node"].split("@", 1)[0]
                for record in planes["IODeviceTree"]["records"]
                if record["target"] and HPM_NAME.fullmatch(record["node"])}
    if observed != {f"hpm{index}" for index in range(6)}:
        raise SystemExit("expected six named J575d HPM providers below a0/a2")
    json.dump({"schema": "j575d-ace3-routing-observation-v1",
               "scope": "read-only public macOS registry descriptors, not native operation",
               "native_boot_approved": False, "mmio_register_access": False,
               "unfiltered_archives_retained": False, "planes": planes},
              sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
