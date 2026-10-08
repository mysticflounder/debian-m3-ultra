"""Offline fixtures for the bounded J575d ACE3 routing collector."""

import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "ace3_routing", ROOT / "scripts/collect-j575d-ace3-routing.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


def entry(name, **properties):
    children = properties.pop("children", [])
    return {"IORegistryEntryName": name, **properties,
            "IORegistryEntryChildren": children}


def hpm(name, dock=b"\x01\x02\x03\x04"):
    return entry(
        name,
        compatible="usbc,sn201202x,spmi",
        interrupts=b"\x0b\x00\x00\x00\x11\x00\x00\x00\x13\x00\x00\x00",
        **{"interrupt-names": b"irq\x00select\x00sleep\x00wake\x00",
           "spmi-parent": b"\xeb\x01\x00\x00", "dock": dock,
           "reset-gpios": b"\x2a\x00\x00\x00", "hpm-class-type": 10,
           "port-number": b"\x01\x00\x00\x00"})


def full_archive():
    docks = entry("port-usb-c-1", **{"AAPL,phandle": b"\x01\x02\x03\x04",
                                    "port-number": b"\x01\x00\x00\x00"})
    bank0 = entry("nub-spmi-a0@A1188000",
                  children=[hpm("hpm0@C"), hpm("hpm1@A", b"\x05\x06\x07\x08"),
                            hpm("hpm2@8", b"\x09\x0a\x0b\x0c"),
                            hpm("hpm3@6", b"\x0d\x0e\x0f\x10")])
    bank2 = entry("nub-spmi-a2@A11A8000",
                  children=[hpm("hpm4@C", b"\x11\x12\x13\x14"),
                            hpm("hpm5@A", b"\x15\x16\x17\x18")])
    return entry("Root", children=[entry("arm-io", children=[bank0, bank2]), docks])


def records(result, prefix=None):
    rows = result["records"]
    return [row for row in rows if prefix is None or row["node"].startswith(prefix)]


class Ace3RoutingFilterTests(unittest.TestCase):
    def test_six_bank_bound_hpm_providers_are_selected(self):
        result = MODULE.filter_archive(full_archive(), "IODeviceTree")
        self.assertEqual({row["node"] for row in records(result, "hpm")},
                         {f"hpm{i}@{suffix}" for i, suffix in
                          enumerate(("C", "A", "8", "6", "C", "A"))})
        self.assertNotIn("hpm6", str(result))

    def test_valid_io_name_aliases_select_bank_and_hpm(self):
        archive = {"IORegistryEntryName": "provider", "IOName": "nub-spmi-a2",
                   "IORegistryEntryChildren": [
                       {"IORegistryEntryName": "device", "IONameMatched": "hpm4@C"}]}
        result = MODULE.filter_archive(archive, "IOService")
        self.assertIn("hpm4", str(result))
        self.assertEqual(result["target_count"], 2)

    def test_unrelated_hpm_unknown_bank_and_invalid_index_are_excluded(self):
        archive = entry("Root", children=[
            entry("nub-spmi-a1@0", children=[hpm("hpm0@C")]),
            entry("hpm0@C"), entry("nub-spmi-a0@0", children=[entry("hpm6@C")])])
        result = MODULE.filter_archive(archive, "IODeviceTree")
        self.assertEqual(records(result, "hpm"), [])
        self.assertNotIn("nub-spmi-a1", str(result))

    def test_real_direct_apple_service_is_retained_but_downstream_is_not(self):
        service = entry("AppleACE3", IOClass="AppleACE3",
                        PrivateValue="do-not-retain",
                        children=[entry("AppleDownstream", IOClass="AppleDownstream",
                                        Secret="do-not-retain"),
                                  entry("CustomDevice", IOClass="CustomDevice")])
        archive = entry("nub-spmi-a0", children=[entry("hpm0@C", children=[service])])
        result = MODULE.filter_archive(archive, "IOService")
        names = {row["node"] for row in result["records"]}
        self.assertIn("AppleACE3", names)
        self.assertNotIn("AppleDownstream", names)
        self.assertNotIn("CustomDevice", names)
        self.assertNotIn("do-not-retain", str(result))
        service_row = next(row for row in result["records"] if row["node"] == "AppleACE3")
        self.assertEqual(service_row["properties"]["IOClass"], "AppleACE3")

    def test_explicit_dock_phandle_join_retains_only_matching_provider(self):
        archive = full_archive()
        archive["IORegistryEntryChildren"].append(
            entry("wrong-dock", **{"AAPL,phandle": b"\xff\xff\xff\xff"}))
        result = MODULE.filter_archive(archive, "IODeviceTree")
        names = {row["node"] for row in result["records"]}
        self.assertIn("port-usb-c-1", names)
        self.assertNotIn("wrong-dock", names)
        dock = next(row for row in result["records"] if row["node"] == "port-usb-c-1")
        self.assertEqual(dock["properties"]["AAPL,phandle"]["hex"], "01020304")
        self.assertEqual(dock["properties"]["AAPL,phandle"]["byte_length"], 4)
        self.assertIn("sha256", dock["properties"]["AAPL,phandle"])

    def test_public_irq_spmi_dock_reset_fields_keep_bytes_and_hashes(self):
        result = MODULE.filter_archive(full_archive(), "IODeviceTree")
        row = next(row for row in result["records"] if row["node"] == "hpm0@C")
        for key in ("interrupt-names", "spmi-parent", "dock", "reset-gpios"):
            value = row["properties"][key]
            self.assertIn("hex", value)
            self.assertIn("byte_length", value)
            self.assertIn("sha256", value)

    def test_dictionary_and_list_roots_are_supported(self):
        archive = {"IORegistryEntryName": "nub-spmi-a0", "IORegistryEntryChildren": [hpm("hpm0@C")]}
        self.assertEqual(MODULE.filter_archive(archive, "IODeviceTree")["target_count"], 2)
        self.assertEqual(MODULE.filter_archive([archive], "IODeviceTree")["target_count"], 2)

    def test_bad_children_raise_value_error(self):
        with self.assertRaises(ValueError):
            MODULE.filter_archive({"IORegistryEntryName": "Root",
                                   "IORegistryEntryChildren": [3]}, "IODeviceTree")
        with self.assertRaises(ValueError):
            MODULE.filter_archive({"IORegistryEntryName": "Root",
                                   "IORegistryEntryChildren": "bad"}, "IODeviceTree")


if __name__ == "__main__":
    unittest.main()
