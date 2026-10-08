"""Offline fixtures for filtered SPMI routing observations."""
import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "spmi_routing", ROOT / "scripts/collect-j575d-spmi-routing.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RoutingFilterTests(unittest.TestCase):
    def test_bank_ancestors_without_unrelated_values(self):
        bank = {"IORegistryEntryName": "nub-spmi-a2@A11A8000", "reg": b"\x00\x01",
                "interrupt-parent": b"\x70\x01\x00\x00", "die-index": 1,
                "IOPlatformSerialNumber": "DO-NOT-RETAIN",
                "IORegistryEntryID": 12345}
        archive = [{"IORegistryEntryName": "Root", "ranges": b"\x01",
                    "IOPlatformUUID": "DO-NOT-RETAIN",
                    "IORegistryEntryChildren": [
                        {"IORegistryEntryName": "arm-io", "#address-cells": 2,
                         "IORegistryEntryChildren": [bank]},
                        {"IORegistryEntryName": "unrelated", "reg": b"secret"}]}]
        result = MODULE.filter_archive(archive, "IODeviceTree")
        self.assertEqual(result["target_count"], 1)
        self.assertEqual(len(result["records"]), 3)
        leaf = result["records"][-1]
        self.assertEqual(leaf["path"], ["Root", "arm-io", "nub-spmi-a2@A11A8000"])
        self.assertEqual(leaf["properties"]["die-index"], 1)
        self.assertEqual(leaf["properties"]["interrupt-parent"]["hex"], "70010000")
        self.assertNotIn("IORegistryEntryID", leaf["available_property_names"])
        self.assertNotIn("IOPlatformSerialNumber", leaf["properties"])
        self.assertNotIn("DO-NOT-RETAIN", str(result))
        self.assertNotIn("unrelated", str(result))

    def test_service_resources_and_power_state_are_bounded(self):
        archive = [{"IORegistryEntryName": "nub-spmi-a2", "IORegistryEntryChildren": [
            {"IORegistryEntryName": "controller", "IOObjectClass": "AppleSPMIController",
             "IODeviceMemory": [{"address": 0x2A11A8000, "length": 0x100,
                                  "private": "DO-NOT-RETAIN"}],
             "IOInterruptControllers": ["AIC"],
             "IOInterruptSpecifiers": [b"\xff\x02\x00\x00"],
             "IOPowerManagement": {"CurrentPowerState": 2, "PrivateState": "DO-NOT-RETAIN"}}]}]
        result = MODULE.filter_archive(archive, "IOService")
        self.assertEqual(result["target_count"], 2)
        leaf = result["records"][-1]["properties"]
        self.assertEqual(leaf["IODeviceMemory"], [{"address": 0x2A11A8000, "length": 0x100}])
        self.assertEqual(leaf["IOPowerManagement"], {"CurrentPowerState": 2})
        self.assertEqual(leaf["IOInterruptSpecifiers"][0]["hex"], "ff020000")
        self.assertNotIn("DO-NOT-RETAIN", str(result))

    def test_unknown_spmi_bank_is_not_selected(self):
        result = MODULE.filter_archive([{"IORegistryEntryName": "nub-spmi-a1@0"}], "IODeviceTree")
        self.assertEqual(result["target_count"], 0)
        self.assertEqual(result["records"], [])

    def test_dictionary_root_matches_modern_ioreg(self):
        result = MODULE.filter_archive({"IORegistryEntryName": "nub-spmi-a0@A1188000"},
                                       "IODeviceTree")
        self.assertEqual(result["target_count"], 1)
        self.assertTrue(result["records"][0]["target"])

    def test_other_controllers_are_not_selected(self):
        result = MODULE.filter_archive(
            {"IORegistryEntryName": "die1-nub-spmi2", "IORegistryEntryChildren": [
                {"IORegistryEntryName": "AppleSPMIController", "IOClass": "AppleSPMIController"}]},
            "IOService")
        self.assertEqual(result["target_count"], 0)
        self.assertEqual(result["records"], [])

    def test_service_bank_aliases(self):
        for key in ("IOName", "IONameMatched"):
            with self.subTest(key=key):
                result = MODULE.filter_archive(
                    {"IORegistryEntryName": "provider", key: "nub-spmi-a2"}, "IOService")
                self.assertEqual(result["target_count"], 1)

    def test_usb_provider_selection_is_opt_in(self):
        archive = [{"IORegistryEntryName": "usb-drd4@2280000",
                    "IODeviceMemory": [[{"address": 0x222280000, "length": 0x10000}]]},
                   {"IORegistryEntryName": "atc-phy4@2A90000"},
                   {"IORegistryEntryName": "usb-drd6@0"}]
        self.assertEqual(MODULE.filter_archive(archive, "IOService")["target_count"], 0)
        included = MODULE.filter_archive(archive, "IOService", include_usb=True)
        self.assertEqual(included["target_count"], 2)
        self.assertNotIn("usb-drd6", str(included))
        usb = next(record for record in included["records"] if record["node"].startswith("usb-drd"))
        self.assertEqual(usb["properties"]["IODeviceMemory"],
                         [[{"address": 0x222280000, "length": 0x10000}]])

    def test_invalid_archive_fails(self):
        with self.assertRaises(ValueError):
            MODULE.filter_archive({}, "IOService")
        with self.assertRaises(ValueError):
            MODULE.filter_archive([{"IORegistryEntryName": "Root", "IORegistryEntryChildren": [3]}],
                                  "IODeviceTree")

    def test_only_explicitly_referenced_darts_are_retained(self):
        phandle = b"\x34\x12\x00\x00"
        archive = [{"IORegistryEntryName": "Root", "IORegistryEntryChildren": [
            {"IORegistryEntryName": "usb-drd3", "iommu-parent": phandle + b"\x00" * 4},
            {"IORegistryEntryName": "dart-usb3", "AAPL,phandle": phandle,
             "IODeviceMemory": [{"address": 0x1302F00000, "length": 0x4000}]},
            {"IORegistryEntryName": "dart-unrelated", "AAPL,phandle": b"\x78\x56\x00\x00"}]}]
        result = MODULE.filter_archive(archive, "IOService", include_usb=True)
        self.assertEqual(result["target_count"], 2)
        self.assertNotIn("dart-unrelated", str(result))
        dart = next(record for record in result["records"] if record["node"] == "dart-usb3")
        self.assertEqual(dart["properties"]["IODeviceMemory"][0]["address"], 0x1302F00000)

    def test_malformed_iommu_reference_does_not_create_a_join(self):
        archive = [{"IORegistryEntryName": "usb-drd3", "iommu-parent": b"\x34\x12\x00"},
                   {"IORegistryEntryName": "dart-usb3", "AAPL,phandle": b"\x34\x12\x00\x00"}]
        result = MODULE.filter_archive(archive, "IODeviceTree", include_usb=True)
        self.assertEqual(result["target_count"], 1)

    def test_mapper_reference_retains_its_dart_provider(self):
        phandle = b"\xcd\x01\x00\x00"
        archive = [{"IORegistryEntryName": "usb-drd3", "iommu-parent": phandle},
                   {"IORegistryEntryName": "dart-usb3", "IODeviceMemory": [
                       {"address": 0x1302F00000, "length": 0x4000}],
                    "IORegistryEntryChildren": [{"IORegistryEntryName": "mapper-usb3",
                                                  "AAPL,phandle": phandle, "reg": b"\x01\x00\x00\x00"}]}]
        result = MODULE.filter_archive(archive, "IODeviceTree", include_usb=True)
        self.assertEqual(result["target_count"], 2)
        self.assertEqual(len(result["records"]), 3)
        dart = next(record for record in result["records"] if record["node"] == "dart-usb3")
        self.assertFalse(dart["target"])
        self.assertEqual(dart["properties"]["IODeviceMemory"][0]["address"], 0x1302F00000)


if __name__ == "__main__":
    unittest.main()
