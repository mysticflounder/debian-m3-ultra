#!/usr/bin/env python3
"""Source-extracted host regression for the T6031 USB2 event resource.

The fixture compiles the actual helper, resource-map, and USB2 power-on
functions from a zero-fuzz application of patch 0008 to the pinned Linux
source.  It does not model the algorithm independently.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE_SOURCE = ROOT / "scratch/j575d-phy-usb-common.W3594q/source"
PATCH = ROOT / "patches/linux/j575d-602042bf/0008-apple-atcphy-m3-usb2-event-resource.patch"
BASE_ATC_SHA = "2425dbcb0bf6a59f5302db50abc7a33dee0847faf3e4564454e93cb22bc4487b"
PATCH_SHA = "ab9ae8a827707dc0fa26fe2ce20fc7155d92dc03b08f6f0ce43be95d39ea172b"
BINDING = "Documentation/devicetree/bindings/phy/apple,atcphy.yaml"
BASE_BINDING_SHA = "0c4f50c8cdc62ff44ea8a991139769a011681968518dc0bf8919411d26f086ca"


def sha(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def extract_function(source: str, name: str) -> str:
    marker = source.index(name)
    brace = source.index("{", marker)
    start = source.rfind("static", 0, marker)
    depth = 0
    end = None
    for pos in range(brace, len(source)):
        if source[pos] == "{":
            depth += 1
        elif source[pos] == "}":
            depth -= 1
            if depth == 0:
                end = pos + 1
                break
    if end is None or start < 0:
        raise AssertionError(f"cannot extract {name}")
    return source[start:end]


def extract_struct(source: str, name: str) -> str:
    marker = source.index(f"struct {name} {{")
    brace = source.index("{", marker)
    depth = 0
    for pos in range(brace, len(source)):
        if source[pos] == "{":
            depth += 1
        elif source[pos] == "}":
            depth -= 1
            if depth == 0:
                return source[marker:source.index(";", pos) + 1]
    raise AssertionError(f"cannot extract struct {name}")


def source_macros(source: str) -> str:
    wanted = (
        "ATCPHY_EVT_USB2_CTL", "USB2PHY_USBCTL", "USB2PHY_CTL",
        "USB2PHY_SIG", "USB2PHY_MISCTUNE", "ACIOPHY_LANE_MODE_T",
        "ACIOPHY_CROSSBAR_T",
    )
    lines = ["#define BIT(n) (1u << (n))"]
    for line in source.splitlines():
        if line.startswith("#define ") and any(f"#define {name}" in line for name in wanted):
            lines.append(line)
    lines += [
        "enum atcphy_generation { ATCPHY_GENERATION_T8103, ATCPHY_GENERATION_T8122 };",
    ]
    return "\n".join(lines)


def prepare_source(out: pathlib.Path) -> tuple[pathlib.Path, bool]:
    if sha(BASE_SOURCE / "drivers/phy/apple/atc.c") != BASE_ATC_SHA:
        raise AssertionError("pinned baseline atc.c changed")
    if sha(PATCH) != PATCH_SHA:
        raise AssertionError("0008 event patch changed")
    if sha(BASE_SOURCE / BINDING) != BASE_BINDING_SHA:
        raise AssertionError("pinned baseline binding changed")
    patched = out / f"source-{os.getpid()}"
    target_dir = patched / "drivers/phy/apple"
    target_dir.mkdir(parents=True)
    shutil.copy2(BASE_SOURCE / "drivers/phy/apple/atc.c", target_dir / "atc.c")
    (patched / BINDING).parent.mkdir(parents=True)
    shutil.copy2(BASE_SOURCE / BINDING, patched / BINDING)
    run = subprocess.run(
        ["patch", "--batch", "--forward", "--fuzz=0", "-p0", "-i", str(PATCH)],
        cwd=patched, capture_output=True, text=True,
    )
    if run.returncode:
        raise AssertionError(f"zero-fuzz patch failed: {run.stderr[-600:]}")
    target = patched / "drivers/phy/apple/atc.c"
    return target, False


def build_fixture(source_path: pathlib.Path, output: pathlib.Path,
                  baseline_path: pathlib.Path, mutant: str | None = None) -> pathlib.Path:
    source = source_path.read_text()
    if mutant == "core-target":
        needle = "set32(atcphy->regs.usb2_event + ATCPHY_EVT_USB2_CTL,"
        source = source.replace(needle, "set32(atcphy->regs.core + ATCPHY_EVT_USB2_CTL,", 1)
        if source == source_path.read_text():
            raise AssertionError("core-target mutation did not apply")
    elif mutant == "fallback":
        needle = "if (!res || resource_size(res) < ATCPHY_EVT_USB2_CTL + sizeof(u32))"
        replacement = (
            "if (!res || resource_size(res) < ATCPHY_EVT_USB2_CTL + sizeof(u32)) {\n"
            "\t\tatcphy->regs.usb2_event = atcphy->regs.core;\n"
            "\t\treturn 0;\n\t\t} else if (0)"
        )
        source = source.replace(needle, replacement, 1)
        if source == source_path.read_text():
            raise AssertionError("fallback mutation did not apply")
    elif mutant == "t6031-flag":
        needle = "\t.separate_usb2_event = true,"
        source = source.replace(needle, "\t.separate_usb2_event = false,", 1)
        if source == source_path.read_text():
            raise AssertionError("T6031 flag mutation did not apply")

    funcs = {
        name: extract_function(source, name)
        for name in ("mask32", "set32", "clear32", "atcphy_map_resources", "atcphy_usb2_power_on")
    }
    baseline = baseline_path.read_text()
    baseline_power = extract_function(baseline, "atcphy_usb2_power_on")
    baseline_power = baseline_power.replace("atcphy_usb2_power_on", "atcphy_usb2_power_on_baseline", 1)
    baseline_core_mask = extract_function(baseline, "core_mask32")
    baseline_core_set = extract_function(baseline, "core_set32")
    hw_struct = extract_struct(source, "atcphy_hw")
    descriptors = []
    for descriptor in ("atcphy_hw_t8103", "atcphy_hw_t8122", "atcphy_hw_t6031"):
        marker = source.index(f"static const struct atcphy_hw {descriptor}")
        descriptors.append(source[marker:source.index("};", marker) + 2])
    c = f"""
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdlib.h>
#include <stdbool.h>
#define __iomem
typedef uint32_t u32;
typedef unsigned long long resource_size_t;
#define IORESOURCE_MEM 1
#define ARRAY_SIZE(x) ((int)(sizeof(x) / sizeof((x)[0])))
#define ERR_PTR(x) ((void *)(intptr_t)(x))
#define PTR_ERR(x) ((int)(intptr_t)(x))
#define IS_ERR(x) ((intptr_t)(x) < 0 && (intptr_t)(x) > -4096)
{source_macros(source)}

struct device {{ int unused; }};
struct resource {{ const char *name; resource_size_t start, end; void *mapped; int map_error; }};
struct platform_device {{ struct resource *resources; size_t count; struct device dev; }};
{hw_struct}
struct apple_atcphy {{
    struct device *dev; const struct atcphy_hw *hw; int fabric_enabled;
    struct {{ void *core, *axi2af, *fabric, *usb2phy, *usb2_event, *pipehandler, *lpdptx; }} regs;
    struct {{ struct resource *core, *axi2af, *fabric; }} res;
}};

static struct resource *platform_get_resource_byname(struct platform_device *pdev, int type, const char *name) {{
    (void)type;
    for (size_t i = 0; i < pdev->count; ++i)
        if (!strcmp(pdev->resources[i].name, name)) return &pdev->resources[i];
    return NULL;
}}
static resource_size_t resource_size(const struct resource *res) {{ return res->end - res->start + 1; }}
static void *devm_ioremap_resource(struct device *dev, struct resource *res) {{
    (void)dev; if (!res) return ERR_PTR(-EINVAL); if (res->map_error) return ERR_PTR(res->map_error); return res->mapped;
}}
static int dev_err_probe(struct device *dev, int err, const char *msg, ...) {{ (void)dev; (void)msg; return err; }}
static uint32_t *event_words, *core_words, *usb_words;
struct op {{ int bank; unsigned offset; uintptr_t addr; uint32_t before, after; }};
static struct op ops[64]; static size_t op_count; static unsigned delays[64]; static size_t delay_count; static uint32_t *trace_core, *trace_usb, *trace_event; static size_t trace_span = 32;
static uint32_t readl(const volatile void *p) {{ return *(const volatile uint32_t *)p; }}
static int trace_bank(const volatile void *p, unsigned *offset) {{
    const uintptr_t a = (uintptr_t)p;
    if (trace_core && a >= (uintptr_t)trace_core && a < (uintptr_t)(trace_core + trace_span)) {{ *offset = (unsigned)(a - (uintptr_t)trace_core); return 1; }}
    if (trace_usb && a >= (uintptr_t)trace_usb && a < (uintptr_t)(trace_usb + trace_span)) {{ *offset = (unsigned)(a - (uintptr_t)trace_usb); return 2; }}
    if (trace_event && a >= (uintptr_t)trace_event && a < (uintptr_t)(trace_event + trace_span)) {{ *offset = (unsigned)(a - (uintptr_t)trace_event); return 3; }}
    return 0;
}}
static void writel(uint32_t v, volatile void *p) {{
    unsigned offset = 0; int bank = trace_bank(p, &offset);
    if (!bank) {{ fprintf(stderr, "CHECK: write outside mapped fixture banks\\n"); _Exit(1); }}
    uint32_t old = *(volatile uint32_t *)p; *(volatile uint32_t *)p = v;
    if (op_count < ARRAY_SIZE(ops)) ops[op_count++] = (struct op){{bank, offset, (uintptr_t)p, old, v}};
}}
static void udelay(unsigned int us) {{ if (delay_count < ARRAY_SIZE(delays)) delays[delay_count++] = us; }}
{funcs['mask32']}
{funcs['set32']}
{funcs['clear32']}
{baseline_core_mask}
{baseline_core_set}
{funcs['atcphy_map_resources']}
{funcs['atcphy_usb2_power_on']}
{baseline_power}
{chr(10).join(descriptors)}

static void die(const char *msg) {{ fprintf(stderr, "CHECK: %s\\n", msg); _Exit(1); }}
static void check(int ok, const char *msg) {{ if (!ok) die(msg); }}
static struct resource resources[8];
static void setup_resources(int event, int event_size, int event_error) {{
    static const char *names[] = {{"core","lpdptx","axi2af","usb2phy","pipehandler","fabric","usb2-event"}};
    static uint32_t maps[7][32]; memset(resources, 0, sizeof(resources)); memset(maps, 0, sizeof(maps));
    for (size_t i = 0; i < 7; ++i) {{ resources[i].name = names[i]; resources[i].start = 0x100000 + i * 0x10000; resources[i].end = resources[i].start + 0x3fff; resources[i].mapped = maps[i]; }}
    resources[6].end = resources[6].start + (event_size ? event_size : 0x3fff) - 1;
    resources[6].map_error = event_error;
    if (!event) resources[6].name = "not-event";
}}
static void map_case(const char *kind) {{
    struct device dev = {{0}}; struct platform_device pdev = {{resources, 7, dev}};
    const struct atcphy_hw *t6031 = &atcphy_hw_t6031, *t8122 = &atcphy_hw_t8122;
    struct apple_atcphy a = {{.dev=&dev, .hw=t6031}};
    setup_resources(strcmp(kind, "missing") != 0, strcmp(kind, "small") == 0 ? 2 : 0x4000, strcmp(kind, "map-error") == 0 ? -EIO : 0);
    a.fabric_enabled = !strcmp(kind, "fabric");
    if (!strcmp(kind, "core-missing")) resources[0].name = "not-core";
    int rc = atcphy_map_resources(&pdev, &a);
    if (!strcmp(kind, "ok") || !strcmp(kind, "fabric")) {{ check(rc == 0, "T6031 complete mapping failed"); check(a.regs.usb2_event != a.regs.core, "T6031 event aliases core"); if (!strcmp(kind, "fabric")) check(a.regs.fabric != NULL, "fabric mapping lost"); }}
    else if (!strcmp(kind, "missing") || !strcmp(kind, "small") || !strcmp(kind, "map-error")) check(rc != 0, "T6031 invalid event mapping accepted");
    else if (!strcmp(kind, "core-missing")) check(rc != 0, "missing core mapping accepted");
    else if (!strcmp(kind, "legacy")) {{ a.hw = t8122; setup_resources(0, 0, 0); rc = atcphy_map_resources(&pdev, &a); check(rc == 0, "T8122 legacy mapping failed"); check(a.regs.usb2_event == a.regs.core, "legacy event fallback changed"); }}
}}
static size_t event_ops(int expect_event);
static void map_power_case(void) {{
    struct device dev = {{0}}; struct platform_device pdev = {{resources, 7, dev}};
    struct apple_atcphy a = {{.dev=&dev, .hw=&atcphy_hw_t6031}};
    setup_resources(1, 0x4000, 0);
    check(atcphy_map_resources(&pdev, &a) == 0, "map-to-power T6031 mapping failed");
    trace_core = a.regs.core; trace_usb = a.regs.usb2phy; trace_event = a.regs.usb2_event; trace_span = 32; op_count = 0; delay_count = 0;
    ((uint32_t *)a.regs.core)[0] = 0x11000000; ((uint32_t *)a.regs.usb2_event)[0] = 0xa5a50002;
    atcphy_usb2_power_on(&a);
    event_ops(1);
    check(((uint32_t *)a.regs.usb2_event)[0] == 0xa5a5000b, "mapped T6031 event RMW failed");
}}
static size_t event_ops(int expect_event) {{
    size_t e = 0, c = 0; for (size_t i = 0; i < op_count; ++i) {{ if (ops[i].bank == 3) e++; if (ops[i].bank == 1) c++; }}
    if (expect_event && c) die("T6031 event write targeted core");
    check(expect_event ? e == 1 : e == 0, expect_event ? "T6031 event write missing" : "unexpected event write");
    if (expect_event) check(c == 0, "T6031 event write targeted core");
    return e;
}}
static void power_case(const char *kind) {{
    uint32_t core[32] = {{0}}, event[32] = {{0}}, usb[32] = {{0}}; const struct atcphy_hw *hw = !strcmp(kind, "t8103") ? &atcphy_hw_t8103 : (!strcmp(kind, "t6031") ? &atcphy_hw_t6031 : &atcphy_hw_t8122);
    struct apple_atcphy a = {{.hw=hw}}; core_words=core; event_words=event; usb_words=usb; trace_core=core; trace_usb=usb; trace_event=event; trace_span=32;
    a.regs.core=core; a.regs.usb2_event = !strcmp(kind, "t6031") ? event : core; a.regs.usb2phy=usb;
    core[0] = 0x11000000; event[0] = 0xa5a50002; op_count=0; delay_count=0; atcphy_usb2_power_on(&a);
    event_ops(!strcmp(kind, "t6031"));
    if (!strcmp(kind, "t6031")) check(event[0] == 0xa5a5000b && core[0] == 0x11000000, "T6031 RMW changed wrong bank/bits");
    if (!strcmp(kind, "t8122")) check(core[0] == 0x11000009, "T8122 old core OR9 behavior changed");
    if (!strcmp(kind, "t8103")) check(core[0] == 0x11000000, "T8103 event write appeared");
}}
static void compare_baseline(void) {{
    uint32_t core1[32]={{0}}, usb1[32]={{0}}, core2[32]={{0}}, usb2[32]={{0}};
    struct apple_atcphy a={{.hw=&atcphy_hw_t8122}}, b={{.hw=&atcphy_hw_t8122}}; a.regs.core=core1; a.regs.usb2_event=core1; a.regs.usb2phy=usb1; b.regs.core=core2; b.regs.usb2_event=core2; b.regs.usb2phy=usb2;
    trace_core=core1; trace_usb=usb1; trace_event=core1; trace_span=32; op_count=0; delay_count=0; atcphy_usb2_power_on(&a); size_t n=op_count, d=delay_count; struct op first[64]; unsigned first_delays[64]; memcpy(first,ops,sizeof(first)); memcpy(first_delays,delays,sizeof(first_delays));
    trace_core=core2; trace_usb=usb2; trace_event=core2; trace_span=32; op_count=0; delay_count=0; atcphy_usb2_power_on_baseline(&b); check(op_count==n,"mode write count changed"); check(delay_count==d,"timing delay count changed");
    for(size_t i=0;i<d;i++) check(first_delays[i]==delays[i],"timing delay changed");
    for(size_t i=0;i<n;i++) check(first[i].bank==ops[i].bank && first[i].offset==ops[i].offset && first[i].before==ops[i].before && first[i].after==ops[i].after,"mode/power sequence changed");
}}
int main(int argc, char **argv) {{
    if (argc != 2) return 2;
    if (!strcmp(argv[1], "map-ok") || !strcmp(argv[1], "map-missing") || !strcmp(argv[1], "map-small") || !strcmp(argv[1], "map-error") || !strcmp(argv[1], "map-fabric") || !strcmp(argv[1], "map-core-missing") || !strcmp(argv[1], "map-legacy")) {{ map_case(argv[1]+4); return 0; }}
    if (!strcmp(argv[1], "map-power")) {{ map_power_case(); return 0; }}
    if (!strcmp(argv[1], "power-t6031")) {{ power_case("t6031"); return 0; }}
    if (!strcmp(argv[1], "power-t8122")) {{ power_case("t8122"); return 0; }}
    if (!strcmp(argv[1], "power-t8103")) {{ power_case("t8103"); return 0; }}
    if (!strcmp(argv[1], "compare")) {{ compare_baseline(); return 0; }}
    return 2;
}}
"""
    c_path = output / f"fixture-{mutant or 'normal'}.c"
    bin_path = output / f"fixture-{mutant or 'normal'}"
    c_path.write_text(textwrap.dedent(c))
    compiler = shutil.which("clang") or shutil.which("cc")
    if not compiler:
        raise unittest.SkipTest("clang/cc unavailable")
    flags = [compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined", "-g", str(c_path), "-o", str(bin_path)]
    run = subprocess.run(flags, capture_output=True, text=True)
    if run.returncode:
        raise AssertionError(f"fixture compile failed:\n{run.stderr[-4000:]}")
    return bin_path


class USB2EventTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.out = pathlib.Path(TEST_OUTPUT or tempfile.mkdtemp(prefix="j575d-usb2-event-tests.", dir=ROOT / "scratch"))
        cls.out.mkdir(parents=True, exist_ok=True)
        cls.source, cls.draft_fallback = prepare_source(cls.out)
        cls.baseline_source = BASE_SOURCE / "drivers/phy/apple/atc.c"
        cls.bin = build_fixture(cls.source, cls.out, cls.baseline_source)
        (cls.out / "provenance.txt").write_text(
            f"baseline_atc_sha256={BASE_ATC_SHA}\npatch_0008_sha256={PATCH_SHA}\n"
            f"patched_atc_sha256={sha(cls.source)}\ndraft_fallback={cls.draft_fallback}\n"
        )

    def run_case(self, name):
        return subprocess.run([str(self.bin), name], capture_output=True, text=True)

    def test_t6031_named_event_mapping(self):
        for case in ("map-ok", "map-missing", "map-small", "map-error", "map-fabric"):
            with self.subTest(case=case):
                self.assertEqual(self.run_case(case).returncode, 0)

    def test_legacy_mapping_and_fabric_independence(self):
        self.assertEqual(self.run_case("map-legacy").returncode, 0)
        self.assertEqual(self.run_case("map-core-missing").returncode, 0)

    def test_power_generation_banks_and_rmw(self):
        for case in ("power-t6031", "power-t8122", "power-t8103", "compare", "map-power"):
            with self.subTest(case=case):
                result = self.run_case(case)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_core_target_mutation_is_designated_runtime_failure(self):
        mutant = build_fixture(self.source, self.out, self.baseline_source, "core-target")
        result = subprocess.run([str(mutant), "power-t6031"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("CHECK: T6031 event write targeted core", result.stderr)

    def test_missing_resource_fallback_mutation_is_designated_runtime_failure(self):
        mutant = build_fixture(self.source, self.out, self.baseline_source, "fallback")
        result = subprocess.run([str(mutant), "map-missing"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("CHECK: T6031 invalid event mapping accepted", result.stderr)

    def test_t6031_descriptor_flag_mutation_is_designated_runtime_failure(self):
        mutant = build_fixture(self.source, self.out, self.baseline_source, "t6031-flag")
        result = subprocess.run([str(mutant), "map-ok"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("CHECK: T6031 event aliases core", result.stderr)

    def test_probe_returns_map_error_before_finalize(self):
        source = self.source.read_text()
        mapping = extract_function(source, "atcphy_map_resources")
        probe = extract_function(source, "atcphy_probe(struct platform_device")
        self.assertIn('return dev_err_probe(atcphy->dev, PTR_ERR(addr)', mapping)
        self.assertLess(probe.index("ret = atcphy_map_resources"), probe.index("ret = atcphy_load_tunables"))
        self.assertIn("if (ret)\n\t\treturn ret;\n\tret = atcphy_load_tunables", probe)


TEST_OUTPUT = None


def main() -> int:
    global TEST_OUTPUT
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--output-dir")
    parser.add_argument("--source-dir")
    args, remaining = parser.parse_known_args()
    if args.source_dir:
        global BASE_SOURCE
        BASE_SOURCE = pathlib.Path(args.source_dir)
    TEST_OUTPUT = args.output_dir
    return unittest.main(argv=[sys.argv[0], *remaining], verbosity=2, exit=False).result.wasSuccessful() is False


if __name__ == "__main__":
    raise SystemExit(int(main()))
