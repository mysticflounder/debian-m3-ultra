#!/usr/bin/env python3
"""Compile the offline Linux J575d PCIe + USB4+2 provider profile.

Uses the immutable nineteen-file Linux DT closure and captured macOS resource
metadata. No fetching, VM launch, hardware access, bootloader execution, or
installation. Passing establishes source packaging, not physical operation.
"""

from __future__ import annotations

import copy
import importlib.util
import json
import pathlib
import re
import shutil
import struct
import sys
import tempfile
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = pathlib.Path(__file__).resolve()
FRAGMENT = ROOT / "configs/j575d-usb-layout.dtsi"
ROUTING = ROOT / "docs/inventory/j575d-usb-routing-2026-10-08.json"
ROUTING_SHA = "4e68cedf0630efc01190538de6c110a5235bc242fb559a4cd62d1deabb30269d"
PCIE_SCRIPT = ROOT / "scripts/build-j575d-pcie-dt.py"
PCIE_SHA = "574e2cf4a5cac153180b4a137cc1d8c6fc1048f147cc51620abc8634338a8f63"
spec = importlib.util.spec_from_file_location("j575d_pcie_profile", PCIE_SCRIPT)
assert spec and spec.loader
PCIE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(PCIE)
BuildError = PCIE.BuildError
Tree = dict[str, dict[str, bytes]]
ADDED = ("dwc3_3", "dwc3_3_dart_0", "dwc3_3_dart_1", "atcphy3")
UNWITNESSED = ("dwc3_2_die1", "dwc3_2_dart_0_die1", "dwc3_2_dart_1_die1", "atcphy2_die1")
REFERENCE_COUNTS = {
    "clocks": "#clock-cells", "power-domains": "#power-domain-cells",
    "resets": "#reset-cells", "phys": "#phy-cells", "iommus": "#iommu-cells",
    "interrupts-extended": "#interrupt-cells", "msi-parent": "#msi-cells",
    "dmas": "#dma-cells", "mboxes": "#mbox-cells", "pwms": "#pwm-cells",
    "io-channels": "#io-channel-cells", "cooling-device": "#cooling-cells",
    "sound-dai": "#sound-dai-cells", "performance-domains": "#performance-domain-cells",
}
REFERENCE_SINGLE = {
    "interrupt-parent", "cpu", "operating-points-v2", "memory-region",
    "interrupt-affinity", "remote-endpoint", "nvmem-cells", "apple,sart",
    "next-level-cache", "apple,helper-cpu",
}
REFERENCE_SPECIAL = {"gpio-ranges", "iommu-map", "msi-ranges", "interrupt-map"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise BuildError(message)


def cells(value: bytes) -> tuple[int, ...]:
    require(len(value) % 4 == 0, "non-cell property in compiled artifact")
    return struct.unpack(f">{len(value) // 4}I", value)


def strings(value: bytes) -> tuple[str, ...]:
    require(value.endswith(b"\0"), "unterminated compiled string property")
    return tuple(part.decode("utf-8") for part in value[:-1].split(b"\0"))


def read_dtb(path: pathlib.Path) -> Tree:
    """Decode our dtc-produced artifact for whole-tree property comparison."""
    data = path.read_bytes()
    magic, total, offset, string_offset, _, _, _, _, string_size, size = struct.unpack_from(
        ">10I", data)
    require(magic == 0xD00DFEED and total == len(data), "unexpected compiled DTB header")
    names = data[string_offset:string_offset + string_size]
    cursor, limit = offset, offset + size
    result: Tree = {}
    stack: list[str] = []
    while cursor < limit:
        token = struct.unpack_from(">I", data, cursor)[0]
        cursor += 4
        if token == 1:
            end = data.index(b"\0", cursor, limit)
            name = data[cursor:end].decode("utf-8")
            parent = stack[-1] if stack else ""
            path_name = parent.rstrip("/") + "/" + name
            require(path_name not in result, f"duplicate compiled node {path_name}")
            result[path_name] = {}
            stack.append(path_name)
            cursor = (end + 4) & ~3
        elif token == 2:
            stack.pop()
        elif token == 3:
            length, name_offset = struct.unpack_from(">II", data, cursor)
            cursor += 8
            end = names.index(b"\0", name_offset)
            name = names[name_offset:end].decode("utf-8")
            result[stack[-1]][name] = data[cursor:cursor + length]
            cursor = (cursor + length + 3) & ~3
        elif token == 4:
            continue
        elif token == 9:
            require(not stack, "compiled DTB has unfinished nodes")
            return result
        else:
            raise BuildError(f"unexpected compiled DTB token {token}")
    raise BuildError("compiled DTB missing end token")


def symbol(tree: Tree, label: str) -> str:
    require(label in tree["/__symbols__"], f"missing symbol {label}")
    path = strings(tree["/__symbols__"][label])[0]
    require(path in tree, f"missing symbol target {label}")
    return path


def handles(tree: Tree) -> dict[int, str]:
    result: dict[int, str] = {}
    for path, props in tree.items():
        if "phandle" in props:
            value = cells(props["phandle"])
            require(len(value) == 1 and value[0] not in (0, 0xFFFFFFFF), f"invalid phandle {path}")
            require(value[0] not in result, f"duplicate phandle {path}")
            result[value[0]] = path
    return result


def reference_property(name: str) -> bool:
    return (name in REFERENCE_COUNTS or name in REFERENCE_SINGLE or name in REFERENCE_SPECIAL or
            bool(re.fullmatch(r"pinctrl-\d+", name)) or name.endswith("-gpios"))


def canonical_property(tree: Tree, path: str, name: str, mapping: dict[int, str]) -> Any:
    """Resolve closure reference cells so dtc phandle renumbering is harmless."""
    value = tree[path][name]
    if not reference_property(name):
        return value
    words, cursor, result = cells(value), 0, []
    if name == "iommu-map":
        require(len(words) % 4 == 0, f"short {path} iommu-map")
        for i in range(0, len(words), 4):
            require(words[i + 1] in mapping, f"unresolved {path} iommu-map")
            result.append((words[i], mapping[words[i + 1]], words[i + 2:i + 4]))
        return tuple(result)
    if name in ("msi-ranges", "interrupt-map"):
        child_count = 0
        if name == "interrupt-map":
            child_count = cells(tree[path]["#address-cells"])[0] + cells(tree[path]["#interrupt-cells"])[0]
        while cursor < len(words):
            provider_index = cursor + child_count
            require(provider_index < len(words) and words[provider_index] in mapping, f"unresolved {path} {name}")
            provider = mapping[words[provider_index]]
            parent_count = cells(tree[provider]["#interrupt-cells"])[0]
            if name == "interrupt-map":
                parent_count += cells(tree[provider].get("#address-cells", struct.pack(">I", 0)))[0]
            else:
                parent_count += 1  # Preserve the range count after the interrupt specifier.
            end = provider_index + 1 + parent_count
            require(end <= len(words), f"short {path} {name}")
            result.append((words[cursor:provider_index], provider, words[provider_index + 1:end]))
            cursor = end
        return tuple(result)
    while cursor < len(words):
        # The inherited disabled ADMAC nodes include empty interrupt slots.
        # A null phandle consumes one cell and has no provider arguments.
        if words[cursor] == 0:
            result.append((None, ()))
            cursor += 1
            continue
        require(words[cursor] in mapping, f"unresolved {path} {name}")
        provider = mapping[words[cursor]]
        if name in REFERENCE_SINGLE or re.fullmatch(r"pinctrl-\d+", name):
            count = 0
        elif name == "gpio-ranges":
            count = 3
        else:
            key = "#gpio-cells" if name.endswith("-gpios") else REFERENCE_COUNTS[name]
            if name == "msi-parent" and key not in tree[provider]:
                count = 0  # Pinned Apple PCIe provider uses the phandle-only form.
            else:
                require(key in tree[provider], f"missing provider cells {provider} {key}")
                count = cells(tree[provider][key])[0]
        require(cursor + 1 + count <= len(words), f"short {path} {name}")
        result.append((provider, words[cursor + 1:cursor + 1 + count]))
        cursor += 1 + count
    return tuple(result)


def translated_regs(tree: Tree, path: str) -> list[tuple[int, int]]:
    """Translate the direct two-cell SoC child resources through its ranges."""
    words = cells(tree[path]["reg"])
    require(len(words) % 4 == 0, f"unexpected reg shape {path}")
    parent = path.rsplit("/", 1)[0]
    require(cells(tree[parent]["#address-cells"]) == (2,) and
            cells(tree[parent]["#size-cells"]) == (2,), f"unexpected SoC cells {parent}")
    ranges = cells(tree[parent]["ranges"])
    require(len(ranges) % 6 == 0, f"unexpected SoC ranges {parent}")
    result = []
    for i in range(0, len(words), 4):
        address, size = (words[i] << 32) | words[i + 1], (words[i + 2] << 32) | words[i + 3]
        matches = []
        for j in range(0, len(ranges), 6):
            child = (ranges[j] << 32) | ranges[j + 1]
            physical = (ranges[j + 2] << 32) | ranges[j + 3]
            extent = (ranges[j + 4] << 32) | ranges[j + 5]
            if child <= address and address + size <= child + extent:
                matches.append((physical + address - child, size))
        require(len(matches) == 1, f"unmapped/ambiguous resource {path}")
        result.append(matches[0])
    return result


def validate_profile(tree: Tree, routing: dict[str, Any]) -> list[dict[str, Any]]:
    mapping = handles(tree)
    result = []
    for port in routing["ports"]:
        label, phy_label = port["linux_dwc3_label"], port["linux_phy_label"]
        die = port["linux_die_from_pinned_ranges"]
        suffix = "_die1" if die else ""
        local = int(label.removeprefix("dwc3_").removesuffix(suffix))
        path, phy = symbol(tree, label), symbol(tree, phy_label)
        parent = symbol(tree, f"die{die}")
        base = int(port["physical_dwc3_base"], 16)
        prefix = base - 0x02280000
        power = symbol(tree, f"ps_atc{local}_usb{suffix}")
        dart_labels = [f"dwc3_{local}_dart_{n}{suffix}" for n in range(2)]
        darts = [symbol(tree, name) for name in dart_labels]
        for name, node in [(label, path), (phy_label, phy), *zip(dart_labels, darts)]:
            require(node.rsplit("/", 1)[0] == parent, f"{name} parent die")
            require(tree[node].get("status", b"okay\0") == b"okay\0", f"{name} status")
            require(canonical_property(tree, node, "power-domains", mapping) == ((power, ()),),
                    f"{name} power-domains")
        require(strings(tree[path]["compatible"]) == ("apple,t6031-dwc3", "apple,t8103-dwc3"),
                f"{label} compatible")
        require(translated_regs(tree, path) == [(base, 0xCD00), (base + 0xCD00, 0x3200)], f"{label} reg")
        require(strings(tree[path]["reg-names"]) == ("dwc3-core", "dwc3-apple"), f"{label} reg-names")
        irq = port["raw_usb_irq_words"][0]
        require(irq >> 12 == die, f"{label} captured IRQ die")
        require(cells(tree[path]["interrupts"]) == (0, die, irq & 0xFFF, 4), f"{label} interrupts")
        require(canonical_property(tree, path, "interrupt-parent", mapping) == ((symbol(tree, "aic"), ()),),
                f"{label} interrupt-parent")
        require(canonical_property(tree, path, "iommus", mapping) == ((darts[0], (0,)), (darts[1], (1,))),
                f"{label} iommus")
        require(canonical_property(tree, path, "resets", mapping) == ((phy, ()),), f"{label} resets")
        require(canonical_property(tree, path, "phys", mapping) == ((phy, (3,)), (phy, (4,))), f"{label} phys")
        require(strings(tree[path]["phy-names"]) == ("usb2-phy", "usb3-phy"), f"{label} phy-names")
        for name, expected in (("dr_mode", b"otg\0"), ("role-switch-default-mode", b"host\0"),
                               ("usb-role-switch", b"")):
            require(tree[path].get(name) == expected, f"{label} {name}")
        for dart_label, dart, resource in zip(dart_labels, darts, port["physical_dart_ranges"]):
            require(strings(tree[dart]["compatible"]) == ("apple,t6031-dart", "apple,t8110-dart"),
                    f"{dart_label} compatible")
            require(translated_regs(tree, dart) == [(int(resource["base"], 16), int(resource["size"], 16))],
                    f"{dart_label} reg")
            dart_irq = port["raw_dart_irq_word"]
            require(dart_irq >> 12 == die, f"{dart_label} captured IRQ die")
            require(cells(tree[dart]["interrupts"]) == (0, die, dart_irq & 0xFFF, 4), f"{dart_label} interrupts")
            require(canonical_property(tree, dart, "interrupt-parent", mapping) ==
                    ((symbol(tree, "aic"), ()),), f"{dart_label} interrupt-parent")
            require(cells(tree[dart]["#iommu-cells"]) == (1,), f"{dart_label} iommu-cells")
        expected_phy = [(prefix + offset, size) for offset, size in
                        ((0x03000000, 0x4C000), (0x03050000, 0x8000), (0, 0x8000),
                         (0x02A90000, 0x4000), (0x02A84000, 0x4000))]
        require(translated_regs(tree, phy) == expected_phy, f"{phy_label} reg")
        require(expected_phy[3][0] == int(port["physical_atc_usb2phy_base"], 16), f"{phy_label} captured usb2phy")
        require(strings(tree[phy]["compatible"]) == ("apple,t6031-atcphy", "apple,t8122-atcphy"),
                f"{phy_label} compatible")
        require(strings(tree[phy]["reg-names"]) == ("core", "lpdptx", "axi2af", "usb2phy", "pipehandler"),
                f"{phy_label} reg-names")
        require(cells(tree[phy]["#phy-cells"]) == (1,) and cells(tree[phy]["#reset-cells"]) == (0,),
                f"{phy_label} provider cells")
        require(tree[phy].get("orientation-switch") == b"" and tree[phy].get("mode-switch") == b"",
                f"{phy_label} switches")
        result.append({"port_number": port["port_number"], "die": die, "dwc3": label,
                       "phy": phy_label, "darts": dart_labels, "physical_dwc3_base": hex(base),
                       "irq_tuple_source_derived": [0, die, irq & 0xFFF, 4],
                       "dart_irq_tuple_source_derived": [0, die, port["raw_dart_irq_word"] & 0xFFF, 4]})
    require([item["die"] for item in result] == [0, 0, 0, 0, 1, 1], "profile must contain USB4+2")
    for label in UNWITNESSED:
        path = symbol(tree, label)
        require(path.startswith(symbol(tree, "die1") + "/"), f"unwitnessed {label} parent")
        require(tree[path].get("status") == b"disabled\0", f"unwitnessed {label} status")
    for compatible, count in (("apple,t6031-dwc3", 6), ("apple,t6031-atcphy", 6)):
        active = [path for path, props in tree.items() if "compatible" in props and
                  compatible in strings(props["compatible"]) and props.get("status", b"okay\0") == b"okay\0"]
        require(len(active) == count, f"active {compatible} count")
    return result


def verify_delta(before: Tree, after: Tree) -> dict[str, int]:
    new_paths = {symbol(after, label) for label in ADDED}
    require(set(after) - set(before) == new_paths and not set(before) - set(after), "unexpected node additions/removals")
    expected = {(symbol(after, label), "status") for label in UNWITNESSED}
    expected |= {("/__symbols__", label) for label in ADDED}
    old_handles, new_handles = handles(before), handles(after)
    changes = set()
    renumbered = 0
    for path in before:
        for prop in set(before[path]) | set(after[path]):
            if prop == "phandle" and prop in before[path] and prop in after[path]:
                renumbered += before[path][prop] != after[path][prop]
                continue
            if prop not in before[path] or prop not in after[path] or canonical_property(
                    before, path, prop, old_handles) != canonical_property(after, path, prop, new_handles):
                changes.add((path, prop))
    require(changes == expected, f"unexpected existing-node changes: {sorted(changes ^ expected)}")
    return {"added_nodes": len(new_paths), "disabled_nodes": len(UNWITNESSED),
            "added_symbols": len(ADDED), "phandle_numbers_changed": renumbered}


def mutation_controls(before: Tree, after: Tree, routing: dict[str, Any]) -> list[dict[str, str]]:
    port = symbol(after, "dwc3_3")
    dart = symbol(after, "dwc3_3_dart_0")
    phantom = symbol(after, "dwc3_2_die1")
    changes = [
        ("wrong_port4_base", port, "reg", struct.pack(">4I", 0x14, 0x02280000, 0, 0xCD00) + after[port]["reg"][16:], "dwc3_3 reg"),
        ("wrong_dart_irq_858", dart, "interrupts", struct.pack(">4I", 0, 0, 858, 4), "dwc3_3_dart_0 interrupts"),
        ("wrong_dart_size", dart, "reg", struct.pack(">4I", 0x13, 0x02F00000, 0, 0x8000), "dwc3_3_dart_0 reg"),
        ("missing_second_iommu", port, "iommus", after[port]["iommus"][:8], "dwc3_3 iommus"),
        ("enabled_unwitnessed_die1", phantom, "status", b"okay\0", "unwitnessed dwc3_2_die1 status"),
        ("unrelated_root_change", "/", "model", b"wrong-board\0", "unexpected existing-node changes"),
    ]
    results = []
    for name, path, prop, value, expected in changes:
        mutant = copy.deepcopy(after)
        mutant[path][prop] = value
        try:
            validate_profile(mutant, routing)
            verify_delta(before, mutant)
        except BuildError as exc:
            require(expected in str(exc), f"{name} failed for wrong reason: {exc}")
            results.append({"name": name, "result": "rejected", "reason": str(exc)})
        else:
            raise BuildError(f"mutation {name} was accepted")
    return results


def load_routing() -> dict[str, Any]:
    require(PCIE.sha256(ROUTING) == ROUTING_SHA, "routing inventory hash mismatch")
    routing = json.loads(ROUTING.read_text(encoding="utf-8"))
    receipts = routing["receipts"] + routing["source_closure"]
    require(len(receipts) == 38, "unexpected routing receipt count")
    for entry in receipts:
        require(PCIE.sha256(ROOT / entry["path"]) == entry["sha256"], f"routing receipt changed: {entry['path']}")
    require(routing["physical_layout"]["die0_ports"] == 4 and routing["physical_layout"]["die1_ports"] == 2 and
            len(routing["ports"]) == 6, "unexpected routing layout")
    return routing


def main() -> int:
    require(not sys.argv[1:], "usage: build-j575d-usb-layout.py")
    require(PCIE.sha256(PCIE_SCRIPT) == PCIE_SHA, "independent PCIe builder changed")
    routing = load_routing()
    closure = PCIE.verify_closure(PCIE.load_manifest())
    dtc, fdtget = shutil.which("dtc"), shutil.which("fdtget")
    require(bool(dtc and fdtget and shutil.which("clang")), "clang, dtc and fdtget required")
    work = pathlib.Path(tempfile.mkdtemp(prefix="j575d-usb-layout.", dir=ROOT / "scratch"))
    board = PCIE.DT_ROOT / "t6032-j575d.dts"
    baseline = PCIE.compile_variant(work, "baseline", board, dtc)
    require(baseline["sha256"] == PCIE.EXPECTED_BASELINE, "baseline DTB hash mismatch")
    wrapper = work / "pcie-wrapper.dts"
    wrapper.write_text('#include "t6032-j575d.dts"\n#include "j575d-pcie-ports.dtsi"\n', encoding="utf-8")
    pcie = PCIE.compile_variant(work, "pcie", wrapper, dtc)
    old_dts = PCIE.decompile(work, "baseline", pathlib.Path(baseline["dtb"]), dtc)
    pcie_dts = PCIE.decompile(work, "pcie", pathlib.Path(pcie["dtb"]), dtc)
    pcie_changes = PCIE.verify_only_status_changes(work, old_dts, pcie_dts)
    pcie_labels = PCIE.label_paths(work, "pcie", pathlib.Path(pcie["dtb"]), fdtget)
    require(all(item["status"] == "okay" for item in pcie_labels.values()), "PCIe status regression")
    wrapper = work / "profile-wrapper.dts"
    wrapper.write_text('#include "t6032-j575d.dts"\n#include "j575d-pcie-ports.dtsi"\n'
                       '#include "j575d-usb-layout.dtsi"\n', encoding="utf-8")
    profile = PCIE.compile_variant(work, "profile", wrapper, dtc)
    PCIE.decompile(work, "profile", pathlib.Path(profile["dtb"]), dtc)
    before, after = read_dtb(pathlib.Path(pcie["dtb"])), read_dtb(pathlib.Path(profile["dtb"]))
    ports = validate_profile(after, routing)
    delta = verify_delta(before, after)
    controls = mutation_controls(before, after, routing)
    PCIE.verify_closure(PCIE.load_manifest())
    versions = {name: PCIE.tool_version(work, f"{name}-version", [executable, "--version"])
                for name, executable in (("clang", shutil.which("clang")), ("dtc", dtc), ("fdtget", fdtget))}
    manifest = {
        "schema_version": 1, "status": "offline_usb4plus2_provider_profile_pass", "workspace": str(work),
        "scope": "Linux source/profile packaging only; not physical operation or bootloader handoff",
        "source_closure": closure, "baseline": baseline, "pcie": pcie, "profile": profile,
        "input_hashes": {"builder": PCIE.sha256(SCRIPT), "fragment": PCIE.sha256(FRAGMENT),
                         "pcie_builder": PCIE_SHA, "pcie_fragment": PCIE.sha256(PCIE.FRAGMENT),
                         "routing_inventory": ROUTING_SHA, "source_manifest": PCIE.sha256(PCIE.SOURCE_MANIFEST)},
        "include_order": ["t6032-j575d.dts", "j575d-pcie-ports.dtsi", "j575d-usb-layout.dtsi"],
        "pcie_status_changes": pcie_changes, "pcie_labels": pcie_labels, "usb_delta": delta,
        "ports": ports, "mutation_controls": controls, "tools": versions,
        "routing_receipt_hashes_verified": 38, "source_files_unchanged": 19,
        "checks": {"six_active_dwc3_and_phy_providers": True, "twelve_active_usb_darts": True,
                   "four_unwitnessed_nodes_disabled": True, "only_intended_semantic_changes": True,
                   "native_or_physical_functionality_tested": False, "full_dtb_schema_validation": False,
                   "connector_graphs_added": False, "calibration_or_alias_handoff_added": False},
        "native_boot_approved": False, "default_dt_or_loader_changed": False,
    }
    (work / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"workspace={work}")
    print(f"PASS closure=19 routing_hashes=38 ports=4+2 darts=12 mutations={len(controls)}")
    print(f"baseline_sha256={baseline['sha256']} profile_sha256={profile['sha256']}")
    print(f"warnings baseline={baseline['warnings']} pcie={pcie['warnings']} profile={profile['warnings']}")
    print(f"manifest={work / 'manifest.json'}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BuildError as exc:
        print(f"j575d USB layout build: ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
