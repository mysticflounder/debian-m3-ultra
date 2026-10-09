#!/usr/bin/env python3
"""Offline binding/DTB matrix for the optional ACE3 select-polling path."""

from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORK = ROOT / "scratch/j575d-typec-polling-proto-2026-10-09"
SOURCE = ROOT / "scratch/j575d-phy-usb-common.W3594q/source"
PATCH_BINDINGS = ROOT / "patches/linux/j575d-602042bf/0004-apple-spmi-and-ace3-bindings.patch"
PATCH = ROOT / "patches/linux/j575d-602042bf/0006-typec-tipd-experimental-select-polling.patch"
CACHE = ROOT / "scratch/j575d-schema-validation-2026-10-07/uv-cache"
LOG_ROOT = ROOT / "scratch/j575d-typec-polling-binding-tests-2026-10-09"
UV = ["uv", "run", "--offline", "--no-project", "--with", "dtschema==2026.9"]


def run(cmd: list[str], cwd: pathlib.Path | None = None,
        input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["UV_CACHE_DIR"] = str(CACHE)
    return subprocess.run(cmd, cwd=cwd, env=env, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          input=input_text, check=False)


def dts_for(case: str) -> str:
    polling = case.startswith("poll-")
    flag = "            apple,experimental-select-polling;\n" if polling else ""
    if case == "poll-valid":
        names = '"irq", "sleep", "wake"'
        ints = "<1 1>, <2 1>, <3 1>"
    elif case == "legacy-valid":
        names = '"irq", "select", "sleep", "wake"'
        ints = "<1 1>, <2 1>, <3 1>, <4 1>"
    elif case == "legacy-three":
        names = '"irq", "sleep", "wake"'
        ints = "<1 1>, <2 1>, <3 1>"
    elif case == "poll-four":
        names = '"irq", "select", "sleep", "wake"'
        ints = "<1 1>, <2 1>, <3 1>, <4 1>"
    elif case == "poll-wrong-order":
        names = '"irq", "select", "wake"'
        ints = "<1 1>, <2 1>, <3 1>"
    elif case == "poll-missing-names":
        names = None
        ints = "<1 1>, <2 1>, <3 1>"
    elif case == "poll-zero-entries":
        names = '"irq", "sleep", "wake"'
        ints = "__omit__"
    elif case == "poll-empty-property":
        names = '"irq", "sleep", "wake"'
        ints = None
    elif case == "poll-extra-entry":
        names = '"irq", "sleep", "wake"'
        ints = "<1 1>, <2 1>, <3 1>, <4 1>"
    elif case == "poll-malformed-bool":
        names = '"irq", "sleep", "wake"'
        ints = "<1 1>, <2 1>, <3 1>"
        flag = "            apple,experimental-select-polling = <1>;\n"
    else:
        raise ValueError(case)

    interrupt_prop = "" if ints == "__omit__" else (
        "            interrupts;\n" if ints is None else f"            interrupts = {ints};\n")
    names_prop = "" if names is None else f"            interrupt-names = {names};\n"
    return f"""/dts-v1/;

/ {{
    #address-cells = <1>;
    #size-cells = <1>;

    intc: interrupt-controller@0 {{
        compatible = "test,interrupt-controller";
        interrupt-controller;
        #interrupt-cells = <2>;
    }};

    spmi {{
        #address-cells = <2>;
        #size-cells = <0>;

        usb-pd@c {{
            compatible = "apple,sn201202x";
            reg = <0xc 0x1>;
            interrupt-parent = <&intc>;
{flag}{interrupt_prop}{names_prop}        }};
    }};
}};
"""


class SelectPollingBindingTests(unittest.TestCase):
    schema_arg: pathlib.Path | None = None
    output_arg: pathlib.Path | None = None

    @classmethod
    def setUpClass(cls) -> None:
        if cls.output_arg:
            cls.run_dir = cls.output_arg.resolve()
            cls.run_dir.mkdir(parents=True, exist_ok=True)
        else:
            LOG_ROOT.mkdir(parents=True, exist_ok=True)
            cls.run_dir = pathlib.Path(tempfile.mkdtemp(prefix="run-", dir=LOG_ROOT))

        if cls.schema_arg:
            cls.schema = cls.schema_arg.resolve()
            cls.binding_root = cls.schema.parents[1]
        else:
            cls.tree = cls.run_dir / "tree"
            (cls.tree / "Documentation/devicetree/bindings/spmi").mkdir(parents=True)
            (cls.tree / "Documentation/devicetree/bindings/connector").mkdir(parents=True)
            (cls.tree / "drivers/usb/typec/tipd").mkdir(parents=True)
            shutil.copyfile(SOURCE / "Documentation/devicetree/bindings/spmi/apple,spmi.yaml",
                            cls.tree / "Documentation/devicetree/bindings/spmi/apple,spmi.yaml")
            shutil.copyfile(SOURCE / "Documentation/devicetree/bindings/connector/usb-connector.yaml",
                            cls.tree / "Documentation/devicetree/bindings/connector/usb-connector.yaml")
            for rel in ("drivers/usb/typec/tipd/spmi.c", "drivers/usb/typec/tipd/tps6598x.h"):
                shutil.copyfile(SOURCE / rel, cls.tree / rel)
            logs = []
            for series_patch in (PATCH_BINDINGS, PATCH):
                applied = run(["patch", "--batch", "--forward", "--fuzz=0", "-p0"],
                              cls.tree, series_patch.read_text(encoding="utf-8"))
                logs.append(f"{series_patch.name}:\n{applied.stdout}")
                if applied.returncode:
                    raise AssertionError(applied.stdout)
            (cls.run_dir / "patch.log").write_text("\n".join(logs), encoding="utf-8")
            cls.schema = cls.tree / "Documentation/devicetree/bindings/usb/apple,sn201202x.yaml"
            cls.binding_root = cls.tree / "Documentation/devicetree/bindings"

        print(f"validation logs: {cls.run_dir}")
        docs = run(UV + ["dt-doc-validate", "-u", str(cls.binding_root), str(cls.schema)])
        (cls.run_dir / "dt-doc-validate.log").write_text(docs.stdout, encoding="utf-8")
        if docs.returncode or docs.stdout.strip():
            raise AssertionError(docs.stdout)

    def validate_case(self, case: str) -> tuple[bool, str, bool, bool]:
        case_dir = self.run_dir / case
        case_dir.mkdir()
        dts = case_dir / f"{case}.dts"
        dtb = case_dir / f"{case}.dtb"
        dts.write_text(dts_for(case), encoding="utf-8")
        compiled = run(["dtc", "-Wno-unit_address_vs_reg", "-I", "dts", "-O", "dtb",
                        "-o", str(dtb), str(dts)])
        output = compiled.stdout
        if compiled.returncode:
            return False, output, False, False
        checked = run(UV + ["dt-validate", "-l", "apple,sn201202x", "-s", str(self.schema), str(dtb)])
        output += checked.stdout
        (case_dir / "validate.log").write_text(output, encoding="utf-8")
        targeted = "from schema $id: http://devicetree.org/schemas/usb/apple,sn201202x.yaml" in output
        if checked.returncode and "Traceback" in output:
            return False, output, True, False
        return checked.returncode == 0 and not targeted, output, True, targeted

    def compile_empty_interrupt_property(self) -> str:
        case = "poll-empty-property"
        case_dir = self.run_dir / case
        case_dir.mkdir()
        dts = case_dir / f"{case}.dts"
        dtb = case_dir / f"{case}.dtb"
        dts.write_text(dts_for(case), encoding="utf-8")
        compiled = run(["dtc", "-Wno-unit_address_vs_reg", "-I", "dts", "-O", "dtb",
                        "-o", str(dtb), str(dts)])
        (case_dir / "compile.log").write_text(compiled.stdout, encoding="utf-8")
        self.assertEqual(compiled.returncode, 0, compiled.stdout)
        return str(dtb)

    def test_fixture_matrix(self) -> None:
        expected_valid = ("legacy-valid", "poll-valid")
        expected_invalid = ("legacy-three", "poll-four", "poll-wrong-order",
                            "poll-missing-names", "poll-zero-entries",
                            "poll-extra-entry", "poll-malformed-bool")
        self.compile_empty_interrupt_property()
        for case in expected_valid:
            valid, output, compiled, targeted = self.validate_case(case)
            self.assertTrue(compiled, f"{case} did not compile:\n{output}")
            self.assertFalse(targeted, f"{case} emitted a targeted diagnostic:\n{output}")
            self.assertTrue(valid, f"{case} unexpectedly failed:\n{output}")
        for case in expected_invalid:
            valid, output, compiled, targeted = self.validate_case(case)
            self.assertTrue(compiled, f"{case} did not compile:\n{output}")
            self.assertTrue(targeted, f"{case} lacked an apple,sn201202x diagnostic:\n{output}")
            self.assertFalse(valid, f"{case} produced no diagnostic:\n{output}")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--schema", type=pathlib.Path,
                        help="already-patched apple,sn201202x.yaml")
    parser.add_argument("--output-dir", type=pathlib.Path,
                        help="deterministic directory for fixtures and logs")
    options, unittest_args = parser.parse_known_args()
    SelectPollingBindingTests.schema_arg = options.schema
    SelectPollingBindingTests.output_arg = options.output_dir
    unittest.main(argv=[sys.argv[0], *unittest_args])
