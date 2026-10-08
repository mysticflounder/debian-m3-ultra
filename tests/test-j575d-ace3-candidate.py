#!/usr/bin/env python3
"""Offline regression checks for the disabled J575d ACE3 graph candidate.

Usage: python tests/test-j575d-ace3-candidate.py <compiled-workspace>

The workspace must already contain ``baseline.dtb`` (the USB 4+2 provider
profile) and ``candidate.dtb`` (that profile plus the disabled ACE3 graph).
This test only parses those artifacts; it never compiles, probes hardware,
launches a VM, or edits either DTB.
"""

from __future__ import annotations

import argparse
import copy
import importlib.util
import pathlib
import struct
import sys
import unittest
from typing import Callable


ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILDER_PATH = ROOT / "scripts/build-j575d-ace3-candidate.py"
spec = importlib.util.spec_from_file_location("j575d_ace3_candidate_builder", BUILDER_PATH)
if spec is None or spec.loader is None:
    raise RuntimeError(f"cannot import {BUILDER_PATH}")
BUILDER = importlib.util.module_from_spec(spec)
spec.loader.exec_module(BUILDER)


ACE_LABELS = ("hpm0", "hpm1", "hpm2", "hpm3", "hpm4", "hpm5")
CONNECTOR_LABELS = tuple(f"typec{i}" for i in range(6))
ENDPOINT_LABELS = tuple(
    label
    for i, suffix in enumerate(("", "", "", "", "_die1", "_die1"))
    for label in (
        f"typec{i}_hs",
        f"typec{i}_ss",
        f"dwc3_{i if i < 4 else i - 4}{suffix}_hs",
        f"dwc3_{i if i < 4 else i - 4}{suffix}_ss",
        f"atcphy{i if i < 4 else i - 4}{suffix}_typec_lanes",
        f"atcphy{i if i < 4 else i - 4}{suffix}_usb3",
    )
)

EXPECTED_BANK_SIDS = (("nub_spmi_a0", 0xC), ("nub_spmi_a0", 0xA),
                     ("nub_spmi_a0", 0x8), ("nub_spmi_a0", 0x6),
                     ("nub_spmi_a2", 0xC), ("nub_spmi_a2", 0xA))
EXPECTED_IRQS = ((11, 13, 17, 19), (37, 39, 43, 45),
                 (63, 65, 69, 71), (89, 91, 95, 97),
                 (11, 13, 17, 19), (37, 39, 43, 45))
PROVIDER_PAIRS = (("dwc3_0", "atcphy0"), ("dwc3_1", "atcphy1"),
                  ("dwc3_2", "atcphy2"), ("dwc3_3", "atcphy3"),
                  ("dwc3_0_die1", "atcphy0_die1"),
                  ("dwc3_1_die1", "atcphy1_die1"))


def words(value: bytes) -> tuple[int, ...]:
    return struct.unpack(f">{len(value) // 4}I", value)


def packed(*values: int) -> bytes:
    return struct.pack(f">{len(values)}I", *values)


def node(tree: BUILDER.Tree, label: str) -> str:
    return BUILDER.USB.symbol(tree, label)


def node_phandle(tree: BUILDER.Tree, label: str) -> int:
    return words(tree[node(tree, label)]["phandle"])[0]


def endpoint_target(tree: BUILDER.Tree, label: str) -> str:
    path = node(tree, label)
    target = words(tree[path]["remote-endpoint"])[0]
    return BUILDER.USB.handles(tree)[target]


def swap_reference_numbers(tree: BUILDER.Tree, first: int, second: int) -> None:
    """Reallocate two phandle numbers while preserving every owner identity."""
    for path, props in tree.items():
        for name, value in list(props.items()):
            if name == "phandle" or not BUILDER.USB.reference_property(name):
                continue
            if len(value) % 4:
                continue
            values = list(words(value))
            values = [second if value == first else first if value == second else value
                      for value in values]
            props[name] = packed(*values)


class Ace3CandidateTests(unittest.TestCase):
    workspace: pathlib.Path
    before: BUILDER.Tree
    after: BUILDER.Tree
    routing: dict

    @classmethod
    def setUpClass(cls) -> None:
        cls.before = BUILDER.USB.read_dtb(cls.workspace / "baseline.dtb")
        cls.after = BUILDER.USB.read_dtb(cls.workspace / "candidate.dtb")
        cls.routing = BUILDER.load_routing()

    def reject(self, name: str, mutate: Callable[[BUILDER.Tree], None]) -> None:
        mutant = copy.deepcopy(self.after)
        mutate(mutant)
        with self.assertRaises(BUILDER.BuildError, msg=name):
            BUILDER.validate_candidate(mutant, self.routing)
            BUILDER.verify_delta(self.before, mutant)

    def reject_reason(
        self,
        name: str,
        mutate: Callable[[BUILDER.Tree], None],
        owner: str,
        context: tuple[str, ...] = ("path", "owner", "allowed", "port"),
    ) -> None:
        mutant = copy.deepcopy(self.after)
        mutate(mutant)
        with self.assertRaises(BUILDER.BuildError, msg=name) as raised:
            BUILDER.validate_candidate(mutant, self.routing)
            BUILDER.verify_delta(self.before, mutant)
        message = str(raised.exception).lower()
        self.assertIn(owner.lower(), message, name)
        self.assertTrue(any(word in message for word in context), message)

    def test_candidate_validates_as_disabled_usb4plus2_graph(self) -> None:
        summary = BUILDER.validate_candidate(self.after, self.routing)
        self.assertEqual(summary["ace_children"], 6)
        self.assertEqual(summary["graph_links"], 18)
        self.assertEqual(summary["graph_endpoints"], 36)
        delta = BUILDER.verify_delta(self.before, self.after)
        self.assertGreaterEqual(delta["added_nodes"], 6)
        self.assertGreaterEqual(delta["added_symbols"], 7)

    def test_all_six_ace_children_and_a2_parent_are_disabled(self) -> None:
        for index, (parent_label, sid) in enumerate(EXPECTED_BANK_SIDS):
            path = node(self.after, ACE_LABELS[index])
            self.assertEqual(path.rsplit("/", 1)[0], node(self.after, parent_label))
            self.assertEqual(self.after[path]["status"], b"disabled\0")
            self.assertEqual(words(self.after[path]["reg"])[0], sid)
            self.assertEqual(words(self.after[path]["reg"])[1], 0)
            self.assertEqual(words(self.after[path]["interrupts"])[::2], EXPECTED_IRQS[index])
            self.assertEqual(words(self.after[path]["interrupts"])[1::2], (1, 1, 1, 1))
            self.assertEqual(
                self.after[path]["interrupt-names"], b"irq\0select\0sleep\0wake\0"
            )
        a2 = node(self.after, "nub_spmi_a2")
        self.assertEqual(a2.rsplit("/", 1)[0], node(self.after, "die0"))
        self.assertEqual(self.after[a2]["status"], b"disabled\0")
        self.assertEqual(words(self.after[a2]["reg"]), (2, 0xA11A8000, 0, 0x100))
        self.assertEqual(words(self.after[a2]["interrupts"])[-3:], (0, 767, 4))

    def test_exactly_eighteen_reciprocal_connections_and_four_plus_two_mapping(self) -> None:
        endpoint_paths = {node(self.after, label) for label in ENDPOINT_LABELS}
        self.assertEqual(len(endpoint_paths), 36)
        self.assertTrue(all("remote-endpoint" in self.after[path] for path in endpoint_paths))
        pairs = set()
        for path in endpoint_paths:
            target = endpoint_target(self.after, next(label for label in ENDPOINT_LABELS
                                                      if node(self.after, label) == path))
            self.assertIn(target, endpoint_paths)
            self.assertEqual(endpoint_target(self.after, next(label for label in ENDPOINT_LABELS
                                                              if node(self.after, label) == target)), path)
            pairs.add(frozenset((path, target)))
        self.assertEqual(len(pairs), 18)

        for index, (dwc3_label, phy_label) in enumerate(PROVIDER_PAIRS):
            self.assertEqual(endpoint_target(self.after, f"typec{index}_hs"),
                             node(self.after, f"{dwc3_label}_hs"))
            self.assertEqual(endpoint_target(self.after, f"typec{index}_ss"),
                             node(self.after, f"{phy_label}_typec_lanes"))
            self.assertEqual(endpoint_target(self.after, f"{dwc3_label}_ss"),
                             node(self.after, f"{phy_label}_usb3"))

    def test_legitimate_numeric_phandle_reallocation_preserves_owner_identity(self) -> None:
        mutant = copy.deepcopy(self.after)
        first, second = node_phandle(mutant, "atcphy0"), node_phandle(mutant, "atcphy1")
        mutant[node(mutant, "atcphy0")]["phandle"] = packed(second)
        mutant[node(mutant, "atcphy1")]["phandle"] = packed(first)
        swap_reference_numbers(mutant, first, second)
        BUILDER.validate_candidate(mutant, self.routing)
        BUILDER.verify_delta(self.before, mutant)

    def test_provider_owner_change_with_raw_payload_unchanged_is_rejected(self) -> None:
        def mutate(tree: BUILDER.Tree) -> None:
            first, second = node(tree, "atcphy0"), node(tree, "atcphy1")
            tree[first]["phandle"], tree[second]["phandle"] = (
                tree[second]["phandle"], tree[first]["phandle"])

        self.reject("provider_owner_change_without_payload_change", mutate)

    def test_wrong_ace_bank_and_sid_are_rejected(self) -> None:
        self.reject("wrong_ace_bank", lambda tree: tree["/__symbols__"].__setitem__(
            "hpm4", node(tree, "hpm0").encode() + b"\0"))

        def wrong_sid(tree: BUILDER.Tree) -> None:
            path = node(tree, "hpm0")
            value = list(words(tree[path]["reg"]))
            value[0] = 0xD
            tree[path]["reg"] = packed(*value)

        self.reject("wrong_ace_sid", wrong_sid)

    def test_wrong_irq_names_select_convention_and_edge_type_are_rejected(self) -> None:
        self.reject("wrong_irq_names", lambda tree: tree[node(tree, "hpm0")].__setitem__(
            "interrupt-names", b"irq\0sleep\0select\0wake\0"))

        def wrong_select(tree: BUILDER.Tree) -> None:
            path = node(tree, "hpm0")
            values = list(words(tree[path]["interrupts"]))
            values[2] = 14
            tree[path]["interrupts"] = packed(*values)

        self.reject("wrong_select_convention", wrong_select)

        def wrong_edge_type(tree: BUILDER.Tree) -> None:
            path = node(tree, "hpm0")
            values = list(words(tree[path]["interrupts"]))
            values[1::2] = [4, 4, 4, 4]
            tree[path]["interrupts"] = packed(*values)

        self.reject("wrong_edge_type", wrong_edge_type)

    def test_accidental_enable_and_wrong_a2_range_or_power_reference_are_rejected(self) -> None:
        self.reject("enabled_ace", lambda tree: tree[node(tree, "hpm0")].__setitem__(
            "status", b"okay\0"))
        self.reject("enabled_a2", lambda tree: tree[node(tree, "nub_spmi_a2")].__setitem__(
            "status", b"okay\0"))

        def wrong_range(tree: BUILDER.Tree) -> None:
            path = node(tree, "nub_spmi_a2")
            tree[path]["reg"] = packed(2, 0xA11A9000, 0, 0x100)

        self.reject("wrong_a2_range", wrong_range)

        def wrong_power(tree: BUILDER.Tree) -> None:
            path = node(tree, "nub_spmi_a2")
            tree[path]["power-domains"] = packed(node_phandle(tree, "ps_nub_spmi_a0"))

        self.reject("wrong_a2_power_reference", wrong_power)

    def test_nonreciprocal_and_swapped_but_reciprocal_graphs_are_rejected(self) -> None:
        def nonreciprocal(tree: BUILDER.Tree) -> None:
            path = node(tree, "typec0_hs")
            tree[path]["remote-endpoint"] = packed(node_phandle(tree, "dwc3_1_hs"))

        self.reject("nonreciprocal_graph", nonreciprocal)

        def swap_graph_identity(tree: BUILDER.Tree) -> None:
            swaps = (("typec0_hs", "typec1_hs"), ("typec0_ss", "typec1_ss"),
                     ("dwc3_0_hs", "dwc3_1_hs"), ("dwc3_0_ss", "dwc3_1_ss"),
                     ("atcphy0_typec_lanes", "atcphy1_typec_lanes"),
                     ("atcphy0_usb3", "atcphy1_usb3"))
            for first, second in swaps:
                first_path, second_path = node(tree, first), node(tree, second)
                first_target = tree[first_path]["remote-endpoint"]
                second_target = tree[second_path]["remote-endpoint"]
                tree[first_path]["remote-endpoint"] = second_target
                tree[second_path]["remote-endpoint"] = first_target

        self.reject("swapped_reciprocal_port_identity", swap_graph_identity)

    def test_endpoint_owner_paths_and_port_container_shape_are_rejected(self) -> None:
        def wrong_phy_right_port(tree: BUILDER.Tree) -> None:
            path = node(tree, "atcphy0") + "/ports/port@0"
            tree[path]["reg"] = packed(1)

        self.reject_reason("wrong_atcphy_rightside_port", wrong_phy_right_port,
                           node(self.after, "atcphy0"), ("bad port", "path", "owner", "reg"))

        def wrong_phy_port_cells(tree: BUILDER.Tree) -> None:
            path = node(tree, "atcphy0") + "/ports"
            tree[path]["#address-cells"] = packed(2)

        self.reject_reason("wrong_atcphy_ports_address_cells", wrong_phy_port_cells,
                           node(self.after, "atcphy0"), ("cells", "ports", "path", "owner"))

        def relocate_endpoint_symbols(tree: BUILDER.Tree) -> None:
            symbols = tree["/__symbols__"]

            def swap_provider_pair(first: str, second: str) -> None:
                first_path = node(tree, first)
                second_path = node(tree, second)
                symbols[first], symbols[second] = symbols[second], symbols[first]
                first_remote = tree[first_path]["remote-endpoint"]
                tree[first_path]["remote-endpoint"] = tree[second_path]["remote-endpoint"]
                tree[second_path]["remote-endpoint"] = first_remote

            def swap_connector_targets(left: str, right: str, first: str, second: str) -> None:
                first_path = node(tree, first)
                second_path = node(tree, second)
                tree[node(tree, left)]["remote-endpoint"] = packed(
                    node_phandle(tree, second))
                tree[node(tree, right)]["remote-endpoint"] = packed(
                    node_phandle(tree, first))

            swap_connector_targets("typec0_hs", "typec1_hs", "dwc3_0_hs", "dwc3_1_hs")
            swap_provider_pair("dwc3_0_hs", "dwc3_1_hs")
            swap_connector_targets("typec0_ss", "typec1_ss",
                                   "atcphy0_typec_lanes", "atcphy1_typec_lanes")
            swap_provider_pair("atcphy0_typec_lanes", "atcphy1_typec_lanes")
            swap_provider_pair("dwc3_0_ss", "dwc3_1_ss")
            swap_provider_pair("atcphy0_usb3", "atcphy1_usb3")

        self.reject_reason("relocated_endpoint_owner_symbols", relocate_endpoint_symbols,
                           "dwc3_0_hs", ("relocated", "symbol", "path", "owner", "allowed"))

    def test_unrelated_node_property_existing_resource_and_status_changes_are_rejected(self) -> None:
        self.reject("extra_unrelated_node", lambda tree: tree.__setitem__(
            "/j575d-unrelated-test", {"compatible": b"unrelated\0"}))
        self.reject("extra_unrelated_property", lambda tree: tree["/"].__setitem__(
            "j575d-unrelated-property", b"1\0"))

        def existing_resource(tree: BUILDER.Tree) -> None:
            path = node(tree, "dwc3_0")
            value = list(words(tree[path]["reg"]))
            value[1] += 0x1000
            tree[path]["reg"] = packed(*value)

        self.reject("existing_resource_change", existing_resource)
        self.reject("existing_status_change", lambda tree: tree[node(tree, "dwc3_0")].__setitem__(
            "status", b"disabled\0"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace", type=pathlib.Path)
    args, unittest_args = parser.parse_known_args()
    for name in ("baseline.dtb", "candidate.dtb"):
        if not (args.workspace / name).is_file():
            parser.error(f"workspace must contain {name}")
    Ace3CandidateTests.workspace = args.workspace
    result = unittest.main(argv=[sys.argv[0], *unittest_args], verbosity=2, exit=False)
    return 0 if result.result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
