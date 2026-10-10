#!/usr/bin/env python3
"""Source-extracted regression for the M3 USBCTL upper-bit preservation.

The C fixture compiles the real helper and power-on function after applying
0008 and 0009 with zero fuzz.  It does not reimplement the register algorithm.
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
PATCH8 = ROOT / "patches/linux/j575d-602042bf/0008-apple-atcphy-m3-usb2-event-resource.patch"
PATCH9 = ROOT / "patches/linux/j575d-602042bf/0009-apple-atcphy-m3-usbctl-preserve.patch"
BASE_ATC_SHA = "2425dbcb0bf6a59f5302db50abc7a33dee0847faf3e4564454e93cb22bc4487b"
PATCH8_SHA = "ab9ae8a827707dc0fa26fe2ce20fc7155d92dc03b08f6f0ce43be95d39ea172b"
PATCH9_SHA = "774b6a9be65962094bee2ae04c70729d24889339437a886b00d90bbbc32715bf"
BINDING = "Documentation/devicetree/bindings/phy/apple,atcphy.yaml"
BASE_BINDING_SHA = "0c4f50c8cdc62ff44ea8a991139769a011681968518dc0bf8919411d26f086ca"


def sha(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def extract_function(source: str, name: str) -> str:
    marker = source.index(name)
    brace = source.index("{", marker)
    start = source.rfind("static", 0, marker)
    depth = 0
    for pos in range(brace, len(source)):
        if source[pos] == "{":
            depth += 1
        elif source[pos] == "}":
            depth -= 1
            if depth == 0:
                return source[start:pos + 1]
    raise AssertionError(f"cannot extract {name}")


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
    return "\n".join(lines)


def prepare_source(out: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
    if sha(BASE_SOURCE / "drivers/phy/apple/atc.c") != BASE_ATC_SHA:
        raise AssertionError("pinned baseline atc.c changed or input is prepatched")
    if sha(PATCH8) != PATCH8_SHA or sha(PATCH9) != PATCH9_SHA:
        raise AssertionError("follow-up patch pin changed")
    if sha(BASE_SOURCE / BINDING) != BASE_BINDING_SHA:
        raise AssertionError("pinned baseline binding changed")
    patched = out / f"source-{os.getpid()}"
    (patched / "drivers/phy/apple").mkdir(parents=True)
    (patched / BINDING).parent.mkdir(parents=True)
    shutil.copy2(BASE_SOURCE / "drivers/phy/apple/atc.c", patched / "drivers/phy/apple/atc.c")
    shutil.copy2(BASE_SOURCE / BINDING, patched / BINDING)
    run = subprocess.run(
        ["patch", "--batch", "--forward", "--fuzz=0", "-p0", "-i", str(PATCH8)],
        cwd=patched, capture_output=True, text=True,
    )
    if run.returncode:
        raise AssertionError(f"zero-fuzz patch failed for {PATCH8.name}: {run.stderr[-800:]}")
    after8 = out / "source-after0008-atc.c"
    shutil.copy2(patched / "drivers/phy/apple/atc.c", after8)
    run = subprocess.run(
        ["patch", "--batch", "--forward", "--fuzz=0", "-p0", "-i", str(PATCH9)],
        cwd=patched, capture_output=True, text=True,
    )
    if run.returncode:
        raise AssertionError(f"zero-fuzz patch failed for {PATCH9.name}: {run.stderr[-800:]}")
    return patched / "drivers/phy/apple/atc.c", after8


def build_fixture(source_path: pathlib.Path, output: pathlib.Path,
                  baseline_path: pathlib.Path, mutant: bool = False) -> pathlib.Path:
    source = source_path.read_text()
    if mutant:
        old = """if (atcphy->hw->preserve_usbctl_upper)\n\t\tmask32(atcphy->regs.usb2phy + USB2PHY_USBCTL,\n\t\t       USB2PHY_USBCTL_USB_MODE, USB2PHY_USBCTL_RUN);\n\telse\n\t\twritel(USB2PHY_USBCTL_RUN, atcphy->regs.usb2phy + USB2PHY_USBCTL);"""
        source = source.replace(old, "writel(USB2PHY_USBCTL_RUN, atcphy->regs.usb2phy + USB2PHY_USBCTL);", 1)
        if source == source_path.read_text():
            raise AssertionError("USBCTL mutation did not apply")
    funcs = {name: extract_function(source, name) for name in
             ("mask32", "set32", "clear32", "atcphy_usb2_power_on")}
    baseline = baseline_path.read_text()
    baseline_power = extract_function(baseline, "atcphy_usb2_power_on").replace(
        "atcphy_usb2_power_on", "atcphy_usb2_power_on_baseline", 1)
    hw_struct = extract_struct(source, "atcphy_hw")
    descriptors = []
    for name in ("atcphy_hw_t8103", "atcphy_hw_t8122", "atcphy_hw_t6031"):
        marker = source.index(f"static const struct atcphy_hw {name}")
        descriptors.append(source[marker:source.index("};", marker) + 2])
    c = f"""
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <stdlib.h>
#define __iomem
typedef uint32_t u32;
{source_macros(source)}
enum atcphy_generation {{ ATCPHY_GENERATION_T8103, ATCPHY_GENERATION_T8122 }};
{hw_struct}
struct apple_atcphy {{
    const struct atcphy_hw *hw;
    struct {{ void *core, *axi2af, *fabric, *usb2phy, *usb2_event, *pipehandler, *lpdptx; }} regs;
}};
struct op {{ int bank; unsigned offset; uint32_t before, after; }};
struct step {{ char kind; struct op op; unsigned delay; }};
static struct op ops[128]; static size_t op_count;
static unsigned delays[64]; static size_t delay_count;
static struct step steps[256]; static size_t step_count;
static uint32_t *trace_core, *trace_usb, *trace_event; static size_t trace_span = 64;
static int trace_bank(const volatile void *p, unsigned *offset) {{
    uintptr_t a = (uintptr_t)p;
    if (trace_core && a >= (uintptr_t)trace_core && a < (uintptr_t)(trace_core + trace_span)) {{ *offset = (unsigned)(a - (uintptr_t)trace_core); return 1; }}
    if (trace_usb && a >= (uintptr_t)trace_usb && a < (uintptr_t)(trace_usb + trace_span)) {{ *offset = (unsigned)(a - (uintptr_t)trace_usb); return 2; }}
    if (trace_event && a >= (uintptr_t)trace_event && a < (uintptr_t)(trace_event + trace_span)) {{ *offset = (unsigned)(a - (uintptr_t)trace_event); return 3; }}
    return 0;
}}
static uint32_t readl(const volatile void *p) {{ return *(const volatile uint32_t *)p; }}
static void writel(uint32_t value, volatile void *p) {{
    unsigned offset = 0; int bank = trace_bank(p, &offset);
    if (!bank) {{ fprintf(stderr, "CHECK: write outside fixture banks\\n"); _Exit(1); }}
    uint32_t before = *(volatile uint32_t *)p; *(volatile uint32_t *)p = value;
    if (op_count < 128) ops[op_count++] = (struct op){{bank, offset, before, value}};
    if (step_count < 256) steps[step_count++] = (struct step){{'W', {{bank, offset, before, value}}, 0}};
}}
static void udelay(unsigned usec) {{
    if (delay_count < 64) delays[delay_count++] = usec;
    if (step_count < 256) steps[step_count++] = (struct step){{'D', {{0,0,0,0}}, usec}};
}}
{funcs['mask32']}
{funcs['set32']}
{funcs['clear32']}
{funcs['atcphy_usb2_power_on']}
{baseline_power}
{chr(10).join(descriptors)}
static void die(const char *msg) {{ fprintf(stderr, "CHECK: %s\\n", msg); _Exit(1); }}
static void check(int ok, const char *msg) {{ if (!ok) die(msg); }}
static void reset_trace(uint32_t *core, uint32_t *usb, uint32_t *event) {{
    trace_core=core; trace_usb=usb; trace_event=event; op_count=0; delay_count=0; step_count=0;
}}
static void run_m3_case(uint32_t initial) {{
    uint32_t core[64]={{0}}, usb[64]={{0}}, event[64]={{0}}; struct apple_atcphy a={{.hw=&atcphy_hw_t6031}};
    a.regs.core=core; a.regs.usb2phy=usb; a.regs.usb2_event=event; usb[0]=initial; reset_trace(core,usb,event);
    atcphy_usb2_power_on(&a);
    check(usb[0] == ((initial & ~7u) | 2u), "M3 upper USBCTL bits were lost");
    check(event[0] == 0x00000009, "M3 event operation changed");
    check(delay_count == 6, "M3 delay count changed");
    for (size_t i=0;i<delay_count;i++) check(delays[i] == 10, "M3 delay value changed");
}}
static void run_m3(void) {{ run_m3_case(0xa5a50007); run_m3_case(0); }}
static void compare_legacy(const struct atcphy_hw *hw) {{
    uint32_t c1[64]={{0}},u1[64]={{0}},e1[64]={{0}},c2[64]={{0}},u2[64]={{0}},e2[64]={{0}};
    struct apple_atcphy a={{.hw=hw}}, b={{.hw=hw}}; a.regs.core=c1;a.regs.usb2phy=u1;a.regs.usb2_event=c1;
    b.regs.core=c2;b.regs.usb2phy=u2;b.regs.usb2_event=c2; u1[0]=u2[0]=0xa5a50007;
    reset_trace(c1,u1,e1); atcphy_usb2_power_on(&a); size_t n=op_count,d=delay_count; struct op first[128]; unsigned ds[64]; memcpy(first,ops,sizeof(first)); memcpy(ds,delays,sizeof(ds));
    reset_trace(c2,u2,e2); atcphy_usb2_power_on_baseline(&b); check(op_count==n,"legacy operation count changed"); check(delay_count==d,"legacy delay count changed");
    for(size_t i=0;i<d;i++) check(delays[i]==ds[i],"legacy delay sequence changed");
    for(size_t i=0;i<n;i++) {{ if (!(ops[i].bank==first[i].bank && ops[i].offset==first[i].offset && ops[i].before==first[i].before && ops[i].after==first[i].after)) {{ fprintf(stderr,"TRACE legacy i=%zu new=%d/%u %08x->%08x old=%d/%u %08x->%08x\\n",i,ops[i].bank,ops[i].offset,ops[i].before,ops[i].after,first[i].bank,first[i].offset,first[i].before,first[i].after); die("legacy operation changed"); }} }}
    check(u1[0]==2 && u2[0]==2,"legacy USBCTL whole write changed");
}}
static void compare_m3_order(void) {{
    uint32_t c1[64]={{0}},u1[64]={{0}},e1[64]={{0}},c2[64]={{0}},u2[64]={{0}},e2[64]={{0}};
    struct apple_atcphy a={{.hw=&atcphy_hw_t6031}}, b={{.hw=&atcphy_hw_t6031}}; a.regs.core=c1;a.regs.usb2phy=u1;a.regs.usb2_event=e1;
    b.regs.core=c2;b.regs.usb2phy=u2;b.regs.usb2_event=e2; u1[0]=u2[0]=0xa5a50007;
    reset_trace(c1,u1,e1); atcphy_usb2_power_on(&a); size_t sn=step_count; struct step first[256]; memcpy(first,steps,sizeof(first));
    reset_trace(c2,u2,e2); atcphy_usb2_power_on_baseline(&b); check(step_count==sn,"M3 unified trace length changed");
    check(sn > 0 && first[sn-1].kind=='W' && first[sn-1].op.bank==2 && first[sn-1].op.offset==0,"M3 final write is not USBCTL");
    check(steps[sn-1].kind=='W' && steps[sn-1].op.bank==2 && steps[sn-1].op.offset==0,"baseline final write is not USBCTL");
    for(size_t i=0;i+1<sn;i++) {{
        check(first[i].kind==steps[i].kind,"M3 write/delay interleave changed");
        if (first[i].kind=='D') check(first[i].delay==steps[i].delay,"M3 delay value changed against baseline");
        else {{ if (!(first[i].op.bank==steps[i].op.bank && first[i].op.offset==steps[i].op.offset && first[i].op.before==steps[i].op.before && first[i].op.after==steps[i].op.after)) {{ fprintf(stderr,"TRACE m3 i=%zu new=%d/%u %08x->%08x old=%d/%u %08x->%08x\\n",i,first[i].op.bank,first[i].op.offset,first[i].op.before,first[i].op.after,steps[i].op.bank,steps[i].op.offset,steps[i].op.before,steps[i].op.after); die("M3 pre-USBCTL operation changed"); }} }}
    }}
    check(u1[0] == 0xa5a50002 && u2[0] == 2,"M3/native USBCTL results changed");
}}
int main(int argc, char **argv) {{
    if (argc != 2) return 2;
    if (!strcmp(argv[1], "m3")) run_m3();
    else if (!strcmp(argv[1], "legacy-t8103")) compare_legacy(&atcphy_hw_t8103);
    else if (!strcmp(argv[1], "legacy-t8122")) compare_legacy(&atcphy_hw_t8122);
    else if (!strcmp(argv[1], "m3-order")) compare_m3_order();
    else return 2;
    return 0;
}}
"""
    c_path = output / f"fixture-{'mutant' if mutant else 'normal'}.c"
    bin_path = output / f"fixture-{'mutant' if mutant else 'normal'}"
    c_path.write_text(textwrap.dedent(c))
    compiler = shutil.which("clang") or shutil.which("cc")
    if not compiler:
        raise unittest.SkipTest("clang/cc unavailable")
    run = subprocess.run([compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
                          "-fsanitize=address,undefined", "-g", str(c_path), "-o", str(bin_path)],
                         capture_output=True, text=True)
    if run.returncode:
        raise AssertionError(f"fixture compile failed:\n{run.stderr[-4000:]}")
    return bin_path


TEST_OUTPUT = None


class USBCTLTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.out = pathlib.Path(TEST_OUTPUT or tempfile.mkdtemp(prefix="j575d-usbctl.", dir=ROOT / "scratch"))
        cls.out.mkdir(parents=True, exist_ok=True)
        cls.source, cls.baseline = prepare_source(cls.out)
        cls.bin = build_fixture(cls.source, cls.out, cls.baseline)
        (cls.out / "provenance.txt").write_text(
            f"baseline_atc_sha256={BASE_ATC_SHA}\npatch_0008_sha256={PATCH8_SHA}\n"
            f"patch_0009_sha256={PATCH9_SHA}\npatched_atc_sha256={sha(cls.source)}\n"
        )

    def run_case(self, case, binary=None):
        return subprocess.run([str(binary or self.bin), case], capture_output=True, text=True)

    def test_m3_preserves_upper_bits_and_mode(self):
        result = self.run_case("m3")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_descriptor_flag_is_m3_only(self):
        source = self.source.read_text()
        t6031 = source[source.index("static const struct atcphy_hw atcphy_hw_t6031"):]
        t8122 = source[source.index("static const struct atcphy_hw atcphy_hw_t8122"):source.index("static const struct atcphy_hw atcphy_hw_t6031")]
        self.assertIn(".preserve_usbctl_upper = true", t6031.split("};", 1)[0])
        self.assertNotIn("preserve_usbctl_upper", t8122.split("};", 1)[0])

    def test_role_power_off_mapping_and_helpers_unchanged(self):
        source = self.source.read_text()
        baseline = self.baseline.read_text()
        for name in ("atcphy_usb2_set_mode", "atcphy_usb2_power_off",
                     "atcphy_map_resources", "mask32", "set32", "clear32"):
            with self.subTest(function=name):
                self.assertEqual(extract_function(source, name),
                                 extract_function(baseline, name))

    def test_legacy_whole_word_and_sequence_unchanged(self):
        for case in ("legacy-t8103", "legacy-t8122", "m3-order"):
            with self.subTest(case=case):
                result = self.run_case(case)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_removing_m3_rmw_is_designated_runtime_failure(self):
        mutant = build_fixture(self.source, self.out, self.baseline, mutant=True)
        result = self.run_case("m3", mutant)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("CHECK: M3 upper USBCTL bits were lost", result.stderr)


def main() -> int:
    global TEST_OUTPUT, BASE_SOURCE
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--source-dir")
    parser.add_argument("--output-dir")
    args, remaining = parser.parse_known_args()
    if args.source_dir:
        BASE_SOURCE = pathlib.Path(args.source_dir)
    TEST_OUTPUT = args.output_dir
    result = unittest.main(argv=[sys.argv[0], *remaining], verbosity=2, exit=False).result
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
