#!/usr/bin/env python3
"""Source-extracted regression for the experimental M3 USB2 role signals.

The fixture compiles the real atc.c helpers after applying 0010 with zero fuzz.
It models register accesses only; it is not a hardware or role-semantics claim.
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "scratch/j575d-usbctl.w3QGd5/source"
PATCH = ROOT / "patches/linux/j575d-602042bf/0010-apple-atcphy-m3-usb2-role-signals.patch"
BASE_SHA = "d8b745b09b34542553f7c86e3280fcbffaefcbefc435bde23129a16a1fdc331c"
PATCH_SHA = "e3d5a74e63a3a573aa3b93c6d7372b1ff1371dfb53006feb94518a10c977c3b8"


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
    wanted = ("USB2PHY_", "ATCPHY_EVT_USB2_CTL")
    lines = ["#define BIT(n) (1u << (n))"]
    for line in source.splitlines():
        if line.startswith("#define ") and any(name in line for name in wanted):
            lines.append(line)
    return "\n".join(lines)


def prepare_source(out: pathlib.Path, source_dir: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
    original = source_dir / "drivers/phy/apple/atc.c"
    if sha(original) != BASE_SHA:
        raise AssertionError("source is not the pinned combined 0008+0009 input")
    if sha(PATCH) != PATCH_SHA:
        raise AssertionError("0010 patch pin changed")
    root = out / "patched-source"
    target = root / "drivers/phy/apple"
    target.mkdir(parents=True)
    shutil.copy2(original, target / "atc.c")
    run = subprocess.run(
        ["patch", "--batch", "--forward", "--fuzz=0", "-p0", "-i", str(PATCH)],
        cwd=root, capture_output=True, text=True,
    )
    if run.returncode:
        raise AssertionError(f"zero-fuzz 0010 application failed: {run.stderr[-1000:]}")
    return target / "atc.c", original


def build_fixture(source_path: pathlib.Path, baseline_path: pathlib.Path,
                  out: pathlib.Path, mutation: str = "") -> pathlib.Path:
    source = source_path.read_text()
    baseline = baseline_path.read_text()
    if mutation == "host-clear-c":
        old = "set32(atcphy->regs.usb2phy + USB2PHY_SIG, USB2PHY_SIG_HOST);"
        new = "mask32(atcphy->regs.usb2phy + USB2PHY_SIG, USB2PHY_SIG_M3_DEVICE, USB2PHY_SIG_HOST);"
        source = source.replace(old, new, 1)
    elif mutation == "power-unconditional-orf":
        source = source.replace(
            "atcphy->hw->m3_role_signals ? USB2PHY_SIG_M3_POWER_ON :",
            "false ? USB2PHY_SIG_M3_POWER_ON :", 1)
    elif mutation == "device-omit-c":
        source = source.replace("if (atcphy->hw->m3_role_signals)", "if (false)", 1)
    if mutation and source == source_path.read_text():
        raise AssertionError(f"mutation did not apply: {mutation}")

    funcs = {name: extract_function(source, name) for name in (
        "mask32", "set32", "clear32", "atcphy_usb2_power_on", "atcphy_usb2_set_mode",
    )}
    old_funcs = {
        name: extract_function(baseline, name).replace(name, f"{name}_baseline", 1)
        for name in ("atcphy_usb2_power_on", "atcphy_usb2_set_mode")
    }
    hw_struct = extract_struct(source, "atcphy_hw")
    descriptors = []
    for name in ("atcphy_hw_t8103", "atcphy_hw_t8122", "atcphy_hw_t6031"):
        marker = source.index(f"static const struct atcphy_hw {name}")
        descriptors.append(source[marker:source.index("};", marker) + 2])

    c = f"""
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define __iomem
#define EINVAL 22
#define guard(x) if (0) (void)
typedef uint32_t u32;
{source_macros(source)}
enum phy_mode {{ PHY_MODE_USB_HOST = 1, PHY_MODE_USB_DEVICE = 2 }};
enum atcphy_generation {{ ATCPHY_GENERATION_T8103, ATCPHY_GENERATION_T8122 }};
#define ACIOPHY_LANE_MODE_T8103 0
#define ACIOPHY_CROSSBAR_T8103 0
#define ACIOPHY_LANE_MODE_T8122 0
#define ACIOPHY_CROSSBAR_T8122 0
struct mutex {{ int unused; }};
{hw_struct}
struct apple_atcphy {{
    const struct atcphy_hw *hw;
    struct {{ void *core, *axi2af, *fabric, *usb2phy, *usb2_event, *pipehandler, *lpdptx; }} regs;
    struct mutex lock;
}};
struct phy {{ void *drv; }};
static struct apple_atcphy *phy_get_drvdata(struct phy *p) {{ return p->drv; }}
struct op {{ int bank; unsigned offset; uint32_t before, after; }};
struct step {{ char kind; struct op op; unsigned delay; }};
static struct op ops[256]; static size_t op_count;
static struct step steps[512]; static size_t step_count;
static unsigned delays[128]; static size_t delay_count;
static uint32_t *trace_core, *trace_usb, *trace_event; static size_t trace_span = 64;
static int trace_bank(const volatile void *p, unsigned *offset) {{
    uintptr_t a = (uintptr_t)p;
    if (a >= (uintptr_t)trace_core && a < (uintptr_t)(trace_core + trace_span)) {{ *offset = (unsigned)(a - (uintptr_t)trace_core); return 1; }}
    if (a >= (uintptr_t)trace_usb && a < (uintptr_t)(trace_usb + trace_span)) {{ *offset = (unsigned)(a - (uintptr_t)trace_usb); return 2; }}
    if (a >= (uintptr_t)trace_event && a < (uintptr_t)(trace_event + trace_span)) {{ *offset = (unsigned)(a - (uintptr_t)trace_event); return 3; }}
    return 0;
}}
static uint32_t readl(const volatile void *p) {{ return *(const volatile uint32_t *)p; }}
static void writel(uint32_t value, volatile void *p) {{
    unsigned offset = 0; int bank = trace_bank(p, &offset);
    if (!bank) {{ fprintf(stderr, "CHECK: write outside fixture banks\\n"); _Exit(1); }}
    uint32_t before = *(volatile uint32_t *)p; *(volatile uint32_t *)p = value;
    ops[op_count++] = (struct op){{bank, offset, before, value}};
    steps[step_count++] = (struct step){{'W', {{bank, offset, before, value}}, 0}};
}}
static void udelay(unsigned usec) {{ delays[delay_count++] = usec; steps[step_count++] = (struct step){{'D', {{0,0,0,0}}, usec}}; }}
{funcs['mask32']}
{funcs['set32']}
{funcs['clear32']}
{funcs['atcphy_usb2_power_on']}
{funcs['atcphy_usb2_set_mode']}
{old_funcs['atcphy_usb2_power_on']}
{old_funcs['atcphy_usb2_set_mode']}
{chr(10).join(descriptors)}
static void die(const char *s) {{ fprintf(stderr, "CHECK: %s\\n", s); _Exit(1); }}
static void check(int ok, const char *s) {{ if (!ok) die(s); }}
static void reset(uint32_t *c, uint32_t *u, uint32_t *e) {{ trace_core=c; trace_usb=u; trace_event=e; op_count=step_count=delay_count=0; }}
static void attach(struct apple_atcphy *a, const struct atcphy_hw *h, uint32_t *c, uint32_t *u, uint32_t *e) {{ a->hw=h; a->regs.core=c; a->regs.usb2phy=u; a->regs.usb2_event=e; }}
static void run_m3_power(void) {{
    for (unsigned low=0; low<16; low++) {{
        uint32_t c[64]={{0}},u[64]={{0}},e[64]={{0}}; struct apple_atcphy a={{0}};
        attach(&a, &atcphy_hw_t6031, c,u,e); u[2]=0xa5a50000u|low; reset(c,u,e); atcphy_usb2_power_on(&a);
        check(u[2] == ((0xa5a50000u|low)|3u), "M3 power-on signal bits changed");
    }}
    {{ uint32_t c[64]={{0}},u[64]={{0}},e[64]={{0}}; struct apple_atcphy a={{0}}; attach(&a,&atcphy_hw_t6031,c,u,e); reset(c,u,e); atcphy_usb2_power_on(&a); check(u[2]==3u,"M3 zero power-on signal changed"); }}
}}
static void run_m3_trace(void) {{
    uint32_t c[64]={{0}},u[64]={{0}},e[64]={{0}},c2[64]={{0}},u2[64]={{0}},e2[64]={{0}}; struct apple_atcphy a={{0}},b={{0}};
    attach(&a,&atcphy_hw_t6031,c,u,e); attach(&b,&atcphy_hw_t6031,c2,u2,e2); u[2]=u2[2]=0xa5a50000u; reset(c,u,e); atcphy_usb2_power_on(&a); size_t n=step_count; struct step x[512]; memcpy(x,steps,sizeof(x)); reset(c2,u2,e2); atcphy_usb2_power_on_baseline(&b); check(step_count==n,"M3 trace length changed");
    check(n>0 && x[0].kind=='W' && x[0].op.bank==2 && x[0].op.offset==8,"M3 first trace write is not SIG"); check(steps[0].kind=='W' && steps[0].op.bank==2 && steps[0].op.offset==8,"baseline first trace write is not SIG"); check(x[0].op.before==steps[0].op.before,"M3 SIG input changed"); check(x[0].op.after==0xa5a50003u && steps[0].op.after==0xa5a5000fu,"M3 trace SIG outputs unexpected");
    for(size_t i=1;i<n;i++) {{ check(x[i].kind==steps[i].kind,"M3 trace operation kind changed"); if(x[i].kind=='D') check(x[i].delay==steps[i].delay,"M3 trace delay changed"); else check(x[i].op.bank==steps[i].op.bank && x[i].op.offset==steps[i].op.offset && x[i].op.before==steps[i].op.before && x[i].op.after==steps[i].op.after,"M3 trace post-SIG write changed"); }}
}}
static void check_mode(struct apple_atcphy *a, struct phy *p, uint32_t *u, int mode, uint32_t expected, const char *msg) {{
    size_t before=op_count; int ret=atcphy_usb2_set_mode(p, mode, 0); check(ret==0,msg); check(u[2]==expected,msg); check(op_count==before+1 || (mode==PHY_MODE_USB_DEVICE && a->hw->m3_role_signals && op_count==before+2),"unexpected mode writes");
}}
static void run_m3_modes(void) {{
    uint32_t c[64]={{0}},u[64]={{0}},e[64]={{0}}; struct apple_atcphy a={{0}}; struct phy p={{.drv=&a}}; attach(&a,&atcphy_hw_t6031,c,u,e);
    u[2]=0xa5a5000cu; reset(c,u,e); check_mode(&a,&p,u,PHY_MODE_USB_HOST,0xa5a5700cu,"M3 host signal bits changed"); check_mode(&a,&p,u,PHY_MODE_USB_DEVICE,0xa5a5000cu,"M3 device signal bits changed"); check_mode(&a,&p,u,PHY_MODE_USB_HOST,0xa5a5700cu,"M3 host-after-device signal bits changed");
    u[2]=0x5a5a0000u; reset(c,u,e); check_mode(&a,&p,u,PHY_MODE_USB_DEVICE,0x5a5a000cu,"M3 device signal bits changed"); check_mode(&a,&p,u,PHY_MODE_USB_HOST,0x5a5a700cu,"M3 host-after-device signal bits changed"); check_mode(&a,&p,u,PHY_MODE_USB_DEVICE,0x5a5a000cu,"M3 device signal bits changed");
    for (unsigned low=0; low<16; low++) for (unsigned variant=0; variant<2; variant++) {{
        uint32_t seed=(variant ? 0x5a5a7000u : 0xa5a50000u)|low; uint32_t c1[64],u1[64],e1[64],c2[64],u2[64],e2[64];
        for(size_t i=0;i<64;i++) {{ c1[i]=c2[i]=0x11000000u+(uint32_t)i; u1[i]=u2[i]=0x22000000u+(uint32_t)i; e1[i]=e2[i]=0x33000000u+(uint32_t)i; }} u1[2]=u2[2]=seed;
        struct apple_atcphy x={{0}},y={{0}}; struct phy px={{0}},py={{0}}; attach(&x,&atcphy_hw_t6031,c1,u1,e1); attach(&y,&atcphy_hw_t6031,c2,u2,e2); px.drv=&x; py.drv=&y;
        reset(c1,u1,e1); check_mode(&x,&px,u1,PHY_MODE_USB_HOST,seed|USB2PHY_SIG_HOST,"M3 host signal bits changed"); check_mode(&x,&px,u1,PHY_MODE_USB_DEVICE,(seed&~USB2PHY_SIG_HOST)|USB2PHY_SIG_M3_DEVICE,"M3 device signal bits changed");
        for(size_t i=0;i<64;i++) {{ check(c1[i]==0x11000000u+(uint32_t)i,"M3 host-device core bank changed"); check(e1[i]==0x33000000u+(uint32_t)i,"M3 host-device event bank changed"); if(i!=2) check(u1[i]==0x22000000u+(uint32_t)i,"M3 host-device non-SIG bank changed"); }}
        reset(c2,u2,e2); check_mode(&y,&py,u2,PHY_MODE_USB_DEVICE,(seed&~USB2PHY_SIG_HOST)|USB2PHY_SIG_M3_DEVICE,"M3 device signal bits changed"); check_mode(&y,&py,u2,PHY_MODE_USB_HOST,((seed&~USB2PHY_SIG_HOST)|USB2PHY_SIG_M3_DEVICE)|USB2PHY_SIG_HOST,"M3 device-host signal bits changed");
        for(size_t i=0;i<64;i++) {{ check(c2[i]==0x11000000u+(uint32_t)i,"M3 device-host core bank changed"); check(e2[i]==0x33000000u+(uint32_t)i,"M3 device-host event bank changed"); if(i!=2) check(u2[i]==0x22000000u+(uint32_t)i,"M3 device-host non-SIG bank changed"); }}
    }}
    reset(c,u,e); size_t n=op_count; uint32_t old=u[2]; check(atcphy_usb2_set_mode(&p,99,0)==-EINVAL,"invalid mode was accepted"); check(op_count==n && u[2]==old,"invalid mode wrote SIG");
}}
static void run_m3_callback_order(void) {{
    for (int mode=PHY_MODE_USB_HOST; mode<=PHY_MODE_USB_DEVICE; mode++) for (unsigned low=0; low<16; low++) for (unsigned variant=0; variant<2; variant++) {{
        uint32_t seed=(variant ? 0x5a5a7000u : 0xa5a50000u)|low; uint32_t ca[64],ua[64],ea[64],cb[64],ub[64],eb[64];
        for(size_t i=0;i<64;i++) {{ ca[i]=cb[i]=0x11000000u+(uint32_t)i; ua[i]=ub[i]=0x22000000u+(uint32_t)i; ea[i]=eb[i]=0x33000000u+(uint32_t)i; }} ua[2]=ub[2]=seed;
        struct apple_atcphy a={{0}},b={{0}}; struct phy pa={{0}},pb={{0}}; attach(&a,&atcphy_hw_t6031,ca,ua,ea); attach(&b,&atcphy_hw_t6031,cb,ub,eb); pa.drv=&a; pb.drv=&b;
        reset(ca,ua,ea); atcphy_usb2_power_on(&a); check(atcphy_usb2_set_mode(&pa,mode,0)==0,"power-on-then-mode failed");
        reset(cb,ub,eb); check(atcphy_usb2_set_mode(&pb,mode,0)==0,"mode-then-power-on mode failed"); atcphy_usb2_power_on(&b);
        uint32_t expected = mode==PHY_MODE_USB_HOST ? (seed|3u|USB2PHY_SIG_HOST) : ((seed|0xfu)&~USB2PHY_SIG_HOST);
        check(ua[2]==expected && ub[2]==expected,"power/mode order SIG result changed");
        for(size_t i=0;i<64;i++) {{ check(ca[i]==cb[i],"power/mode order core bank differs"); check(ua[i]==ub[i],"power/mode order USB bank differs"); check(ea[i]==eb[i],"power/mode order event bank differs"); }}
    }}
}}
static void equal_steps(const struct step *a, const struct step *b, size_t n, const char *msg) {{ for(size_t i=0;i<n;i++) {{ check(a[i].kind==b[i].kind,msg); if(a[i].kind=='D') check(a[i].delay==b[i].delay,msg); else check(a[i].op.bank==b[i].op.bank && a[i].op.offset==b[i].op.offset && a[i].op.before==b[i].op.before && a[i].op.after==b[i].op.after,msg); }} }}
static void run_legacy(void) {{
    const struct atcphy_hw *hs[2]={{&atcphy_hw_t8103,&atcphy_hw_t8122}};
    for(size_t h=0;h<2;h++) {{
        for(int mode=1;mode<=2;mode++) {{ uint32_t c[64]={{0}},u[64]={{0}},e[64]={{0}},c2[64]={{0}},u2[64]={{0}},e2[64]={{0}}; struct apple_atcphy a={{0}},b={{0}}; struct phy p={{0}},q={{0}}; attach(&a,hs[h],c,u,e);attach(&b,hs[h],c2,u2,e2);p.drv=&a;q.drv=&b;u[2]=u2[2]=0xa5a5000c;reset(c,u,e);check(atcphy_usb2_set_mode(&p,mode,0)==0,"legacy mode failed");size_t n=step_count;struct step x[512];memcpy(x,steps,sizeof(x));reset(c2,u2,e2);check(atcphy_usb2_set_mode_baseline(&q,mode,0)==0,"legacy baseline mode failed");check(step_count==n,"legacy mode trace length changed");equal_steps(x,steps,n,"legacy mode trace changed"); }}
        uint32_t c[64]={{0}},u[64]={{0}},e[64]={{0}},c2[64]={{0}},u2[64]={{0}},e2[64]={{0}}; struct apple_atcphy a={{0}},b={{0}}; attach(&a,hs[h],c,u,e);attach(&b,hs[h],c2,u2,e2);u[2]=u2[2]=0xa5a5000c;reset(c,u,e);atcphy_usb2_power_on(&a);size_t n=step_count;struct step x[512];memcpy(x,steps,sizeof(x));reset(c2,u2,e2);atcphy_usb2_power_on_baseline(&b);check(step_count==n,"legacy power trace length changed");equal_steps(x,steps,n,"legacy power trace changed");
    }}
}}
int main(int argc,char **argv) {{ if(argc!=2)return 2; if(!strcmp(argv[1],"m3-power"))run_m3_power(); else if(!strcmp(argv[1],"m3-trace"))run_m3_trace(); else if(!strcmp(argv[1],"m3-modes"))run_m3_modes(); else if(!strcmp(argv[1],"m3-callback-order"))run_m3_callback_order(); else if(!strcmp(argv[1],"legacy"))run_legacy(); else return 2; return 0; }}
"""
    c_path = out / f"fixture-{mutation or 'normal'}.c"
    binary = out / f"fixture-{mutation or 'normal'}"
    c_path.write_text(textwrap.dedent(c))
    compiler = shutil.which("clang") or shutil.which("cc")
    if not compiler:
        raise unittest.SkipTest("clang/cc unavailable")
    run = subprocess.run([compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter", "-Wno-unused-value", "-fsanitize=address,undefined", "-g", str(c_path), "-o", str(binary)], capture_output=True, text=True)
    if run.returncode:
        raise AssertionError(f"fixture compile failed:\n{run.stderr[-5000:]}")
    return binary


TEST_OUTPUT = None
SOURCE_DIR = DEFAULT_SOURCE


class RoleSignalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.out = pathlib.Path(TEST_OUTPUT or tempfile.mkdtemp(prefix="j575d-role-signals.", dir=ROOT / "scratch"))
        cls.out.mkdir(parents=True, exist_ok=True)
        cls.source, cls.baseline = prepare_source(cls.out, SOURCE_DIR)
        cls.binary = build_fixture(cls.source, cls.baseline, cls.out)
        (cls.out / "provenance.txt").write_text(f"base_sha256={BASE_SHA}\npatch_0010_sha256={PATCH_SHA}\npatched_sha256={sha(cls.source)}\n")

    def run_case(self, case, binary=None):
        return subprocess.run([str(binary or self.binary), case], capture_output=True, text=True)

    def test_m3_power_on_all_low_bits_and_upper_bits(self):
        r = self.run_case("m3-power")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_m3_trace_only_changes_initial_signal_write(self):
        r = self.run_case("m3-trace")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_m3_power_and_mode_callback_orders(self):
        r = self.run_case("m3-callback-order")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_m3_role_switches_and_invalid_mode(self):
        r = self.run_case("m3-modes")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_legacy_traces_are_exact(self):
        r = self.run_case("legacy")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_flag_is_m3_only_and_unchanged_helpers(self):
        source = self.source.read_text(); baseline = self.baseline.read_text()
        t6031 = source[source.index("static const struct atcphy_hw atcphy_hw_t6031"):]
        t8103 = source[source.index("static const struct atcphy_hw atcphy_hw_t8103"):source.index("static const struct atcphy_hw atcphy_hw_t8122")]
        t8122 = source[source.index("static const struct atcphy_hw atcphy_hw_t8122"):source.index("static const struct atcphy_hw atcphy_hw_t6031")]
        self.assertIn(".m3_role_signals = true", t6031.split("};", 1)[0])
        self.assertNotIn("m3_role_signals", t8103.split("};", 1)[0])
        self.assertNotIn("m3_role_signals", t8122.split("};", 1)[0])
        for name in ("atcphy_usb2_power_off", "atcphy_map_resources", "mask32", "set32", "clear32"):
            self.assertEqual(extract_function(source, name), extract_function(baseline, name))

    def _mutation(self, name, case, expected):
        binary = build_fixture(self.source, self.baseline, self.out, name)
        r = self.run_case(case, binary)
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn(f"CHECK: {expected}", r.stderr)

    def test_mutant_host_clearing_is_designated_failure(self):
        self._mutation("host-clear-c", "m3-modes", "M3 host signal bits changed")

    def test_mutant_unconditional_orf_is_designated_failure(self):
        self._mutation("power-unconditional-orf", "m3-power", "M3 power-on signal bits changed")

    def test_mutant_device_omitting_c_is_designated_failure(self):
        self._mutation("device-omit-c", "m3-modes", "M3 device signal bits changed")


def main() -> int:
    global TEST_OUTPUT, SOURCE_DIR
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--source-dir")
    parser.add_argument("--output-dir")
    args, remaining = parser.parse_known_args()
    if args.source_dir:
        SOURCE_DIR = pathlib.Path(args.source_dir)
    TEST_OUTPUT = args.output_dir
    result = unittest.main(argv=[sys.argv[0], *remaining], verbosity=2, exit=False).result
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
