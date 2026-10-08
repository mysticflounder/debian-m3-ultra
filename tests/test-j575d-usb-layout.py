#!/usr/bin/env python3
"""Offline regression checks for a previously compiled J575d USB profile.

Usage: python tests/test-j575d-usb-layout.py <compiled-workspace>

The workspace must already contain pcie.dtb and profile.dtb.  This test never
rebuilds, probes hardware, launches a VM, or edits the compiled artifacts.
"""

from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import pathlib
import re
import struct
import sys
import unittest
from collections import Counter
from typing import Callable


ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILDER_PATH = ROOT / "scripts/build-j575d-usb-layout.py"
spec = importlib.util.spec_from_file_location("j575d_usb_layout_builder", BUILDER_PATH)
if spec is None or spec.loader is None:
    raise RuntimeError(f"cannot import {BUILDER_PATH}")
BUILDER = importlib.util.module_from_spec(spec)
spec.loader.exec_module(BUILDER)
SOURCE_MANIFEST = ROOT / "docs/inventory/t6032-board-dt-sources-2026-09-26.json"
DT_ROOT = ROOT / "scratch/m1n1-board-dt"
PROPERTY_RE = re.compile(
    r"(?ms)^\s*([A-Za-z][A-Za-z0-9,#_-]*)\s*=\s*((?:(?!;).)*?)\s*;"
)


def word(value: int) -> bytes:
    return struct.pack(">I", value)


def cell_words(*values: int) -> bytes:
    return struct.pack(f">{len(values)}I", *values)


def phandle(tree: BUILDER.Tree, label: str) -> int:
    path = BUILDER.symbol(tree, label)
    return BUILDER.cells(tree[path]["phandle"])[0]


def source_reference_properties() -> Counter[str]:
    """Enumerate angle-bracket source references, excluding bare aliases."""
    manifest = json.loads(SOURCE_MANIFEST.read_text(encoding="utf-8"))
    found: Counter[str] = Counter()
    for entry in manifest["source_files"]:
        text = (DT_ROOT / entry["local"]).read_text(encoding="utf-8")
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        text = re.sub(r"//[^\n]*", "", text)
        for match in PROPERTY_RE.finditer(text):
            name, value = match.groups()
            # aliases such as `serial0 = &serial0;` are paths, not cells.
            if re.search(r"<[^>]*&[A-Za-z_]", value):
                found[name] += 1
    return found


def swap_provider_phandles(tree: BUILDER.Tree, first: str, second: str) -> None:
    first_path, second_path = BUILDER.symbol(tree, first), BUILDER.symbol(tree, second)
    first_value = tree[first_path]["phandle"]
    tree[first_path]["phandle"], tree[second_path]["phandle"] = (
        tree[second_path]["phandle"], first_value
    )


class UsbLayoutTests(unittest.TestCase):
    workspace: pathlib.Path
    before: BUILDER.Tree
    after: BUILDER.Tree
    routing: dict

    @classmethod
    def setUpClass(cls) -> None:
        cls.before = BUILDER.read_dtb(cls.workspace / "pcie.dtb")
        cls.after = BUILDER.read_dtb(cls.workspace / "profile.dtb")
        cls.routing = BUILDER.load_routing()

    def test_profile_matches_routing_contract(self) -> None:
        ports = BUILDER.validate_profile(self.after, self.routing)
        self.assertEqual([item["die"] for item in ports], [0, 0, 0, 0, 1, 1])
        self.assertEqual({item["port_number"] for item in ports}, {1, 2, 3, 4, 5, 6})

    def test_delta_is_bounded(self) -> None:
        delta = BUILDER.verify_delta(self.before, self.after)
        self.assertEqual(delta["added_nodes"], 4)
        self.assertEqual(delta["disabled_nodes"], 4)
        self.assertEqual(delta["added_symbols"], 4)

    def reject_mutation(
        self,
        name: str,
        mutate: Callable[[BUILDER.Tree], None],
        expected_message: str,
    ) -> None:
        mutant = copy.deepcopy(self.after)
        mutate(mutant)
        with self.assertRaises(BUILDER.BuildError, msg=name) as raised:
            BUILDER.validate_profile(mutant, self.routing)
            BUILDER.verify_delta(self.before, mutant)
        self.assertIn(expected_message, str(raised.exception), name)

    def test_mutation_wrong_port4_base_rejected(self) -> None:
        path = BUILDER.symbol(self.after, "dwc3_3")

        def mutate(tree: BUILDER.Tree) -> None:
            tree[path]["reg"] = cell_words(0x14, 0x02280000, 0, 0xCD00) + tree[path]["reg"][16:]

        self.reject_mutation("wrong_port4_base", mutate, "dwc3_3 reg")

    def test_mutation_pointer_rejected(self) -> None:
        path = BUILDER.symbol(self.after, "dwc3_3")
        dart0 = phandle(self.after, "dwc3_3_dart_0")

        def mutate(tree: BUILDER.Tree) -> None:
            tree[path]["iommus"] = cell_words(dart0, 0, dart0, 1)

        self.reject_mutation("wrong_dart_pointer", mutate, "dwc3_3 iommus")

    def test_mutation_power_manager_pointer_rejected(self) -> None:
        path = BUILDER.symbol(self.after, "dwc3_3")
        wrong_power = phandle(self.after, "ps_atc2_usb")

        def mutate(tree: BUILDER.Tree) -> None:
            tree[path]["power-domains"] = word(wrong_power)

        self.reject_mutation("wrong_pmgr_pointer", mutate, "dwc3_3 power-domains")

    def test_mutation_irq_rejected(self) -> None:
        path = BUILDER.symbol(self.after, "dwc3_3")

        def mutate(tree: BUILDER.Tree) -> None:
            tree[path]["interrupts"] = cell_words(0, 0, 858, 4)

        self.reject_mutation("wrong_port4_irq", mutate, "dwc3_3 interrupts")

    def test_mutation_extra_alias_rejected(self) -> None:
        target = BUILDER.symbol(self.after, "dwc3_3")

        def mutate(tree: BUILDER.Tree) -> None:
            tree["/__symbols__"]["unapproved_usb_alias"] = target.encode() + b"\0"

        self.reject_mutation("extra_alias", mutate, "unexpected existing-node changes")

    def test_mutation_phantom_provider_rejected(self) -> None:
        phantom = "/soc@200000000/phantom-provider@1310000000"

        def mutate(tree: BUILDER.Tree) -> None:
            tree[phantom] = {
                "compatible": b"apple,t6031-dart\0apple,t8110-dart\0",
                "phandle": word(0x7FFF),
                "#iommu-cells": word(1),
            }

        self.reject_mutation("phantom_provider", mutate, "unexpected node additions/removals")

    def test_canonical_property_ignores_phandle_renumbering(self) -> None:
        old = {
            "/provider": {"phandle": word(1), "#power-domain-cells": word(0)},
            "/consumer": {"power-domains": word(1)},
        }
        new = {
            "/provider": {"phandle": word(99), "#power-domain-cells": word(0)},
            "/consumer": {"power-domains": word(99)},
        }
        old_value = BUILDER.canonical_property(old, "/consumer", "power-domains", BUILDER.handles(old))
        new_value = BUILDER.canonical_property(new, "/consumer", "power-domains", BUILDER.handles(new))
        self.assertEqual(old_value, (("/provider", ()),))
        self.assertEqual(old_value, new_value)

    def test_canonical_property_preserves_null_interrupt_slots(self) -> None:
        tree = {
            "/aic": {"phandle": word(5), "#interrupt-cells": word(4)},
            "/admac": {
                # <0>, <0>, <&aic 0 0 630 4>, <0>
                "interrupts-extended": cell_words(0, 0, 5, 0, 0, 630, 4, 0),
            },
        }
        value = BUILDER.canonical_property(
            tree, "/admac", "interrupts-extended", BUILDER.handles(tree)
        )
        self.assertEqual(
            value,
            ((None, ()), (None, ()), ("/aic", (0, 0, 630, 4)), (None, ())),
        )

    def test_canonical_sound_dai_reference_identity(self) -> None:
        mca = BUILDER.symbol(self.after, "mca")
        cpu = "/sound/dai-link@0/cpu"
        self.assertIn(cpu, self.after)
        self.assertEqual(
            BUILDER.canonical_property(self.after, cpu, "sound-dai", BUILDER.handles(self.after)),
            ((mca, (0,)),),
        )

    def test_canonical_apple_sart_reference_identity(self) -> None:
        nvme = BUILDER.symbol(self.after, "nvme_die1")
        sart = BUILDER.symbol(self.after, "sart_die1")
        self.assertEqual(
            BUILDER.canonical_property(self.after, nvme, "apple,sart", BUILDER.handles(self.after)),
            ((sart, ()),),
        )

    def test_source_closure_reference_handlers_cover_all_families(self) -> None:
        found = source_reference_properties()
        expected_counts = {
            "next-level-cache": 32,
            "performance-domains": 16,
            "pinctrl-0": 11,
            "apple,helper-cpu": 1,
            "iommu-map": 1,
            "msi-ranges": 1,
            "interrupt-map": 4,
        }
        for name, count in expected_counts.items():
            self.assertEqual(found[name], count, name)
        for name in found:
            self.assertTrue(BUILDER.reference_property(name), name)

    def test_new_reference_families_have_exact_canonical_shapes(self) -> None:
        expected_counts = {
            "next-level-cache": 32,
            "performance-domains": 16,
            "pinctrl-0": 11,
            "apple,helper-cpu": 1,
            "iommu-map": 1,
            "msi-ranges": 1,
            "interrupt-map": 4,
        }
        found = {
            name: [(path, props[name]) for path, props in self.after.items() if name in props]
            for name in expected_counts
        }
        mapping = BUILDER.handles(self.after)
        for name, count in expected_counts.items():
            self.assertEqual(len(found[name]), count, name)
            for path, _ in found[name]:
                value = BUILDER.canonical_property(self.after, path, name, mapping)
                self.assertTrue(value, f"empty canonical value: {name} {path}")
                if name in {"next-level-cache", "performance-domains", "pinctrl-0", "apple,helper-cpu"}:
                    self.assertTrue(all(isinstance(item[0], str) and item[1] == () for item in value), path)
                elif name == "iommu-map":
                    self.assertTrue(all(
                        len(item) == 3 and isinstance(item[0], int) and isinstance(item[1], str)
                        and len(item[2]) == 2 for item in value
                    ), path)
                elif name == "msi-ranges":
                    self.assertTrue(all(
                        len(item) == 3 and item[0] == () and isinstance(item[1], str)
                        and len(item[2]) == 5
                        for item in value
                    ), path)
                elif name == "interrupt-map":
                    self.assertTrue(all(
                        len(item) == 3 and len(item[0]) == 4 and isinstance(item[1], str)
                        and len(item[2]) == 4 for item in value
                    ), path)

    def test_missing_reference_family_target_swaps_rejected(self) -> None:
        swaps = (
            ("next-level-cache", "l2_cache_0", "l2_cache_1"),
            ("performance-domains", "cpufreq_e", "cpufreq_p0"),
            ("pinctrl-0", "i2c0_pins", "i2c1_pins"),
            ("apple,helper-cpu", "mtp", "aop"),
            ("iommu-map", "pcie0_dart_0", "pcie0_dart_1"),
            ("msi-ranges", "aic", "pcie0"),
            ("interrupt-map", "port00", "port01"),
        )
        for name, first, second in swaps:
            with self.subTest(property=name):
                mutant = copy.deepcopy(self.after)
                raw_payloads = {
                    (path, name): props[name]
                    for path, props in self.after.items()
                    if name in props
                }
                swap_provider_phandles(mutant, first, second)
                with self.assertRaises(BUILDER.BuildError, msg=name) as raised:
                    BUILDER.verify_delta(self.before, mutant)
                for (path, prop), raw in raw_payloads.items():
                    self.assertEqual(mutant[path][prop], raw, f"raw payload changed: {name} {path}")
                message = str(raised.exception)
                if name == "msi-ranges":
                    self.assertTrue(
                        "unexpected existing-node changes" in message or "missing provider cells" in message,
                        message,
                    )
                else:
                    self.assertIn("unexpected existing-node changes", message, name)

    def test_all_unwitnessed_die1_quartet_disabled(self) -> None:
        for label in BUILDER.UNWITNESSED:
            path = BUILDER.symbol(self.after, label)
            self.assertEqual(self.after[path].get("status"), b"disabled\0", label)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace", type=pathlib.Path)
    args, unittest_args = parser.parse_known_args()
    if not (args.workspace / "pcie.dtb").is_file() or not (args.workspace / "profile.dtb").is_file():
        parser.error("workspace must contain pcie.dtb and profile.dtb")
    UsbLayoutTests.workspace = args.workspace
    result = unittest.main(argv=[sys.argv[0], *unittest_args], verbosity=2, exit=False)
    return 0 if result.result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
