#!/usr/bin/env python3
"""Host-only regression tests for the opt-in ATCPHY Fabric channel.

The tests patch fresh copies of the retained Linux source and binding, then
compile small C fixtures made from the resulting source functions.  No kernel
build, MMIO, ioremap, firmware, or hardware access is performed.
"""

from __future__ import annotations

import hashlib
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRATCH = ROOT / "scratch" / "j575d-phy-fabric-tests-2026-10-08"
SOURCE = ROOT / "scratch/j575d-usb-drivers.6s0L0J/source"
PATCH = ROOT / "patches/linux/j575d-602042bf/0004-apple-atcphy-m3-fabric-calibration.patch"
ATC = "drivers/phy/apple/atc.c"
BINDING = "Documentation/devicetree/bindings/phy/apple,atcphy.yaml"
SOURCE_SHA = "1b9517fd9b79e1c5fb0be4cd56d8c1443b78d08a138e56c09ca7321505f51eae"
PATCH_SHA = "30a6398b2c7bf568b7b02db75e40fb2f8f1bcbf1d935353fb0a54acb9649f038"
PATCHED_ATC_SHA = "90261b5d057777e3e93bd20b4deea1595535a6b00663caf863139dc273bb3895"
PATCHED_BINDING_SHA = "c4bcbb44a00b6888d8817b98d61b80e094a775b10b9f5c5e1576d1e84ce9050e"
RESOURCE_NAMES = ("core", "lpdptx", "axi2af", "usb2phy", "pipehandler")


def digest(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def function_source(text: str, name: str) -> str:
    """Extract one complete C function by brace balance from patched source."""
    match = re.search(r"(?m)^(?:static\s+)?[A-Za-z_][\w\s\*]*?\s*" +
                      re.escape(name) + r"\s*\(", text)
    if not match:
        raise AssertionError(f"missing source function {name}")
    opening = text.find("{", match.end())
    if opening < 0:
        raise AssertionError(f"missing opening brace {name}")
    depth = 0
    in_string: str | None = None
    escaped = False
    for index in range(opening, len(text)):
        char = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == in_string:
                in_string = None
            continue
        if char in ('"', "'"):
            in_string = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[match.start():index + 1]
    raise AssertionError(f"unterminated function {name}")


def compile_run(run_dir: pathlib.Path, source: str) -> str:
    compile_dir = pathlib.Path(tempfile.mkdtemp(prefix="compile-", dir=run_dir))
    c_file = compile_dir / "fixture.c"
    binary = compile_dir / "fixture"
    c_file.write_text(source, encoding="utf-8")
    subprocess.run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
                    "-O0", str(c_file), "-o", str(binary)],
                   check=True, capture_output=True, text=True)
    result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
    return result.stdout


def apply_prefix(source: str) -> str:
    function = function_source(source, "atcphy_apply_tunables")
    marker = "\n\tswitch (mode)"
    end = function.find(marker)
    if end < 0:
        raise AssertionError("apply function has no mode switch")
    return function[:end] + "\n}"


class FabricSourceTests(unittest.TestCase):
    run_dir: pathlib.Path
    source_root: pathlib.Path
    atc_text: str
    binding_text: str

    @classmethod
    def setUpClass(cls) -> None:
        SCRATCH.mkdir(parents=True, exist_ok=True)
        if digest(SOURCE / ATC) != SOURCE_SHA:
            raise AssertionError("frozen atc.c source hash changed")
        if digest(PATCH) != PATCH_SHA:
            raise AssertionError("Fabric patch hash changed")
        cls.run_dir = pathlib.Path(tempfile.mkdtemp(prefix="run-", dir=SCRATCH))
        cls.source_root = cls.run_dir / "source"
        (cls.source_root / "drivers/phy/apple").mkdir(parents=True)
        (cls.source_root / "Documentation/devicetree/bindings/phy").mkdir(parents=True)
        shutil.copyfile(SOURCE / ATC, cls.source_root / ATC)
        shutil.copyfile(SOURCE / BINDING, cls.source_root / BINDING)
        subprocess.run(["patch", "--batch", "--forward", "--fuzz=0", "-p0"],
                       cwd=cls.source_root, input=PATCH.read_bytes(), check=True,
                       capture_output=True)
        cls.atc_text = (cls.source_root / ATC).read_text(encoding="utf-8")
        cls.binding_text = (cls.source_root / BINDING).read_text(encoding="utf-8")
        if digest(cls.source_root / ATC) != PATCHED_ATC_SHA:
            raise AssertionError("patched atc.c receipt changed")
        if digest(cls.source_root / BINDING) != PATCHED_BINDING_SHA:
            raise AssertionError("patched binding receipt changed")

    def test_fresh_patch_and_receipts(self) -> None:
        self.assertEqual(digest(SOURCE / ATC), SOURCE_SHA)
        self.assertEqual(digest(PATCH), PATCH_SHA)
        self.assertEqual(digest(self.source_root / ATC), PATCHED_ATC_SHA)
        self.assertEqual(digest(self.source_root / BINDING), PATCHED_BINDING_SHA)

    def test_match_data_and_probe_validation_order(self) -> None:
        self.assertIn('.fabric_tunables = false', self.atc_text)
        self.assertIn('.fabric_tunables = true', self.atc_text)
        self.assertRegex(self.atc_text, r'\.compatible = "apple,t6031-atcphy"')
        probe = function_source(self.atc_text, "atcphy_probe")
        self.assertLess(probe.index("atcphy_validate_fabric"),
                        probe.index("atcphy_map_resources"))
        validate = function_source(self.atc_text, "atcphy_validate_fabric")
        self.assertIn("property != resource", validate)
        self.assertIn("fabric_tunables", validate)
        self.assertIn("fabric_prop->length < 3 * sizeof(u32)", validate)
        mapping = function_source(self.atc_text, "atcphy_map_resources")
        self.assertLess(mapping.index("for (int i = 0; i < ARRAY_SIZE(resources); i++)"),
                        mapping.index("if (atcphy->fabric_enabled)"))
        self.assertIn('platform_get_resource_byname(pdev, IORESOURCE_MEM, "fabric")', mapping)
        configure = function_source(self.atc_text, "atcphy_configure")
        self.assertIn("lockdep_assert_held(&atcphy->lock)", configure)
        self.assertLess(configure.index("lockdep_assert_held"),
                        configure.index("atcphy_apply_tunables"))

    def test_apply_source_fixture_preserves_optional_order_and_values(self) -> None:
        prefix = apply_prefix(self.atc_text)
        fixture = r'''
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdint.h>
#include <errno.h>
#include <stdlib.h>
struct apple_tunable { int id; };
enum atcphy_mode { APPLE_ATCPHY_MODE_OFF };
struct apple_atcphy {
    struct { struct apple_tunable *common[2], *axi2af, *fabric;
             struct apple_tunable *lane_usb3[2], *lane_dp[2], *lane_usb4[2]; } tunables;
    struct { void *core, *axi2af, *fabric, *usb2phy, *pipehandler, *lpdptx; } regs;
    bool swap_lanes;
};
static int seen[8]; static void *seen_regs[8]; static int nseen;
static void apple_tunable_apply(void *regs, struct apple_tunable *t) {
    if (!t || nseen >= 8) exit(2); seen[nseen] = t->id; seen_regs[nseen++] = regs;
}
''' + r'''
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-variable"
#pragma clang diagnostic ignored "-Wunused-parameter"
''' + prefix + r'''
#pragma clang diagnostic pop
static int run(int fabric) {
    struct apple_tunable t[5] = {{1},{2},{3},{4},{5}};
    struct apple_atcphy a = {0};
    a.tunables.common[0] = &t[0]; a.tunables.axi2af = &t[1];
    a.tunables.common[1] = &t[2]; a.tunables.fabric = fabric ? &t[3] : NULL;
    a.regs.core = (void*)0x10; a.regs.axi2af = (void*)0x20; a.regs.fabric = (void*)0x30;
    nseen = 0; atcphy_apply_tunables(&a, APPLE_ATCPHY_MODE_OFF);
    if (nseen != (fabric ? 4 : 3)) return 10;
    if (seen[0] != 1 || seen[1] != 2 || seen[2] != (fabric ? 4 : 3) ||
        (fabric && seen[3] != 3)) return 11;
    if (seen_regs[0] != (void*)0x10 || seen_regs[1] != (void*)0x20) return 12;
    if (fabric && seen_regs[2] != (void*)0x30) return 13;
    return 0;
}
int main(void) { return run(0) || run(1); }
'''
        compile_run(self.run_dir, fixture)

    def test_validate_source_fixture_rejects_partial_and_non_m3_pairs(self) -> None:
        function = function_source(self.atc_text, "atcphy_validate_fabric")
        fixture = r'''
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <errno.h>
#define IORESOURCE_MEM 1
typedef uint32_t u32;
struct property { unsigned int length; };
struct device_node { const struct property *property; };
struct resource { int present; };
struct platform_device { struct resource *fabric; };
struct atcphy_hw { bool fabric_tunables; };
struct apple_atcphy { struct device_node *np; void *dev; const struct atcphy_hw *hw; bool fabric_enabled; };
static struct resource *platform_get_resource_byname(struct platform_device *p, int t, const char *n) { (void)t; (void)n; return p->fabric; }
static const struct property *of_find_property(struct device_node *n, const char *name, int *len) { (void)name; (void)len; return n->property; }
#define dev_err(...) ((void)0)
''' + function + r'''
static int check(struct atcphy_hw *hw, int resource, int prop, unsigned length, int want) {
    struct property p = {length}; struct device_node n = {prop ? &p : NULL};
    struct resource r = {resource}; struct platform_device pd = {resource ? &r : NULL};
    struct apple_atcphy a = {.np = &n, .hw = hw}; int got = atcphy_validate_fabric(&pd, &a);
    if (got != want) return 1; if (want == 0 && resource && prop && !a.fabric_enabled) return 2;
    if (want != 0 && a.fabric_enabled) return 3; return 0;
}
int main(void) {
    struct atcphy_hw m3 = {true}, old = {false};
    if (check(&m3, 0, 0, 0, 0) || check(&m3, 1, 1, 12, 0)) return 10;
    if (check(&m3, 1, 0, 0, -EINVAL) || check(&m3, 0, 1, 12, -EINVAL)) return 11;
    if (check(&m3, 1, 1, 0, -EINVAL) || check(&old, 1, 1, 12, -EINVAL)) return 12;
    if (check(&old, 0, 0, 0, 0)) return 13; return 0;
}
'''
        compile_run(self.run_dir, fixture)

    def test_tunable_parser_source_fixture_preserves_be_values_and_bounds(self) -> None:
        source = (SOURCE / "drivers/soc/apple/tunable.c").read_text(encoding="utf-8")
        function = function_source(source, "devm_apple_tunable_parse")
        fixture = r'''
#include <stdint.h>
#include <stddef.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
typedef uint32_t u32; typedef uint32_t __be32; typedef unsigned char u8;
struct device {}; struct resource { size_t start, end; };
struct property { unsigned int length; const u8 *data; };
struct device_node { const struct property *property; };
struct apple_tunable { size_t sz; struct { u32 offset, mask, value; } values[]; };
#define GFP_KERNEL 0
#define struct_size(p, m, n) (sizeof(*(p)) + (n) * sizeof((p)->values[0]))
#define ERR_PTR(x) ((struct apple_tunable *)(intptr_t)(x))
#define resource_size(r) ((r)->end - (r)->start + 1)
static void *devm_kzalloc(struct device *d, size_t n, int f) { (void)d; (void)f; return calloc(1, n); }
static struct property *of_find_property(struct device_node *n, const char *name, int *len) { (void)name; (void)len; return (struct property *)n->property; }
static const u32 *of_prop_next_u32(const struct property *p, const u32 *prev, u32 *out) {
    size_t i = prev ? (size_t)(prev - (const u32 *)p->data) + 1 : 0;
    if ((i + 1) * 4 > p->length) return NULL;
    const u8 *b = p->data + i * 4; *out = ((u32)b[0] << 24) | ((u32)b[1] << 16) | ((u32)b[2] << 8) | b[3];
    return (const u32 *)(p->data + i * 4);
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
''' + function + r'''
#pragma clang diagnostic pop
static int run(const u8 *data, unsigned len, size_t size, int expected) {
    struct property p = {len, data}; struct device_node n = {&p}; struct resource r = {0, size - 1}; struct device d;
    struct apple_tunable *t = devm_apple_tunable_parse(&d, &n, "x", &r);
    int bad = ((intptr_t)t < 0); if (bad != expected) return 1;
    if (!bad && (t->sz != 1 || t->values[0].offset != 0x10 || t->values[0].mask != 0xaabbccdd || t->values[0].value != 0x11223344)) return 2;
    if (!bad) free(t); return 0;
}
int main(void) {
    const u8 valid[12] = {0,0,0,0x10, 0xaa,0xbb,0xcc,0xdd, 0x11,0x22,0x33,0x44};
    const u8 unaligned[12] = {0,0,0,2, 0,0,0,0, 0,0,0,0};
    const u8 over[12] = {0,0,0,0x20, 0,0,0,0, 0,0,0,0};
    if (run(valid, 12, 0x20, 0) || run(unaligned, 12, 0x20, 1) || run(over, 12, 0x20, 1)) return 10;
    if (run(valid, 13, 0x20, 1)) return 11; return 0;
}
'''
        compile_run(self.run_dir, fixture)

    def test_binding_shape_and_opt_in_matrix(self) -> None:
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML unavailable; dtschema not installed")
        document = yaml.safe_load(self.binding_text)
        self.assertEqual(document["properties"]["reg-names"]["items"][5]["const"], "fabric")
        self.assertEqual(document["properties"]["reg"]["minItems"], 5)
        for name in ("reg", "reg-names"):
            self.assertNotIn("maxItems", document["properties"][name])
            self.assertEqual(len(document["properties"][name]["items"]), 6)
        fabric = document["properties"]["apple,tunable-fabric"]
        self.assertNotIn("minItems", fabric)
        self.assertNotIn("maxItems", fabric)
        self.assertEqual(document["$defs"]["apple,tunable"]["$ref"],
                         "/schemas/types.yaml#/definitions/uint32-matrix")
        self.assertEqual(fabric["$ref"], "#/$defs/apple,tunable")
        self.assertEqual(tuple(document["properties"]["reg-names"]["items"][i]["const"]
                               for i in range(5)), RESOURCE_NAMES)
        # Host-side contract matrix for the conditional schema branch.
        def accepted(compat, reg_count, names, has_fabric):
            m3 = compat == "apple,t6031-atcphy" or compat == ["apple,t6031-atcphy", "apple,t8122-atcphy"]
            legacy = reg_count == 5 and tuple(names) == RESOURCE_NAMES and not has_fabric
            opt_in = (m3 and reg_count == 6 and tuple(names) == RESOURCE_NAMES + ("fabric",)
                      and has_fabric)
            m3_legacy = m3 and legacy
            return legacy or m3_legacy or opt_in
        self.assertTrue(accepted("apple,t8103-atcphy", 5, RESOURCE_NAMES, False))
        self.assertTrue(accepted(["apple,t6031-atcphy", "apple,t8122-atcphy"], 5, RESOURCE_NAMES, False))
        self.assertTrue(accepted(["apple,t6031-atcphy", "apple,t8122-atcphy"], 6,
                                 RESOURCE_NAMES + ("fabric",), True))
        self.assertFalse(accepted(["apple,t8122-atcphy", "apple,t6031-atcphy"], 6,
                                  RESOURCE_NAMES + ("fabric",), True))
        self.assertFalse(accepted("apple,t8122-atcphy", 6, RESOURCE_NAMES + ("fabric",), True))
        self.assertFalse(accepted(["apple,t6031-atcphy", "apple,t8122-atcphy"], 6,
                                  RESOURCE_NAMES + ("fabric",), False))
        self.assertFalse(accepted("apple,t8103-atcphy", 5, RESOURCE_NAMES, True))


if __name__ == "__main__":
    unittest.main(verbosity=2)
