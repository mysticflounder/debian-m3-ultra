#!/usr/bin/env python3
"""Build and audit the disabled J575d ACE3/SPMI candidate overlay.

This is an offline source/DT graph check.  It compiles the pinned board with
the already-verified PCIe and USB provider overlays, appends the disabled ACE3
candidate, and compares the two compiled trees semantically.  It does not
enable an ACE3 child or claim native, PMGR, IRQ, calibration, or Type-C
functionality.
"""

from __future__ import annotations

import copy
import importlib.util
import json
import pathlib
import shutil
import struct
import sys
import tempfile
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = pathlib.Path(__file__).resolve()
USB_SCRIPT = ROOT / "scripts/build-j575d-usb-layout.py"
USB_SHA = "5617d5bf3ddf7c0c0fce7e8aa2a17a0a8dd264c4bc73b3f258b624c26efcbc2d"
USB_FRAGMENT = ROOT / "configs/j575d-usb-layout.dtsi"
CANDIDATE_FRAGMENT = ROOT / "configs/j575d-ace3-candidate.dtsi"
ROUTING = ROOT / "docs/inventory/j575d-usb-routing-2026-10-08.json"
ROUTING_SHA = "4e68cedf0630efc01190538de6c110a5235bc242fb559a4cd62d1deabb30269d"
FRESH_CAPTURE = ROOT / "scratch/j575d-ace3-routing-first-2026-10-08.json"
FRESH_CAPTURE_SHA = "9b44d4817457c943d2ec09e3b659fe9bf9cf8ad021e9cd74bdf3d29bbfe4155f"
EXPECTED_BASELINE = "af9ba709814b2a1f1be5c9e3a8529a78df2851eb3b6ce8c306949766d501b867"

spec = importlib.util.spec_from_file_location("j575d_usb_layout", USB_SCRIPT)
assert spec and spec.loader
USB = importlib.util.module_from_spec(spec)
spec.loader.exec_module(USB)
PCIE = USB.PCIE
BuildError = USB.BuildError
Tree = USB.Tree


ACE_ROWS = (
    (0, "nub_spmi_a0", "0xc", "dwc3_0", "atcphy0", (11, 13, 17, 19)),
    (1, "nub_spmi_a0", "0xa", "dwc3_1", "atcphy1", (37, 39, 43, 45)),
    (2, "nub_spmi_a0", "0x8", "dwc3_2", "atcphy2", (63, 65, 69, 71)),
    (3, "nub_spmi_a0", "0x6", "dwc3_3", "atcphy3", (89, 91, 95, 97)),
    (4, "nub_spmi_a2", "0xc", "dwc3_0_die1", "atcphy0_die1", (11, 13, 17, 19)),
    (5, "nub_spmi_a2", "0xa", "dwc3_1_die1", "atcphy1_die1", (37, 39, 43, 45)),
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise BuildError(message)


def cells(value: bytes) -> tuple[int, ...]:
    require(len(value) % 4 == 0, "non-cell property")
    return struct.unpack(f">{len(value) // 4}I", value)


def strings(value: bytes) -> tuple[str, ...]:
    require(value.endswith(b"\0"), "unterminated string property")
    return tuple(part.decode("utf-8") for part in value[:-1].split(b"\0"))


def sym(tree: Tree, label: str) -> str:
    return USB.symbol(tree, label)


def canonical(tree: Tree, path: str, name: str, mapping: dict[int, str]) -> Any:
    require(path in tree and name in tree[path], f"missing {path} {name}")
    return USB.canonical_property(tree, path, name, mapping)


def graph_labels(row: tuple[int, str, str, str, str, tuple[int, ...]]) -> tuple[str, ...]:
    index, _, _, dwc, phy, _ = row
    return (f"hpm{index}", f"typec{index}", f"typec{index}_hs", f"typec{index}_ss",
            f"{dwc}_hs", f"{dwc}_ss", f"{phy}_typec_lanes", f"{phy}_usb3")


def candidate_symbols() -> set[str]:
    result = {"nub_spmi_a2"}
    for row in ACE_ROWS:
        result.update(graph_labels(row))
    return result


def port_path(base: str, number: int) -> str:
    return f"{base}/ports/port@{number}"


def endpoint_path(base: str, number: int) -> str:
    return f"{port_path(base, number)}/endpoint"


def endpoint_remote(tree: Tree, endpoint: str, mapping: dict[int, str]) -> str:
    value = canonical(tree, endpoint, "remote-endpoint", mapping)
    require(len(value) == 1 and value[0][1] == (), f"bad remote-endpoint {endpoint}")
    return value[0][0]


def require_ports_block(tree: Tree, owner: str) -> None:
    ports = f"{owner}/ports"
    require(ports in tree, f"missing ports block {owner}")
    require(cells(tree[ports]["#address-cells"]) == (1,) and
            cells(tree[ports]["#size-cells"]) == (0,), f"bad ports cells {owner}")
    for number in (0, 1):
        path = port_path(owner, number)
        require(path in tree and cells(tree[path]["reg"]) == (number,),
                f"{owner} port@{number} reg")


def expected_symbol_paths(before: Tree) -> dict[str, str]:
    """Fixed candidate paths; never derive the allowlist from candidate symbols."""
    a0 = sym(before, "nub_spmi_a0")
    a2 = f"{sym(before, 'die0')}/spmi@2a11a8000"
    result: dict[str, str] = {"nub_spmi_a2": a2}
    for index, bank_label, sid_text, dwc, phy, _ in ACE_ROWS:
        bank = a0 if bank_label == "nub_spmi_a0" else a2
        hpm = f"{bank}/usb-pd@{sid_text[2:]}"
        connector = f"{hpm}/connector"
        result.update({f"hpm{index}": hpm, f"typec{index}": connector,
                       f"typec{index}_hs": endpoint_path(f"{connector}", 0),
                       f"typec{index}_ss": endpoint_path(f"{connector}", 1)})
        dwc_path, phy_path = sym(before, dwc), sym(before, phy)
        result.update({f"{dwc}_hs": endpoint_path(dwc_path, 0),
                       f"{dwc}_ss": endpoint_path(dwc_path, 1),
                       f"{phy}_typec_lanes": endpoint_path(phy_path, 0),
                       f"{phy}_usb3": endpoint_path(phy_path, 1)})
    return result


def validate_fresh_capture() -> dict[str, Any]:
    require(USB.PCIE.sha256(FRESH_CAPTURE) == FRESH_CAPTURE_SHA, "fresh ACE3 capture hash mismatch")
    data = json.loads(FRESH_CAPTURE.read_text(encoding="utf-8"))
    require(data.get("schema") == "j575d-ace3-routing-observation-v1", "unexpected ACE3 capture schema")
    rows = []
    for plane in ("IODeviceTree", "IOService"):
        records = data["planes"][plane]["records"]
        hpm = [r for r in records if r.get("target") and r["node"].startswith("hpm")]
        require(len(hpm) == 6, f"fresh {plane} HPM count")
        rows.append((plane, len(hpm)))
    services = [r for r in data["planes"]["IOService"]["records"]
                if r.get("target") and r["node"] == "AppleHPMARMSPMI"]
    require(len(services) == 6, "fresh AppleHPMARMSPMI count")
    return {"sha256": FRESH_CAPTURE_SHA, "hpm_targets": rows,
            "apple_hpm_arm_spmi_services": len(services)}


def validate_candidate(tree: Tree, routing: dict[str, Any]) -> dict[str, Any]:
    """Validate the disabled ACE3 bank, six children, and 18 reciprocal links."""
    provider_ports = USB.validate_profile(tree, routing)
    mapping = USB.handles(tree)
    die0 = sym(tree, "die0")
    aic = sym(tree, "aic")
    a2 = sym(tree, "nub_spmi_a2")
    require(a2.rsplit("/", 1)[0] == die0, "a2 bank must be die0 child")
    require(USB.translated_regs(tree, a2) == [(0x2A11A8000, 0x100)], "a2 bank resource")
    require(strings(tree[a2]["compatible"]) == ("apple,t6031-spmi", "apple,t8103-spmi"), "a2 compatible")
    require(cells(tree[a2]["#address-cells"]) == (2,) and cells(tree[a2]["#size-cells"]) == (0,), "a2 cells")
    require(cells(tree[a2]["#interrupt-cells"]) == (2,) and tree[a2].get("interrupt-controller") == b"", "a2 IRQ controller")
    require(canonical(tree, a2, "interrupt-parent", mapping) == ((aic, ()),), "a2 interrupt-parent")
    require(cells(tree[a2]["interrupts"]) == (0, 0, 767, 4), "a2 IRQ 767/high")
    require(canonical(tree, a2, "power-domains", mapping) == ((sym(tree, "ps_nub_spmi_a2"), ()),), "a2 PMGR source join")
    require(tree[a2].get("status") == b"disabled\0", "a2 bank must be disabled")

    graph_count = 0
    endpoint_count = 0
    for index, bank_label, sid_text, dwc, phy, irq_values in ACE_ROWS:
        hpm = sym(tree, f"hpm{index}")
        bank = sym(tree, bank_label)
        require(hpm == f"{bank}/usb-pd@{sid_text[2:]}", f"hpm{index} exact bank/SID path")
        require(strings(tree[hpm]["compatible"]) == ("apple,sn201202x",), f"hpm{index} compatible")
        sid = int(sid_text, 16)
        require(cells(tree[hpm]["reg"]) == (sid, 0), f"hpm{index} SID")
        require(cells(tree[hpm]["interrupts"]) == sum(((irq, 1) for irq in irq_values), ()), f"hpm{index} IRQs")
        require(strings(tree[hpm]["interrupt-names"]) == ("irq", "select", "sleep", "wake"), f"hpm{index} IRQ names")
        require(tree[hpm].get("status") == b"disabled\0", f"hpm{index} ACE child disabled")
        connector = sym(tree, f"typec{index}")
        require(connector == f"{hpm}/connector", f"typec{index} exact connector owner")
        require(strings(tree[connector]["compatible"]) == ("usb-c-connector",), f"typec{index} connector")
        require(strings(tree[connector]["power-role"]) == ("dual",) and strings(tree[connector]["data-role"]) == ("dual",), f"typec{index} roles")
        require_ports_block(tree, connector)
        dwc_path, phy_path = sym(tree, dwc), sym(tree, phy)
        require_ports_block(tree, dwc_path)
        require_ports_block(tree, phy_path)
        pairs = ((f"typec{index}_hs", f"{dwc}_hs", 0, 0),
                 (f"typec{index}_ss", f"{phy}_typec_lanes", 1, 0),
                 (f"{dwc}_ss", f"{phy}_usb3", 1, 1))
        for left, right, left_port, right_port in pairs:
            left_ep, right_ep = sym(tree, left), sym(tree, right)
            left_owner = connector if left.startswith("typec") else (dwc_path if left.startswith("dwc") else phy_path)
            right_owner = connector if right.startswith("typec") else (dwc_path if right.startswith("dwc") else phy_path)
            require(left_ep == endpoint_path(left_owner, left_port), f"{left} exact endpoint owner")
            require(right_ep == endpoint_path(right_owner, right_port), f"{right} exact endpoint owner")
            require(endpoint_remote(tree, left_ep, mapping) == right_ep, f"{left} reciprocal")
            require(endpoint_remote(tree, right_ep, mapping) == left_ep, f"{right} reciprocal")
            graph_count += 1
            endpoint_count += 2
    require(graph_count == 18 and endpoint_count == 36, "expected 18 graph links/36 endpoints")
    return {"ports": provider_ports, "a2_resource": "0x2a11a8000/0x100", "a2_irq": [0, 767, 4],
            "ace_children": 6, "graph_links": graph_count, "graph_endpoints": endpoint_count,
            "all_ace_disabled": True, "select_witness": False}


def expected_added_paths(before: Tree, after: Tree) -> set[str]:
    result: set[str] = set()
    for path in expected_symbol_paths(before).values():
        while path and path not in before:
            result.add(path)
            path = path.rsplit("/", 1)[0] or "/"
    return result


def verify_delta(before: Tree, after: Tree) -> dict[str, int]:
    """Reject all pre-existing semantic changes except phandle renumbering."""
    require(not set(before) - set(after), "pre-existing nodes removed")
    added = set(after) - set(before)
    require(added == expected_added_paths(before, after), "unexpected candidate nodes")
    symbols_before = set(before["/__symbols__"])
    symbols_after = set(after["/__symbols__"])
    require(symbols_after - symbols_before == candidate_symbols(), "unexpected candidate symbols")
    require(symbols_before <= symbols_after, "pre-existing symbols removed")
    for label in symbols_before:
        require(before["/__symbols__"][label] == after["/__symbols__"][label], f"symbol changed {label}")
    expected_symbols = expected_symbol_paths(before)
    for label, expected in expected_symbols.items():
        require(sym(after, label) == expected, f"candidate symbol relocated {label}")
    old_handles, new_handles = USB.handles(before), USB.handles(after)
    semantic_changes: set[tuple[str, str]] = set()
    phandle_changes = 0
    for path in before:
        if path == "/__symbols__":
            continue
        for prop in set(before[path]) | set(after[path]):
            if prop == "phandle" and prop in before[path] and prop in after[path]:
                phandle_changes += before[path][prop] != after[path][prop]
                continue
            if prop not in before[path] or prop not in after[path]:
                semantic_changes.add((path, prop))
                continue
            try:
                old, new = USB.canonical_property(before, path, prop, old_handles), USB.canonical_property(after, path, prop, new_handles)
            except (BuildError, KeyError, IndexError, struct.error):
                semantic_changes.add((path, prop))
                continue
            if old != new:
                semantic_changes.add((path, prop))
    require(not semantic_changes, f"unexpected existing-node changes: {sorted(semantic_changes)}")
    return {"added_nodes": len(added), "added_symbols": len(candidate_symbols()),
            "phandle_numbers_changed": phandle_changes}


def mutation_controls(before: Tree, after: Tree, routing: dict[str, Any]) -> list[dict[str, str]]:
    """Exercise scoped negative controls with an explicit reason for each."""
    a2 = sym(after, "nub_spmi_a2")
    hpm0 = sym(after, "hpm0")
    typec0_hs = sym(after, "typec0_hs")
    typec1_hs = sym(after, "typec1_hs")
    controls = [
        ("wrongbank", a2, "reg", struct.pack(">4I", 0x2, 0xA1188000, 0, 0x100), "a2 bank resource"),
        ("selectchanged", hpm0, "interrupts", struct.pack(">8I", 11, 1, 14, 1, 17, 1, 19, 1), "hpm0 IRQs"),
        ("graphnonreciprocal", typec0_hs, "remote-endpoint", after[typec1_hs]["phandle"], "typec0_hs reciprocal"),
        ("swappedport", sym(after, "typec0") + "/ports/port@0", "reg", struct.pack(">I", 1), "port@0 reg"),
        ("rightportreg", sym(after, "typec0") + "/ports/port@1", "reg", struct.pack(">I", 0), "port@1 reg"),
        ("relocatedendpoint", "/__symbols__", "typec0_hs", after["/__symbols__"]["typec1_hs"], "typec0_hs exact endpoint owner"),
        ("accidentally_enabledACE", hpm0, "status", b"okay\0", "hpm0 ACE child disabled"),
        ("unrelatedbaseproperty", "/", "model", b"wrong-board\0", "unexpected existing-node changes"),
    ]
    results = []
    for name, path, prop, value, reason in controls:
        mutant = copy.deepcopy(after)
        mutant[path][prop] = value
        try:
            validate_candidate(mutant, routing)
            verify_delta(before, mutant)
        except BuildError as exc:
            require(reason in str(exc), f"{name} rejected for wrong reason: {exc}")
            results.append({"name": name, "result": "rejected", "reason": reason})
        else:
            raise BuildError(f"mutation {name} was accepted")
    return results


def load_routing() -> dict[str, Any]:
    require(USB.PCIE.sha256(ROUTING) == ROUTING_SHA, "routing inventory hash mismatch")
    routing = USB.load_routing()
    require(len(routing["receipts"] + routing["source_closure"]) == 38, "routing receipt count")
    return routing


def main() -> int:
    require(not sys.argv[1:], "usage: build-j575d-ace3-candidate.py")
    require(USB.PCIE.sha256(USB_SCRIPT) == USB_SHA, "frozen USB builder changed")
    require(PCIE.sha256(USB.PCIE_SCRIPT) == USB.PCIE_SHA, "frozen PCIe builder changed")
    require(CANDIDATE_FRAGMENT.is_file(), "ACE3 candidate fragment missing")
    routing = load_routing()
    fresh = validate_fresh_capture()
    closure = PCIE.verify_closure(PCIE.load_manifest())
    require(closure["count"] == 19, "board closure count")
    clang, dtc, fdtget = shutil.which("clang"), shutil.which("dtc"), shutil.which("fdtget")
    dtc = dtc or ("/opt/homebrew/bin/dtc" if pathlib.Path("/opt/homebrew/bin/dtc").is_file() else None)
    fdtget = fdtget or ("/opt/homebrew/bin/fdtget" if pathlib.Path("/opt/homebrew/bin/fdtget").is_file() else None)
    require(bool(clang and dtc and fdtget), "clang, dtc, and fdtget required")
    work = pathlib.Path(tempfile.mkdtemp(prefix="j575d-ace3-candidate.", dir=ROOT / "scratch"))
    board = PCIE.DT_ROOT / "t6032-j575d.dts"
    baseline_wrapper = work / "baseline-wrapper.dts"
    baseline_wrapper.write_text('#include "t6032-j575d.dts"\n#include "j575d-pcie-ports.dtsi"\n#include "j575d-usb-layout.dtsi"\n', encoding="utf-8")
    baseline = PCIE.compile_variant(work, "baseline", baseline_wrapper, dtc)
    require(baseline["sha256"] == EXPECTED_BASELINE, "pinned PCIe+USB baseline hash")
    candidate_wrapper = work / "candidate-wrapper.dts"
    candidate_wrapper.write_text(baseline_wrapper.read_text(encoding="utf-8") + '#include "j575d-ace3-candidate.dtsi"\n', encoding="utf-8")
    candidate = PCIE.compile_variant(work, "candidate", candidate_wrapper, dtc)
    before_dts = PCIE.decompile(work, "baseline", pathlib.Path(baseline["dtb"]), dtc)
    after_dts = PCIE.decompile(work, "candidate", pathlib.Path(candidate["dtb"]), dtc)
    before, after = USB.read_dtb(pathlib.Path(baseline["dtb"])), USB.read_dtb(pathlib.Path(candidate["dtb"]))
    summary = validate_candidate(after, routing)
    delta = verify_delta(before, after)
    controls = mutation_controls(before, after, routing)
    tools = {name: PCIE.tool_version(work, f"{name}-version", [exe, "--version"])
             for name, exe in (("clang", clang), ("dtc", dtc), ("fdtget", fdtget))}
    manifest = {
        "schema_version": 1, "status": "offline_disabled_ace3_candidate_pass",
        "scope": "offline DT source/graph packaging only; no native or physical qualification",
        "workspace": str(work), "source_closure": closure, "fresh_capture": fresh,
        "baseline": baseline, "candidate": candidate, "before_decompiled": str(before_dts),
        "candidate_decompiled": str(after_dts), "delta": delta, "candidate_summary": summary,
        "ports": summary["ports"],
        "tree_counts": {"baseline_nodes": len(before), "candidate_nodes": len(after),
                        "added_nodes": len(after) - len(before)},
        "mutation_controls": controls, "tools": tools,
        "input_hashes": {"builder": PCIE.sha256(SCRIPT), "frozen_usb_builder": USB_SHA,
                         "frozen_pcie_builder": USB.PCIE_SHA,
                         "board": PCIE.sha256(board), "usb_fragment": PCIE.sha256(USB_FRAGMENT),
                         "candidate_fragment": PCIE.sha256(CANDIDATE_FRAGMENT),
                         "pcie_fragment": PCIE.sha256(PCIE.FRAGMENT),
                         "routing_inventory": ROUTING_SHA, "fresh_capture": FRESH_CAPTURE_SHA,
                         "source_manifest": PCIE.sha256(PCIE.SOURCE_MANIFEST)},
        "include_order": ["t6032-j575d.dts", "j575d-pcie-ports.dtsi",
                           "j575d-usb-layout.dtsi", "j575d-ace3-candidate.dtsi"],
        "source_inference": {"select_irqs": [13, 39, 65, 91], "basis": "cached sibling-board DT convention", "j575d_witnessed": False},
        "checks": {"closure_files": 19, "routing_receipts": 38, "usb_baseline_hash_matches": True,
                   "six_ace_children_disabled": True, "six_graphs_reciprocal": True,
                   "select_witness": False, "native_or_physical_functionality_tested": False,
                   "full_dtb_schema_validation": False},
        "native_boot_approved": False,
    }
    (work / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"workspace={work}")
    print(f"PASS closure=19 routing_receipts=38 ace_children=6 graph_links=18 endpoints=36 controls={len(controls)}")
    print(f"baseline_sha256={baseline['sha256']} candidate_sha256={candidate['sha256']}")
    print(f"warnings baseline={baseline['warnings']} candidate={candidate['warnings']} delta={candidate['warnings'] - baseline['warnings']}")
    print(f"manifest={work / 'manifest.json'}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BuildError as exc:
        print(f"j575d ACE3 candidate build: ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
