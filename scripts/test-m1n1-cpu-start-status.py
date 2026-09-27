#!/usr/bin/env python3
"""Source-extracted host regression for T6032 SMP status propagation.

SMP functions execute against ADT/MMIO mocks. Payload/HV tests execute their
extracted guards, with separate ordering checks bounded to the real caller
functions; they do not execute the complete payload/HV initialization.
"""

from __future__ import annotations

import ast
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
PINNED = ROOT / "scratch/m1n1-cpu-audit/m1n1-4184923ffb2dff079b384d6a32cc02142aa14572"
TEMPLATE = ROOT / "tests/m1n1-cpu-preflight.c"
STATUS_TEMPLATE = ROOT / "tests/m1n1-cpu-start-status.c"
PATCH_NAMES = (
    "0001-expand-cpu-capacity-and-fix-bounds.patch",
    "0003-guard-secondary-start-prerequisites.patch",
    "0004-abort-on-secondary-start-timeout.patch",
    "0005-t6032-cpu-start-masks.patch",
    "0006-preflight-t6032-cpu-inventory.patch",
)
EXPECTED = {
    "src/smp.c": "173ae51dd860d1b075a071d78d06945e3ed929910ce06ab0f76cd6b9e261371b",
    "src/smp.h": "d4bd759b232d47930893c4d0fb90280935741929e4e4dca5a15654fb0a316c83",
    "src/soc.h": "3569ce0f11ad808f724bf0c050b1fc8381dd199791ec95729f411ad8c2359bca",
    "src/hv.h": "e6055d4abe512bd60f86173bb4c07db37e9cba9a103c9aa7d642c03dea282472",
    "src/kboot.c": "11294702663baab7a3e0d0c7ac426688d6dc39f8543ca8c3088bf5cdd4f5d926",
    "src/hv.c": "764adf7001dd94bdd017c57b70893c87369716bf0034e64f7bf70dc9a74cd1cd",
    "src/payload.c": "4100228afa891c54d40a29eb47bfe024c10aeaa25b9b2fcc12388a5a96a6dd0c",
    "src/proxy.c": "f242bfb5b32de097b8b65a0f9e07d23bf02c936cbc7b21349da5a7fea0031119",
    "src/proxy.h": "98203fac9cd1d67413862676b18b4d2d75f5e2d9e57b206081c6a360618b220f",
    "proxyclient/m1n1/proxy.py": "82be4a57a77d1a5b7e86192491aa7efaea15ce182338f8f7d8809184f51534c3",
}


def fail(message: str) -> None:
    raise RuntimeError(message)


def run(command: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=False,
                          env={**os.environ, "ASAN_OPTIONS": "detect_leaks=0"})


def load_extractor():
    spec = importlib.util.spec_from_file_location("m1n1_bounds", ROOT / "scripts/test-m1n1-cpu-bounds.py")
    if spec is None or spec.loader is None:
        fail("cannot load pinned source extractor")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def materialize(work: pathlib.Path) -> pathlib.Path:
    tree = work / "m1n1"
    (tree / "src").mkdir(parents=True)
    for relative, expected in EXPECTED.items():
        source = PINNED / relative
        if not source.is_file() or sha256(source) != expected:
            fail(f"pinned source hash mismatch: {relative}")
        if relative.startswith("proxyclient/"):
            continue
        (tree / relative).write_bytes(source.read_bytes())
    status_patches = sorted((ROOT / "patches/m1n1").glob("0007-*.patch"))
    if len(status_patches) != 1:
        fail("expected exactly one 0007 status patch")
    for name in PATCH_NAMES:
        patch = ROOT / "patches/m1n1" / name
        applied = run(["patch", "-p1", "--batch", "--forward", "-i", str(patch)], tree)
        if applied.returncode:
            fail(f"{name} did not apply:\n{applied.stdout}{applied.stderr}")
    applied = run(["patch", "-p1", "--batch", "--forward", "-i", str(status_patches[0])], tree)
    if applied.returncode:
        fail(f"{status_patches[0].name} did not apply:\n{applied.stdout}{applied.stderr}")
    return tree


def guard(source: str, path: pathlib.Path) -> str:
    match = re.search(
        r"if\s*\(\s*smp_start_secondaries\(\)\s*<\s*0\s*\)\s*\{?\s*return\s+-1\s*;\s*\}?",
        source,
    )
    if not match:
        fail(f"T6032 failure guard missing in {path}")
    return match.group(0)


def case_block(source: str, case_name: str, path: pathlib.Path) -> str:
    start = source.find(f"case {case_name}:")
    if start < 0:
        fail(f"proxy case missing in {path}: {case_name}")
    end = source.find("case ", start + len(case_name) + 6)
    if end < 0:
        fail(f"proxy case has no following case in {path}: {case_name}")
    block = source[start:end]
    if "break;" not in block:
        fail(f"proxy case has no break in {path}: {case_name}")
    return block


def exercise_python_status_wire(client: str) -> None:
    """Execute the pinned _request decoder with a signed S_BADSTATE reply."""
    tree = ast.parse(client)
    function = next(
        (node for node in ast.walk(tree)
         if isinstance(node, ast.FunctionDef) and node.name == "_request"),
        None,
    )
    if function is None:
        fail("pinned Python proxy _request function missing")
    probe = ast.ClassDef(
        name="_StatusProbe", bases=[], keywords=[],
        body=[function], decorator_list=[],
    )
    module = ast.Module(body=[ast.Import(names=[ast.alias(name="struct")]), probe], type_ignores=[])
    ast.fix_missing_locations(module)
    class ProxyError(Exception):
        pass
    class ProxyReplyError(ProxyError):
        pass
    class ProxyRemoteError(ProxyError):
        pass
    class ProxyCommandError(ProxyRemoteError):
        pass
    namespace = {
        "ProxyReplyError": ProxyReplyError,
        "ProxyRemoteError": ProxyRemoteError,
        "ProxyCommandError": ProxyCommandError,
    }
    exec(compile(module, "<pinned proxy _request>", "exec"), namespace)

    class FakeIface:
        def __init__(self, status: int):
            self.status = status

        def proxyreq(self, request, **kwargs):
            (opcode,) = __import__("struct").unpack("<Q", request[:8])
            return __import__("struct").pack("<QqQ", opcode, self.status, 0)

    probe = namespace["_StatusProbe"]()
    probe.iface = FakeIface(-2)
    probe.debug = False
    probe.S_OK, probe.S_BADCMD = 0, -1
    try:
        probe._request(0x500)
    except ProxyRemoteError:
        pass
    else:
        fail("pinned Python proxy did not reject signed S_BADSTATE")

    probe.iface.status = 0
    if probe._request(0x500) != 0:
        fail("pinned Python proxy changed successful status return")


def main() -> int:
    clang = shutil.which("clang")
    if clang is None:
        fail("clang is required")
    helper = load_extractor()
    with tempfile.TemporaryDirectory(prefix="m1n1-cpu-start-status-", dir=ROOT / "scratch") as name:
        work = pathlib.Path(name)
        tree = materialize(work)
        smp = (tree / "src/smp.c").read_text(encoding="utf-8")
        soc = (tree / "src/soc.h").read_text(encoding="utf-8")
        smp_header = (tree / "src/smp.h").read_text(encoding="utf-8")
        payload = (tree / "src/payload.c").read_text(encoding="utf-8")
        hv = (tree / "src/hv.c").read_text(encoding="utf-8")
        try:
            payload = helper.extract_function(payload, "int payload_run(void)", tree / "src/payload.c")
            hv = helper.extract_function(hv, "int hv_init(void)", tree / "src/hv.c")
        except helper.HarnessError as exc:
            fail(str(exc))
        proxy = (tree / "src/proxy.c").read_text(encoding="utf-8")
        proxy_header = (tree / "src/proxy.h").read_text(encoding="utf-8")
        if not re.search(r"#define\s+S_BADSTATE\s+-2\b", proxy_header):
            fail("proxy.h lacks S_BADSTATE=-2")
        payload_guard = re.search(
            r"cpufreq_init\s*\(\).*?if\s*\(\s*smp_start_secondaries\(\)\s*<\s*0\s*\)\s*\{?\s*return\s+-1\s*;.*?mitigations_perform\s*\(\)",
            payload, re.S)
        if not payload_guard:
            fail("payload caller status guard/order is missing")
        for downstream in ("kboot_prepare_dt", "kboot_boot"):
            if payload.find(downstream) < payload_guard.end():
                fail(f"payload status guard does not precede {downstream}")
        hv_guard = re.search(
            r"pcie_shutdown\s*\(\).*?usb_hpm_restore_irqs\s*\(\s*0\s*\).*?if\s*\(\s*smp_start_secondaries\(\)\s*<\s*0\s*\).*?smp_set_wfe_mode",
            hv, re.S)
        if not hv_guard:
            fail("HV prelude/status guard/postlude order is missing")
        for downstream in ("hv_wdt_init", "hv_pt_init"):
            if hv.find(downstream) < hv_guard.end():
                fail(f"HV status guard does not precede {downstream}")
        try:
            functions = {
                "mask": helper.extract_function(smp, "static bool smp_cpu_start_masks(", tree / "src/smp.c"),
                "u32": helper.extract_function(smp, "static bool smp_t6032_u32(", tree / "src/smp.c"),
                "preflight": helper.extract_function(smp, "static bool smp_t6032_preflight(", tree / "src/smp.c"),
                "start_cpu": helper.extract_function(smp, "static bool smp_start_cpu(", tree / "src/smp.c"),
                "start_secondaries": helper.extract_function(smp, "int smp_start_secondaries(void)", tree / "src/smp.c"),
            }
        except helper.HarnessError as exc:
            fail(str(exc))
        if not re.search(
                r"if\s*\(\s*chip_id\s*==\s*T6032\s*\).*?!spin_table\[i\]\.flag.*?return\s+-1",
                functions["start_secondaries"], re.S):
            fail("T6032 final secondary-flag failure gate missing")
        fixture = json.loads((ROOT / "docs/inventory/t6032-startup-metadata-2026-09-26.json").read_text())
        cpus = fixture["cpus"]
        if len(cpus) != 32:
            fail("startup metadata fixture is not 32 records")
        defines = [line for text in (smp, smp_header) for line in text.splitlines()
                   if line.startswith("#define ")]
        defines += [line for line in soc.splitlines()
                    if re.match(r"#define\s+(?:S5L|S800|T[0-9]+)", line)]
        state_rows = ", ".join(
            "{" + ", ".join(str(x) for x in (c["state"].encode() + b"\0")) + "}"
            for c in cpus
        )
        live = (f"#define LIVE_RUNNING_ID {fixture['running_cpu_id']}\n"
                f"static const u32 live_ids[32] = {{{', '.join(str(c['cpu_id']) for c in cpus)}}};\n"
                f"static const u32 live_regs[32] = {{{', '.join(c['reg'] + 'U' for c in cpus)}}};\n"
                f"static const u32 live_dies[32] = {{{', '.join(str(c['die']) for c in cpus)}}};\n"
                f"static const u32 live_clusters[32] = {{{', '.join(str(c['cluster']) for c in cpus)}}};\n"
                f"static const u32 live_cores[32] = {{{', '.join(str(c['core']) for c in cpus)}}};\n"
                f"static const u8 live_states[32][8] = {{{state_rows}}};\n"
                f"static const u64 live_bases[32] = {{{', '.join(c['cpu_impl_base'] + 'ULL' for c in cpus)}}};\n"
                f"static const u64 live_sizes[32] = {{{', '.join(c['cpu_impl_size'] + 'ULL' for c in cpus)}}};")
        source = TEMPLATE.read_text(encoding="utf-8")
        main_at = source.find("int main(void)")
        if main_at < 0:
            fail("preflight template main missing")
        source = source[:main_at]
        # Rename shared-template mocks in this generated translation unit so
        # status cases can inject each pre-release lookup failure locally.
        for old, new in (("adt_path_offset_trace", "base_adt_path_offset_trace"),
                         ("adt_path_offset", "base_adt_path_offset"),
                         ("adt_get_reg", "base_adt_get_reg")):
            source = source.replace(old + "(", new + "(")
        declarations = (
            "static int adt_path_offset_trace(const void *, const char *, int *);\n"
            "static int adt_path_offset(const void *, const char *);\n"
            "static int adt_get_reg(const void *, int *, const char *, int, u64 *, u64 *);\n"
        )
        source = source.replace("/* INSERT_SOURCE_DEFINES */",
                                declarations + "/* INSERT_SOURCE_DEFINES */", 1)
        source += r'''
static unsigned status_path_failure;
static int base_adt_path_offset_trace(const void *tree, const char *path, int *trace);
static int base_adt_path_offset(const void *tree, const char *path);
static int base_adt_get_reg(const void *tree, int *path, const char *prop, int index,
                            u64 *addr, u64 *size);
static int adt_path_offset_trace(const void *tree, const char *path, int *trace);
static int adt_path_offset(const void *tree, const char *path);
static int adt_get_reg(const void *tree, int *path, const char *prop, int index,
                       u64 *addr, u64 *size);
static int adt_path_offset_trace(const void *tree, const char *path, int *trace)
{
    if (status_path_failure == 1 && !strcmp(path, "/arm-io/pmgr")) return -1;
    return base_adt_path_offset_trace(tree, path, trace);
}
static int adt_path_offset(const void *tree, const char *path)
{
    if ((status_path_failure == 2 && !strcmp(path, "/arm-io")) ||
        (status_path_failure == 3 && !strcmp(path, "/cpus"))) return -1;
    return base_adt_path_offset(tree, path);
}
static int adt_get_reg(const void *tree, int *path, const char *prop, int index,
                       u64 *addr, u64 *size)
{
    if (status_path_failure == 4) return -1;
    return base_adt_get_reg(tree, path, prop, index, addr, size);
}
'''
        replacements = {
            "/* INSERT_SOURCE_DEFINES */": "\n".join(defines),
            "/* INSERT_LIVE_FIXTURE */": live,
            "/* INSERT_MASK_HELPER */": functions["mask"],
            "/* INSERT_U32_HELPER */": functions["u32"],
            "/* INSERT_PREFLIGHT_HELPER */": functions["preflight"],
            "/* INSERT_START_CPU */": functions["start_cpu"],
            "/* INSERT_START_SECONDARIES */": functions["start_secondaries"],
        }
        for marker, replacement in replacements.items():
            if source.count(marker) != 1:
                fail(f"template marker missing or duplicated: {marker}")
            source = source.replace(marker, replacement)
        status = STATUS_TEMPLATE.read_text(encoding="utf-8")
        replacements.update({
            "/* INSERT_PAYLOAD_GUARD */": guard(payload, tree / "src/payload.c"),
            "/* INSERT_HV_GUARD */": guard(hv, tree / "src/hv.c"),
            "/* INSERT_PROXY_SMP_CASE */": case_block(proxy, "P_SMP_START_SECONDARIES", tree / "src/proxy.c"),
            "/* INSERT_PROXY_HV_CASE */": case_block(proxy, "P_HV_INIT", tree / "src/proxy.c"),
        })
        for marker, replacement in replacements.items():
            if marker in status:
                if status.count(marker) != 1:
                    fail(f"status template marker missing or duplicated: {marker}")
                status = status.replace(marker, replacement)
        source += status
        generated = work / "status.c"
        binary = work / "status"
        generated.write_text(source, encoding="utf-8")
        compiled = run([clang, "-std=c11", "-O1", "-g", "-fno-omit-frame-pointer",
                        "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                        str(generated), "-o", str(binary)], work)
        if compiled.returncode:
            fail(f"clang failed:\n{compiled.stdout}{compiled.stderr}")
        completed = run([str(binary)], work)
        if completed.returncode:
            fail(f"status harness failed ({completed.returncode}):\n{completed.stdout}{completed.stderr}")
        client = (PINNED / "proxyclient/m1n1/proxy.py").read_text(encoding="utf-8")
        if ("if status != self.S_OK:" not in client or
                "raise ProxyRemoteError" not in client or
                'struct.unpack("<Qq"' not in client or
                "def smp_start_secondaries(self):" not in client):
            fail("pinned Python proxy status/request shape changed")
        exercise_python_status_wire(client)
        print(completed.stdout, end="")
        print("Python proxy request path rejects signed S_BADSTATE and preserves S_OK")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(f"m1n1 CPU status harness: ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
