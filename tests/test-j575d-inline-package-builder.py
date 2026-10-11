#!/usr/bin/env python3
"""Offline profile/ELF contract tests for the inline package builder."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "j575d_inline_builder", ROOT / "scripts/build-j575d-inline-package.py"
)
assert SPEC and SPEC.loader
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


class InlinePackageProfileTests(unittest.TestCase):
    def test_historical_default_profile_stays_pinned(self) -> None:
        profile = BUILDER.profile_config("historical")
        self.assertEqual(tuple(profile["boards"]), ("candidate", "official"))
        self.assertEqual(
            profile["inputs"]["loader"][1],
            "edb04ff16c0e467a6179392ac99674faa59005aeb9b89c9e062f8305fcb154cb",
        )
        self.assertEqual(
            profile["inputs"]["initramfs"][1],
            "7bfb73c02f74a285f6defb02741b85cb880fdbeb7d4a27f458c4c32b62383f30",
        )

    def test_fork_profile_uses_explicit_event_board_and_pins(self) -> None:
        profile = BUILDER.profile_config("fork-current")
        self.assertEqual(tuple(profile["boards"]), ("official", "event"))
        self.assertEqual(
            profile["inputs"]["loader"][1],
            "7c1c0ef40b0ce7a578fd3fba74333655f89f3ee234968db44ae3fde4e0ba1c70",
        )
        self.assertEqual(
            profile["inputs"]["loader_elf"][1],
            "427d01dc8df26aa9d9f56e5593b50dbc7a26b72f6f840039d2921b5b24f22d7a",
        )
        self.assertEqual(
            profile["inputs"]["initramfs"][1],
            "807b823e87a53304106e5f49e48ed5fc918040f21570cbc77e87df26df5613ee",
        )
        self.assertEqual(
            profile["boards"]["event"][1],
            "be4ab6f0f5dcd508a5aa25df4e7692246715ce356142b2c8bcc9b1aff1dab861",
        )

    def test_both_raw_elf_profiles_bind_eof_to_symbols(self) -> None:
        for name in ("historical", "fork-current"):
            profile = BUILDER.profile_config(name)
            symbols = BUILDER.elf_symbols(profile["inputs"]["loader_elf"][0].read_bytes())
            self.assertEqual(symbols["_base"], 0)
            self.assertEqual(symbols["_end"], symbols["_payload_start"])
            loader = profile["inputs"]["loader"][0].read_bytes()
            self.assertEqual(len(loader), symbols["_payload_start"] - symbols["_base"])

    def test_board_metadata_does_not_mislabel_official_as_event(self) -> None:
        self.assertEqual(
            BUILDER.board_metadata("event"),
            {
                "board_role": "explicit event candidate; retained PHY disabled state; no automatic enablement",
                "candidate_schema_diagnostics_remain": True,
            },
        )
        self.assertEqual(
            BUILDER.board_metadata("official"),
            {
                "board_role": "official kernel board DTB; no event-candidate substitution",
                "candidate_schema_diagnostics_remain": False,
            },
        )

    def test_raw_prefix_rejects_missing_mandatory_symbol(self) -> None:
        with self.assertRaisesRegex(ValueError, "missing required symbols"):
            BUILDER.raw_prefix_contract({"_base": 0, "_end": 0x3B0000}, 0x3B0000)


if __name__ == "__main__":
    unittest.main()
