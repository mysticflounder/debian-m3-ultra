#!/usr/bin/env python3
"""Offline stdlib tests for the bounded J575d ioreg metadata collector."""

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import pathlib
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts/collect-j575d-usb-metadata.py"
SPEC = importlib.util.spec_from_file_location("collect_j575d_usb_metadata", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
COLLECTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COLLECTOR)


TUNABLES = [f"tunable_{index:02d}" for index in range(14)]


def _u32(value: int) -> str:
    return value.to_bytes(4, "little").hex()


def _fixture() -> str:
    lines = [
        "+-o Root",
        '    "target-sub-type" = <"T6032">',
        '    "model" = "J575d fixture"',
        '    "OS Build Version" = "fixture-os"',
        '    "IOKitBuildVersion" = "fixture-kernel"',
        '    "unrelated-root-field" = "must not leak"',
        "    +-o device-tree",
        '        "compatible" = <"apple,j575d">',
    ]
    for parent_index in range(2):
        parent_phandle = 0xA0000000 + parent_index
        lines.extend([
            f"        +-o nub-spmi-a{parent_index}@{parent_index}",
            f'            "AAPL,phandle" = <{_u32(parent_phandle)}>',
            '            "compatible" = "apple,spmi-provider"',
            '            "provider-private" = "must not leak"',
        ])
        for offset in range(3):
            port = parent_index * 3 + offset + 1
            hpm_phandle = 0xB0000000 + port
            lines.extend([
                f"            +-o hpm{port - 1}@{port:x}",
                f'                "AAPL,phandle" = <{_u32(hpm_phandle)}>',
                f'                "port-number" = <{_u32(port)}>',
                f'                "dock" = <{_u32(parent_phandle)}>',
                '                "features-supported" = <01020304>',
                '                "secret-hpm-field" = <deadbeef>',
            ])
    for port in range(1, 7):
        lines.extend([
            f"        +-o atc-phy{port - 1}@{port:x}",
            f'            "port-number" = <{_u32(port)}>',
            '            "compatible" = "apple,atc-phy"',
            '            "reg" = <0102030405060708>',
            '            "unrelated-binary" = <cafebabe>',
            *[f'            "{key}" = <{_u32(port)}>' for key in TUNABLES],
        ])
    for port in range(1, 7):
        lines.extend([
            f"        +-o usb-drd{port - 1}@{port:x}",
            f'            "port-number" = <{_u32(port)}>',
            '            "compatible" = <"apple,usb-drd">',
            '            "role" = "dual-role"',
            '            "unrelated-usb-field" = "must not leak"',
        ])
    return "\n".join(lines) + "\n"


IOREG_TEXT = _fixture()


class CollectJ575dUsbMetadataTests(unittest.TestCase):
    def test_parser_tracks_paths_and_exact_public_values(self) -> None:
        records, root = COLLECTOR.parse_ioreg(IOREG_TEXT)
        atc = next(record for record in records if record["node"] == "atc-phy0@1")
        self.assertEqual(atc["path"], ["Root", "device-tree", "atc-phy0@1"])
        self.assertEqual(root["device-tree-compatible"], '<"apple,j575d">')

        binary = atc["properties"]["reg"]
        expected = bytes.fromhex("0102030405060708")
        self.assertEqual(binary, {
            "byte_length": len(expected),
            "hex": expected.hex(),
            "sha256": hashlib.sha256(expected).hexdigest(),
        })
        self.assertEqual(atc["properties"]["tunable_00"]["hex"], "01000000")
        self.assertNotIn("unrelated-binary", atc["properties"])
        self.assertNotIn("unrelated-root-field", root)

    def test_main_mocks_ioreg_and_emits_joined_json(self) -> None:
        completed = mock.Mock(stdout=IOREG_TEXT)
        command = ["/usr/sbin/ioreg", "-p", "IODeviceTree", "-l", "-w0"]
        output = io.StringIO()
        with mock.patch.object(COLLECTOR.subprocess, "run", return_value=completed) as run:
            with contextlib.redirect_stdout(output):
                result = COLLECTOR.main()

        self.assertEqual(result, 0)
        run.assert_called_once_with(
            command, check=True, capture_output=True, text=True, encoding="utf-8"
        )
        payload = json.loads(output.getvalue())
        self.assertEqual(payload["schema"], "j575d-usb-metadata-v1")
        self.assertFalse(payload["native_boot_approved"])
        self.assertEqual(payload["host_identity"]["target_type"], "T6032")
        self.assertNotIn("chip", payload["host_identity"])
        self.assertEqual(payload["command"], " ".join(command))
        self.assertEqual(payload["validation"], {
            "atc_phy_count": 6,
            "hpm_count": 6,
            "named_atc_tunable_count": 14,
            "unfiltered_stream_retained": False,
        })
        self.assertEqual(len(payload["atc_phy"]), 6)
        self.assertEqual(len(payload["usb_drd"]), 6)
        self.assertEqual(len(payload["hpm"]), 6)
        self.assertEqual(len(payload["spmi_ancestors"]), 2)
        self.assertEqual(
            [item["port_number"] for item in payload["hpm_port_join"]],
            list(range(1, 7)),
        )
        self.assertTrue(all(item["atc_phy_same_port_number"] for item in payload["hpm_port_join"]))
        self.assertEqual(
            {item["port_number"] for item in payload["hpm_port_join"]}, set(range(1, 7))
        )
        for record in payload["atc_phy"]:
            self.assertEqual(
                {key for key in record["properties"] if key.startswith("tunable_")},
                set(TUNABLES),
            )
            self.assertNotIn("unrelated-binary", record["properties"])


if __name__ == "__main__":
    unittest.main()
