#!/usr/bin/env python3
"""Host-only regression tests for the opt-in T6031 USB-common channel.

The tests apply the new patch to fresh copies of the retained Fabric source,
extract the real tuple parser/validation function into small C fixtures, and
exercise the mode/order contract.  They do not build a kernel or touch MMIO,
firmware, hardware, or the pinned receipt inputs.
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
SCRATCH = ROOT / "scratch" / "j575d-usb-common-driver-2026-10-08"
SOURCE = ROOT / "scratch/j575d-phy-fabric.1M5jQC/source"
PATCH = ROOT / "patches/linux/j575d-602042bf/0005-apple-atcphy-m3-usb-common-calibration.patch"
ATC = "drivers/phy/apple/atc.c"
BINDING = "Documentation/devicetree/bindings/phy/apple,atcphy.yaml"
TUNABLE = "drivers/soc/apple/tunable.c"
SOURCE_ATC_SHA = "90261b5d057777e3e93bd20b4deea1595535a6b00663caf863139dc273bb3895"
SOURCE_BINDING_SHA = "c4bcbb44a00b6888d8817b98d61b80e094a775b10b9f5c5e1576d1e84ce9050e"
SOURCE_TUNABLE_SHA = "e2e366e0a4e7f1707ec6c463c8f477604f7ba74254eccbab65d37f3d69a3fae7"
PATCH_SHA = "ab77204e6dadbd78163eb604592aaf683d67c061e826ac0c3f56a5f815606551"
PATCHED_ATC_SHA = "2425dbcb0bf6a59f5302db50abc7a33dee0847faf3e4564454e93cb22bc4487b"
PATCHED_BINDING_SHA = "0c4f50c8cdc62ff44ea8a991139769a011681968518dc0bf8919411d26f086ca"


def digest(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def function_source(text: str, name: str) -> str:
    match = re.search(r"(?m)^(?:static\s+)?[A-Za-z_][\w\s\*]*?\s*" +
                      re.escape(name) + r"\s*\(", text)
    if not match:
        raise AssertionError(f"missing source function {name}")
    opening = text.find("{", match.end())
    if opening < 0:
        raise AssertionError(f"missing opening brace {name}")
    depth = 0
    quote: str | None = None
    escaped = False
    for index in range(opening, len(text)):
        char = text[index]
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char in ('"', "'"):
            quote = char
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


def compile_run_status(run_dir: pathlib.Path, source: str) -> int:
    """Compile a fixture and return its runtime status for mutation witnesses."""
    compile_dir = pathlib.Path(tempfile.mkdtemp(prefix="compile-mutation-", dir=run_dir))
    c_file = compile_dir / "fixture.c"
    binary = compile_dir / "fixture"
    c_file.write_text(source, encoding="utf-8")
    subprocess.run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
                    "-O0", str(c_file), "-o", str(binary)],
                   check=True, capture_output=True, text=True)
    return subprocess.run([str(binary)], check=False, capture_output=True).returncode


class UsbCommonSourceTests(unittest.TestCase):
    run_dir: pathlib.Path
    source_root: pathlib.Path
    atc_text: str
    binding_text: str

    @classmethod
    def setUpClass(cls) -> None:
        SCRATCH.mkdir(parents=True, exist_ok=True)
        if digest(SOURCE / ATC) != SOURCE_ATC_SHA:
            raise AssertionError("frozen Fabric atc.c source hash changed")
        if digest(SOURCE / BINDING) != SOURCE_BINDING_SHA:
            raise AssertionError("frozen Fabric binding hash changed")
        if digest(SOURCE / TUNABLE) != SOURCE_TUNABLE_SHA:
            raise AssertionError("frozen tuple-parser source hash changed")
        if digest(PATCH) != PATCH_SHA:
            raise AssertionError("USB-common patch hash changed")

        cls.run_dir = pathlib.Path(tempfile.mkdtemp(prefix="run-", dir=SCRATCH))
        cls.source_root = cls.run_dir / "source"
        (cls.source_root / "drivers/phy/apple").mkdir(parents=True)
        (cls.source_root / "Documentation/devicetree/bindings/phy").mkdir(parents=True)
        shutil.copyfile(SOURCE / ATC, cls.source_root / ATC)
        shutil.copyfile(SOURCE / BINDING, cls.source_root / BINDING)
        subprocess.run(["patch", "--batch", "--forward", "--fuzz=0", "-p0"],
                       cwd=cls.source_root, input=PATCH.read_bytes(), check=True,
                       capture_output=True, text=False)
        cls.atc_text = (cls.source_root / ATC).read_text(encoding="utf-8")
        cls.binding_text = (cls.source_root / BINDING).read_text(encoding="utf-8")

    def test_fresh_patch_and_receipts(self) -> None:
        self.assertEqual(digest(SOURCE / ATC), SOURCE_ATC_SHA)
        self.assertEqual(digest(SOURCE / BINDING), SOURCE_BINDING_SHA)
        self.assertEqual(digest(PATCH), PATCH_SHA)
        self.assertEqual(digest(self.source_root / ATC), PATCHED_ATC_SHA)
        self.assertEqual(digest(self.source_root / BINDING), PATCHED_BINDING_SHA)

    def test_source_gates_capability_and_applies_before_lanes(self) -> None:
        self.assertIn("bool usb_common_tunables;", self.atc_text)
        self.assertIn(".usb_common_tunables = true", self.atc_text)
        self.assertEqual(self.atc_text.count(".usb_common_tunables = false"), 2)
        validate = function_source(self.atc_text, "atcphy_validate_usb_common")
        self.assertIn("!usb_common_prop->length", validate)
        self.assertIn("% (3 * sizeof(u32))", validate)
        self.assertIn("usb_common_tunables", validate)
        probe = function_source(self.atc_text, "atcphy_probe")
        self.assertLess(probe.index("atcphy_validate_usb_common"),
                        probe.index("atcphy_map_resources"))
        apply = function_source(self.atc_text, "atcphy_apply_tunables")
        self.assertLess(apply.index("common[1]"), apply.index("usb_common"))
        self.assertLess(apply.index("usb_common"), apply.index("switch"))
        self.assertIn("APPLE_ATCPHY_MODE_USB3 || mode == APPLE_ATCPHY_MODE_USB3_DP", apply)

    def test_mode_order_and_gating_fixture(self) -> None:
        function = function_source(self.atc_text, "atcphy_apply_tunables")
        prefix = r'''
#include <stdbool.h>
#include <stddef.h>
enum atcphy_mode {
    APPLE_ATCPHY_MODE_OFF, APPLE_ATCPHY_MODE_USB2, APPLE_ATCPHY_MODE_USB3,
    APPLE_ATCPHY_MODE_USB3_DP, APPLE_ATCPHY_MODE_TBT, APPLE_ATCPHY_MODE_USB4,
    APPLE_ATCPHY_MODE_DP,
};
struct apple_tunable { int id; };
struct apple_atcphy {
    struct {
        struct apple_tunable *axi2af, *common[2], *lane_usb3[2], *lane_dp[2];
        struct apple_tunable *lane_usb4[2], *fabric, *usb_common;
    } tunables;
    bool swap_lanes;
    struct { void *core, *axi2af, *fabric; } regs;
};
struct call { int base, id; };
static struct call calls[16]; static size_t call_count;
static int core_reg, axi2af_reg, fabric_reg;
static int base_id(void *base) {
    if (base == &core_reg) return 1;
    if (base == &axi2af_reg) return 2;
    if (base == &fabric_reg) return 3;
    return -1;
}
static void apple_tunable_apply(void *base, struct apple_tunable *tunable) {
    if (!tunable) return;
    if (call_count < sizeof(calls) / sizeof(calls[0]))
        calls[call_count++] = (struct call){base_id(base), tunable->id};
}
'''
        suffix = r'''
static int expect(enum atcphy_mode mode, bool usb, bool fabric, bool swap) {
    struct call want[16]; size_t n = 0;
    want[n++] = (struct call){1, 10}; want[n++] = (struct call){2, 11};
    if (fabric) want[n++] = (struct call){3, 12};
    want[n++] = (struct call){1, 13};
    if (usb && (mode == APPLE_ATCPHY_MODE_USB3 || mode == APPLE_ATCPHY_MODE_USB3_DP))
        want[n++] = (struct call){1, 14};
    switch (mode) {
    case APPLE_ATCPHY_MODE_USB3:
    case APPLE_ATCPHY_MODE_USB3_DP:
        want[n++] = (struct call){1, swap ? 21 : 20};
        want[n++] = (struct call){1, swap ? 30 : 31};
        break;
    case APPLE_ATCPHY_MODE_DP:
        want[n++] = (struct call){1, swap ? 31 : 30};
        want[n++] = (struct call){1, swap ? 30 : 31};
        break;
    case APPLE_ATCPHY_MODE_TBT:
    case APPLE_ATCPHY_MODE_USB4:
        want[n++] = (struct call){1, swap ? 41 : 40};
        want[n++] = (struct call){1, swap ? 40 : 41};
        break;
    case APPLE_ATCPHY_MODE_OFF:
    case APPLE_ATCPHY_MODE_USB2:
        break;
    }
    if (call_count != n) return 1;
    for (size_t i = 0; i < n; ++i)
        if (calls[i].base != want[i].base || calls[i].id != want[i].id) return 2;
    return 0;
}
static int run_case(enum atcphy_mode mode, bool usb, bool fabric, bool swap) {
    struct apple_tunable t[32]; struct apple_atcphy a = {0};
    for (int i = 0; i < 32; ++i) t[i].id = i + 10;
    a.tunables.common[0] = &t[0]; a.tunables.axi2af = &t[1];
    a.tunables.fabric = fabric ? &t[2] : NULL; a.tunables.common[1] = &t[3];
    a.tunables.usb_common = usb ? &t[4] : NULL;
    a.tunables.lane_usb3[0] = &t[10]; a.tunables.lane_usb3[1] = &t[11];
    a.tunables.lane_dp[0] = &t[20]; a.tunables.lane_dp[1] = &t[21];
    a.tunables.lane_usb4[0] = &t[30]; a.tunables.lane_usb4[1] = &t[31];
    a.swap_lanes = swap; a.regs.core = &core_reg; a.regs.axi2af = &axi2af_reg;
    a.regs.fabric = &fabric_reg; call_count = 0;
    atcphy_apply_tunables(&a, mode);
    return expect(mode, usb, fabric, swap);
}
int main(void) {
    for (int mode = APPLE_ATCPHY_MODE_OFF; mode <= APPLE_ATCPHY_MODE_DP; ++mode)
        for (int usb = 0; usb <= 1; ++usb)
            for (int fabric = 0; fabric <= 1; ++fabric)
                for (int swap = 0; swap <= 1; ++swap)
                    if (run_case((enum atcphy_mode)mode, usb, fabric, swap)) return 1;
    return 0;
}
'''
        fixture = prefix + function + suffix
        self.assertEqual(compile_run(self.run_dir, fixture), "")

        # This source mutation compiles, but the complete witness must fail:
        # removing the mode gate would apply USB-common to every mode.
        mutated = re.sub(
            r"if \(atcphy->tunables\.usb_common &&\n\s+\(mode == APPLE_ATCPHY_MODE_USB3 \|\| mode == APPLE_ATCPHY_MODE_USB3_DP\)\)",
            "if (atcphy->tunables.usb_common)", function, count=1)
        self.assertNotEqual(mutated, function)
        self.assertEqual(compile_run_status(self.run_dir, prefix + mutated + suffix), 1)

    def test_source_extracted_validation_fixture(self) -> None:
        function = function_source(self.atc_text, "atcphy_validate_usb_common")
        fixture = r'''
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <errno.h>
typedef uint32_t u32;
struct device {}; struct property { unsigned int length; };
struct device_node { const struct property *property; };
struct atcphy_hw { bool usb_common_tunables; };
struct apple_atcphy { struct device *dev; struct device_node *np; const struct atcphy_hw *hw; bool usb_common_enabled; };
static const struct property *of_find_property(struct device_node *n, const char *name, int *len) { (void)name; (void)len; return n->property; }
#define dev_err(...) do {} while (0)
''' + function + r'''
static int check(const struct atcphy_hw *hw, int present, unsigned length, int want, int enabled) {
    struct property p = {length}; struct device_node n = {present ? &p : NULL};
    struct apple_atcphy a = {.np = &n, .hw = hw};
    int got = atcphy_validate_usb_common(&a);
    return got != want || (int)a.usb_common_enabled != enabled;
}
int main(void) {
    const struct atcphy_hw m3 = {true}, old = {false};
    if (check(&m3, 0, 0, 0, 0) || check(&m3, 1, 12, 0, 1)) return 1;
    if (check(&m3, 1, 0, -EINVAL, 0) || check(&m3, 1, 8, -EINVAL, 0)) return 2;
    if (check(&old, 1, 12, -EINVAL, 0)) return 3;
    return 0;
}
'''
        self.assertEqual(compile_run(self.run_dir, fixture), "")

    def test_source_extracted_tuple_parser_be_and_bounds_fixture(self) -> None:
        source = (SOURCE / TUNABLE).read_text(encoding="utf-8")
        function = function_source(source, "devm_apple_tunable_parse")
        fixture = r'''
#include <stdint.h>
#include <stddef.h>
#include <errno.h>
#include <stdlib.h>
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
static void putbe(u8 *p, u32 value) {
    p[0] = (u8)(value >> 24); p[1] = (u8)(value >> 16);
    p[2] = (u8)(value >> 8); p[3] = (u8)value;
}
static int run_many(void) {
    u8 data[65 * 12]; struct property p; struct device_node n;
    struct resource r = {0, 0x3ff}; struct device d;
    for (size_t i = 0; i < 65; ++i) {
        putbe(data + i * 12, (u32)(i * 4));
        putbe(data + i * 12 + 4, 0xffffffff); putbe(data + i * 12 + 8, (u32)i);
    }
    p = (struct property){sizeof(data), data}; n = (struct device_node){&p};
    struct apple_tunable *t = devm_apple_tunable_parse(&d, &n, "x", &r);
    int bad = ((intptr_t)t < 0);
    if (bad || t->sz != 65 || t->values[64].offset != 256) return 1;
    free(t); return 0;
}
int main(void) {
    const u8 valid[12] = {0,0,0,0x10, 0xaa,0xbb,0xcc,0xdd, 0x11,0x22,0x33,0x44};
    const u8 unaligned[12] = {0,0,0,2, 0,0,0,0, 0,0,0,0};
    const u8 over[12] = {0,0,0,0x20, 0,0,0,0, 0,0,0,0};
    if (run(valid, 12, 0x20, 0) || run(unaligned, 12, 0x20, 1) || run(over, 12, 0x20, 1)) return 10;
    if (run(valid, 8, 0x20, 1) || run_many()) return 11; return 0;
}
'''
        self.assertEqual(compile_run(self.run_dir, fixture), "")

    def test_binding_declares_optional_t6031_only_matrix(self) -> None:
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML unavailable; schema validation is a separate lane")
        document = yaml.safe_load(self.binding_text)
        usb = document["properties"]["apple,tunable-usb-common"]
        self.assertEqual(usb["$ref"], "#/$defs/apple,tunable")
        self.assertNotIn("minItems", usb)
        self.assertNotIn("maxItems", usb)
        self.assertEqual(document["$defs"]["apple,tunable"]["$ref"],
                         "/schemas/types.yaml#/definitions/uint32-matrix")
        non_t6031 = document["allOf"][2]["then"]["properties"]
        self.assertIs(non_t6031["apple,tunable-usb-common"], False)


if __name__ == "__main__":
    unittest.main(verbosity=2)
