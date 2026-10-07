#!/usr/bin/env python3
"""Mock-only host regression for the reviewed m1n1 SMP adaptation.

The runner materializes the hash-pinned 2460b604 tree, applies only the
reviewed upstream patch series, extracts the current SMP functions into
tests/m1n1-upstream-smp.c, and executes no firmware, AArch64, MMIO, VM, or
native reset code.  The old pinned runners are deliberately not imported or
modified. Structural mutations are checked without execution; safe behavioral
mutations run only against valid mock fixtures, so unpatched source is never
exposed to sanitizer UB.
"""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from typing import NoReturn

ROOT = pathlib.Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / "scratch/m1n1-upstream-audit/source-2460b604c6f016956ead711823605eea840c602e.tar.gz"
ARCHIVE_SHA256 = "aa0ffbeb7ae9cc0eb7a5653f44474e26f826809cf7f0564f8deb395d25203b01"
TREE_NAME = "m1n1-2460b604c6f016956ead711823605eea840c602e"
REV = "2460b604c6f016956ead711823605eea840c602e"
PATCH_DIR = ROOT / "patches/m1n1/upstream-2460b60"
PATCHES = (
    "0001-fix-half-open-cpu-bounds.patch",
    "0003-guard-secondary-start-prerequisites.patch",
    "0004-abort-on-secondary-start-timeout.patch",
    "0005-t6032-cpu-start-masks.patch",
    "0006-preflight-t6032-cpu-inventory.patch",
    "0007-propagate-t6032-cpu-start-failures.patch",
    "0017-validate-smp-api-cpu-indices.patch",
    "0018-validate-mmu-hv-cpu-indices.patch",
    "0022-contain-t6032-stop-reset-state.patch",
)
TEMPLATE = ROOT / "tests/m1n1-upstream-smp.c"
WORK = ROOT / "scratch/upstream-smp-host"
CLANG = shutil.which("clang")
RUN_ROOT: pathlib.Path | None = None
SOURCE_CONSTANTS: dict[str, str] = {}
SOURCE_DEFINES: str = ""
CAPTURED_TOPOLOGY: str = ""
STOP_TIMEOUT_ENABLED = False
CALLER_GUARDS: str = ""


class HarnessError(RuntimeError):
    pass


def fail(message: str) -> NoReturn:
    raise HarnessError(message)


def run(command: list[str], cwd: pathlib.Path | None = None,
        env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, check=False, timeout=60, env=env)
    except subprocess.TimeoutExpired:
        fail(f"command timed out: {' '.join(command[:3])}")


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def extract_function(source: str, name: str) -> str:
    match = re.search(
        rf"(?m)^(?P<head>(?:(?:static|inline|__attribute__\s*\([^\n]+\))\s+)*"
        rf"(?:bool|void|u64|uint64_t|int|static\s+bool|static\s+void|static\s+u64)\s+"
        rf"{re.escape(name)}\s*\([^;{{]*\))\s*\{{",
        source,
    )
    if match is None:
        # A deliberately permissive fallback handles declarations whose
        # return type was changed by the status patch.
        start = source.find(f"{name}(")
        if start < 0:
            fail(f"missing current function {name}")
        brace = source.find("{", start)
        if brace < 0:
            fail(f"missing body for {name}")
        start = source.rfind("\n", 0, start) + 1
    else:
        start, brace = match.start(), match.end() - 1
    depth = 0
    quote: str | None = None
    escaped = line_comment = block_comment = False
    for index in range(brace, len(source)):
        char = source[index]
        nxt = source[index + 1] if index + 1 < len(source) else ""
        if line_comment:
            if char == "\n": line_comment = False
        elif block_comment:
            if char == "*" and nxt == "/": block_comment = False
        elif quote:
            if escaped: escaped = False
            elif char == "\\": escaped = True
            elif char == quote: quote = None
        elif char in "\"'": quote = char
        elif char == "/" and nxt == "/": line_comment = True
        elif char == "/" and nxt == "*": block_comment = True
        elif char == "{": depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0: return source[start:index + 1]
    fail(f"unterminated function {name}")


def materialize() -> pathlib.Path:
    if not ARCHIVE.is_file():
        fail(f"missing reviewed archive: {ARCHIVE}")
    if sha256(ARCHIVE) != ARCHIVE_SHA256:
        fail("reviewed archive SHA-256 mismatch")
    global RUN_ROOT, SOURCE_CONSTANTS, SOURCE_DEFINES, CAPTURED_TOPOLOGY, STOP_TIMEOUT_ENABLED, CALLER_GUARDS
    WORK.mkdir(parents=True, exist_ok=True)
    RUN_ROOT = pathlib.Path(tempfile.mkdtemp(prefix="run-", dir=WORK))
    with tarfile.open(ARCHIVE, "r:gz") as archive:
        members = archive.getmembers()
        for member in members:
            target = (RUN_ROOT / member.name).resolve()
            if not str(target).startswith(str(RUN_ROOT.resolve()) + "/"):
                fail(f"archive path escapes work directory: {member.name}")
        archive.extractall(RUN_ROOT, filter="data")
    tree = RUN_ROOT / TREE_NAME
    if not (tree / "src/smp.c").is_file():
        fail(f"archive root mismatch; expected {TREE_NAME}")
    expected = {
        "src/smp.c": "4b000be8d4e6437fc24351a57db5277785cc2e427045fb45d1750b158f2b8766",
        "src/smp_asm.h": "2afe4c4ac4cd696a2d020fcef5621aa1ac66c2e7edcaaaef11f17df17cc696bd",
    }
    for relative, digest in expected.items():
        if sha256(tree / relative) != digest:
            fail(f"source hash mismatch: {relative}")
    smp_text = (tree / "src/smp.c").read_text(encoding="utf-8")
    asm_text = (tree / "src/smp_asm.h").read_text(encoding="utf-8")
    soc_text = (tree / "src/soc.h").read_text(encoding="utf-8")
    pmgr_text = (tree / "src/pmgr.h").read_text(encoding="utf-8")

    def macro(text: str, name: str) -> str:
        match = re.search(rf"(?m)^#define\s+{re.escape(name)}\s+(.+?)\s*$", text)
        if match is None:
            fail(f"source constant missing: {name}")
        return match.group(1)

    SOURCE_CONSTANTS = {
        "MAX_CPUS": macro(asm_text, "MAX_CPUS"),
        "MAX_EL3_CPUS": macro(asm_text, "MAX_EL3_CPUS"),
        "SECONDARY_STACK_SIZE": macro(asm_text, "SECONDARY_STACK_SIZE"),
        "T6032": macro(soc_text, "T6032"),
        "PMGR_DIE_OFFSET": macro(pmgr_text, "PMGR_DIE_OFFSET"),
        "CPU_REG_CORE": macro(smp_text, "CPU_REG_CORE"),
        "CPU_REG_CLUSTER": macro(smp_text, "CPU_REG_CLUSTER"),
        "CPU_REG_DIE": macro(smp_text, "CPU_REG_DIE"),
        "RVBAR_ADDR": macro(smp_text, "RVBAR_ADDR"),
    }
    soc_names = ("S5L8960X", "T7000", "T7001", "S8000", "S8001", "S8003",
                 "T8010", "T8011", "T8012", "T8015", "T8103", "T8112",
                 "T8122", "T8132", "T8140", "T8142", "T8152", "T6000",
                 "T6001", "T6002", "T6020", "T6021", "T6022", "T6030",
                 "T6031", "T6034", "T6040", "T6041", "T6050", "T6051")
    offset_names = ("CPU_START_OFF_S5L8960X", "CPU_START_OFF_S8000", "CPU_START_OFF_T8103",
                    "CPU_START_OFF_T8112", "CPU_START_OFF_T6020", "CPU_START_OFF_T6031")
    SOURCE_DEFINES = "\n".join(
        f"#define {name} {macro(soc_text if name in soc_names else smp_text, name)}"
        for name in (*soc_names, *offset_names)
    )
    inventory = ROOT / "docs/inventory/t6032-cpus-2026-09-26.json"
    if not inventory.is_file():
        fail(f"captured inventory missing: {inventory}")
    document = json.loads(inventory.read_text(encoding="utf-8"))
    topology = document.get("topology", {})
    affinity = topology.get("affinity", [])
    if topology.get("advertised_max_cpus") != 32 or len(affinity) != 32:
        fail("captured inventory is not the complete 32-node fixture")
    rows = sorted((int(row["cpu_id"]), int(row["die"]), int(row["cluster"]), int(row["core"]))
                  for row in affinity)
    if [row[0] for row in rows] != list(range(32)):
        fail("captured inventory IDs are not dense 0..31")
    CAPTURED_TOPOLOGY = ",\n    ".join("{%d, %d, %d, %d}" % row for row in rows)
    optional_stop = PATCH_DIR / "0022-contain-t6032-stop-reset-state.patch"
    if not optional_stop.is_file():
        fail(f"missing required stop/entry containment patch: {optional_stop}")
    STOP_TIMEOUT_ENABLED = True
    patch_names = list(PATCHES)
    for name in patch_names:
        patch = PATCH_DIR / name
        if not patch.is_file():
            fail(f"missing reviewed adaptation (parent/worker still editing?): {patch}")
        result = run(["patch", "-p1", "--batch", "--forward", "--fuzz=0", "-i", str(patch)], tree)
        if result.returncode:
            fail(f"{name} did not apply cleanly:\n{result.stdout}{result.stderr}")
    payload_text = (tree / "src/payload.c").read_text(encoding="utf-8")
    hv_text = (tree / "src/hv/hv.c").read_text(encoding="utf-8")
    proxy_text = (tree / "src/proxy.c").read_text(encoding="utf-8")

    def status_if(text: str, label: str) -> str:
        match = re.search(r"if\s*\(\s*smp_start_secondaries\(\)\s*<\s*0\s*\)\s*(?:\{[^{}]*\}|return\s+-1\s*;)", text, re.S)
        if match is None:
            fail(f"missing extracted {label} SMP status cutoff")
        block = match.group(0).replace("smp_start_secondaries()", "mock_smp_start_secondaries()")
        return block

    proxy_match = re.search(
        r"if\s*\(\s*smp_start_secondaries\(\)\s*<\s*0\s*\)\s*"
        r"(?:\{[^{}]*\}|[^\n;]*;)\s*break\s*;",
        proxy_text, re.S,
    )
    if proxy_match is None:
        fail("missing extracted proxy SMP status mapping")
    proxy_block = proxy_match.group(0).replace("smp_start_secondaries()", "mock_smp_start_secondaries()")
    CALLER_GUARDS = f"""
static int caller_start_status, caller_continuation;
static int mock_smp_start_secondaries(void) {{ return caller_start_status; }}
static int payload_guard_probe(void) {{
    {status_if(payload_text, 'payload')}
    caller_continuation++;
    return 0;
}}
static int hv_guard_probe(void) {{
    {status_if(hv_text, 'HV')}
    caller_continuation++;
    return 0;
}}
struct proxy_probe_reply {{ int status; }};
static int proxy_guard_probe(void) {{
    struct proxy_probe_reply reply_storage = {{0}};
    struct proxy_probe_reply *reply = &reply_storage;
    switch (0) {{ case 0:
    {proxy_block}
    }}
    caller_continuation++;
    return reply->status;
}}
"""
    return tree


def function_bodies(tree: pathlib.Path) -> dict[str, str]:
    source = (tree / "src/smp.c").read_text(encoding="utf-8")
    names = (
        "smp_cpu_start_masks", "smp_t6032_u32", "smp_t6032_preflight",
        "smp_secondary_entry", "smp_init", "smp_start_secondaries", "smp_start_cpu", "smp_stop_cpu", "smp_send_ipi", "smp_call4",
        "smp_wait", "smp_is_alive", "smp_get_mpidr", "smp_get_release_addr",
    )
    result = {name: extract_function(source, name) for name in names}
    if not re.search(r"\bu8\s+secondary_stacks\[MAX_CPUS\]\[SECONDARY_STACK_SIZE\]", source):
        fail("current static normal stack declaration missing")
    if not re.search(r"\bu8\s+secondary_stacks_el3\[MAX_EL3_CPUS\]\[SECONDARY_STACK_SIZE\]", source):
        fail("current static EL3 stack declaration missing")
    if len(re.findall(r"secondary_stacks(?:_el3)?\[.*?\]\[SECONDARY_STACK_SIZE\].*?ALIGNED\(0x4000\)", source)) != 2:
        fail("both current static stack declarations must retain 0x4000 alignment")
    return result


def source_contracts(tree: pathlib.Path) -> dict[str, str]:
    smp = (tree / "src/smp.c").read_text(encoding="utf-8")
    memory = (tree / "src/memory.c").read_text(encoding="utf-8")
    hv = (tree / "src/hv/hv.c").read_text(encoding="utf-8")
    wdt = (tree / "src/hv/hv_wdt.c").read_text(encoding="utf-8")
    proxy = (tree / "src/proxy.c").read_text(encoding="utf-8")
    if not re.search(r"smp_t6032_preflight\s*\(", smp):
        fail("full-32 preflight helper/call missing")
    if not re.search(r"static\s+(?:bool|int)\s+smp_start_cpu\s*\(\s*int\s+index\s*,\s*const\s+struct\s+cpu_info", smp):
        fail("current smp_start_cpu ABI missing")
    if not re.search(r"\bint\s+smp_start_secondaries\s*\(\s*void\s*\)", smp):
        fail("status-returning smp_start_secondaries ABI missing")
    init = extract_function(smp, "smp_init")
    if init.find("smp_t6032_preflight") < 0:
        fail("smp_init does not call full inventory preflight")
    payload = (tree / "src/payload.c").read_text(encoding="utf-8")
    hv = (tree / "src/hv/hv.c").read_text(encoding="utf-8")
    if not re.search(r"smp_start_secondaries\(\)\s*<\s*0", payload):
        fail("payload caller does not cut off after SMP failure")
    if not re.search(r"smp_start_secondaries\(\)\s*<\s*0", hv):
        fail("HV caller does not cut off after SMP failure")
    if not re.search(r"RVBAR_ADDR\).*?\n\s*printf.*?\n\s*return", smp, re.S):
        fail("locked-RVBAR no-release guard missing")
    if not re.search(r"if\s*\(\s*i\s*>=\s*100\s*\).*?panic\s*\(", smp, re.S):
        fail("non-returning timeout containment missing")
    if STOP_TIMEOUT_ENABLED:
        stop_body = extract_function(smp, "smp_stop_cpu")
        if not re.search(r"if\s*\(\s*i\s*>=\s*50\s*\).*?panic\s*\(", stop_body, re.S):
            fail("0022 stop-timeout containment missing")
    entry = extract_function(smp, "smp_secondary_entry")
    if not re.search(r"index\s*<\s*0\s*\|\|\s*index\s*>=\s*MAX_CPUS", entry):
        fail("secondary-entry index guard missing")
    if not re.search(r"chip_id\s*==\s*T6032.*?smp_reset_stacks\[index\]\.mpidr\s*!=\s*~0ULL"
                     r".*?smp_reset_stacks\[index\]\.mpidr\s*!=\s*mpidr.*?panic\s*\(",
                     entry, re.S):
        fail("T6032 known-slot MPIDR guard missing")
    for name in ("smp_start_cpu", "smp_stop_cpu", "smp_send_ipi", "smp_call4", "smp_wait", "smp_is_alive", "smp_get_mpidr", "smp_get_release_addr"):
        body = extract_function(smp, name)
        if not re.search(r"\b(?:cpu|index)\s*<\s*0\s*\|\|\s*(?:cpu|index)\s*>=\s*MAX_CPUS", body):
            fail(f"signed index guard missing from {name}")
    for path, text, names in (
        ("src/memory.c", memory, ("mmu_init_secondary",)),
        ("src/hv/hv.c", hv, ("hv_start_secondary", "hv_exit_cpu", "hv_pin_cpu")),
        ("src/hv/hv_wdt.c", wdt, ("hv_wdt_start",)),
    ):
        for name in names:
            body = extract_function(text, name)
            lower_bound = r"(?:cpu|index)\s*<\s*-1" if name == "hv_pin_cpu" else r"(?:cpu|index)\s*<\s*0"
            if not re.search(rf"\b{lower_bound}\s*\|\|\s*(?:cpu|index)\s*>=\s*MAX_CPUS", body):
                fail(f"signed index guard missing from {path}:{name}")
    if len(re.findall(r"request->args\[0\]\s*>=\s*MAX_CPUS", proxy)) < 8:
        fail("raw proxy CPU ingress checks are incomplete")
    return {"smp": smp, "memory": memory, "hv": hv, "wdt": wdt, "proxy": proxy}


def check_mutation_controls(sources: dict[str, str]) -> int:
    smp = sources["smp"]
    start_cpu = extract_function(smp, "smp_start_cpu")
    init = extract_function(smp, "smp_init")
    send_ipi = extract_function(smp, "smp_send_ipi")
    proxy = extract_function(sources["proxy"], "proxy_process")
    controls = (
        ("RVBAR return", start_cpu,
         re.sub(r"(RVBAR_ADDR\).*?printf\(.*?\)\s*;)\s*return\s+false\s*;", r"\1", start_cpu,
                count=1, flags=re.S),
         r"RVBAR_ADDR\).*?\n\s*printf.*?\n\s*return\s+false\s*;"),
        ("timeout panic", start_cpu, start_cpu.replace("panic(\"SMP:", "printf(\"SMP:", 1),
         r"if\s*\(\s*i\s*>=\s*100\s*\).*?panic\s*\("),
        ("preflight call", init, init.replace("smp_t6032_preflight", "smp_t6032_preflight_removed", 1),
         r"smp_t6032_preflight\s*\("),
        ("negative SMP guard", send_ipi, send_ipi.replace("cpu < 0 || cpu >= MAX_CPUS", "cpu >= MAX_CPUS", 1),
         r"cpu\s*<\s*0\s*\|\|\s*cpu\s*>=\s*MAX_CPUS"),
        ("proxy raw guard", proxy, proxy.replace("request->args[0] >= MAX_CPUS", "request->args[0] > MAX_CPUS"),
         r"request->args\[0\]\s*>=\s*MAX_CPUS"),
    )
    for name, original, mutated, pattern in controls:
        if not re.search(pattern, original, re.S):
            fail(f"baseline missing {name} control")
        if re.search(pattern, mutated, re.S):
            fail(f"source mutation control did not remove {name}")
    return len(controls)


def compile_fixture(bodies: dict[str, str], *, label: str = "baseline", expect_pass: bool = True,
                    failure_marker: str | None = None) -> pathlib.Path:
    source = TEMPLATE.read_text(encoding="utf-8")
    declarations = """
void smp_send_ipi(int); void smp_call4(int, void *, u64, u64, u64, u64);
u64 smp_wait(int); bool smp_is_alive(int); u64 smp_get_mpidr(int);
u64 smp_get_release_addr(int);
"""
    fixture_bodies = dict(bodies)
    fixture_bodies["smp_t6032_preflight"] = fixture_bodies["smp_t6032_preflight"].replace(
        "{", "{\n    preflight_calls++;", 1)
    insertion = declarations + "\n" + "\n\n".join(fixture_bodies[name] for name in (
        "smp_cpu_start_masks", "smp_t6032_u32", "smp_t6032_preflight",
        "smp_secondary_entry", "smp_init", "smp_send_ipi", "smp_call4", "smp_wait", "smp_is_alive",
        "smp_get_mpidr", "smp_get_release_addr", "smp_start_cpu", "smp_stop_cpu",
        "smp_start_secondaries",
    ))
    generated = source.replace("/* INSERT_SMP_FUNCTIONS */", insertion)
    for name, value in SOURCE_CONSTANTS.items():
        generated = generated.replace(f"__{name}__", value)
    generated = generated.replace("/* INSERT_CAPTURED_TOPOLOGY */", CAPTURED_TOPOLOGY)
    generated = generated.replace("/* INSERT_SOURCE_CONSTANTS */", SOURCE_DEFINES)
    generated = generated.replace("__STOP_TIMEOUT_TEST__", "1" if STOP_TIMEOUT_ENABLED else "0")
    generated = generated.replace("/* INSERT_CALLER_GUARDS */", CALLER_GUARDS)
    if RUN_ROOT is None:
        fail("materializer did not establish a run root")
    c_file = RUN_ROOT / f"m1n1-upstream-smp-{label}.c"
    binary = RUN_ROOT / f"m1n1-upstream-smp-{label}"
    c_file.write_text(generated, encoding="utf-8")
    if CLANG is None:
        fail("clang is required for host fixture")
    result = run([CLANG, "-std=gnu11", "-O0", "-g", "-fsanitize=address,undefined",
                  "-fno-omit-frame-pointer", str(c_file), "-o", str(binary)])
    if result.returncode:
        fail(f"host fixture compile failed:\n{result.stdout}{result.stderr}")
    sanitizer_env = os.environ.copy()
    sanitizer_env["UBSAN_OPTIONS"] = "halt_on_error=1:print_stacktrace=1"
    sanitizer_env["ASAN_OPTIONS"] = "detect_leaks=0"
    result = run([str(binary)], RUN_ROOT, env=sanitizer_env)
    if expect_pass and result.returncode:
        fail(f"host fixture failed:\n{result.stdout}{result.stderr}")
    if not expect_pass:
        output = result.stdout + result.stderr
        if result.returncode == 0:
            fail(f"runtime mutation control unexpectedly passed: {label}")
        if result.returncode != 1 or any(token in output for token in
                                         ("AddressSanitizer", "UndefinedBehaviorSanitizer", "runtime error:")):
            fail(f"runtime mutation control failed for an unrelated reason: {label}:\n{output}")
        if failure_marker is None or failure_marker not in output:
            fail(f"runtime mutation control lacked designated fixture failure for {label}:\n{output}")
    return binary


def runtime_mutation_controls(tree: pathlib.Path, baseline: dict[str, str]) -> int:
    """Run safe mutations whose expected failure is an observed fixture assertion.

    Index mutations remain structural-only: executing those originals would
    intentionally reintroduce sanitizer UB. These controls exercise release
    ordering, timeout containment, mask bounds, inventory validation and
    final status behavior without invalid array indices.
    """
    source = (tree / "src/smp.c").read_text(encoding="utf-8")

    def variant(label: str, name: str, mutate, failure_marker: str) -> None:
        changed = source
        body = extract_function(changed, name)
        new_body = mutate(body)
        if new_body == body:
            fail(f"runtime mutation did not match {label}")
        changed = changed.replace(body, new_body, 1)
        bodies = {key: extract_function(changed, key) for key in baseline}
        compile_fixture(bodies, label=label, expect_pass=False, failure_marker=failure_marker)

    variant("no-rvbar-return", "smp_start_cpu", lambda body: re.sub(
        r"(RVBAR_ADDR\).*?printf\(.*?\)\s*;)\s*return\s+false\s*;",
        r"\1/* removed release guard */", body, count=1, flags=re.S),
        "FAIL: locked RVBAR mismatch has no release side effects")
    variant("timeout-returns", "smp_start_cpu", lambda body: body.replace(
        "panic(\"SMP:", "printf(\"SMP:", 1),
        "FAIL: secondary-start timeout panics")
    variant("mask-boundary", "smp_cpu_start_masks", lambda body: body.replace(
        "(u32)core >= selected_width", "(u32)core > selected_width", 1),
        "FAIL: cluster width boundary")
    variant("overlap-check", "smp_t6032_preflight", lambda body: body.replace(
        "(ids & (1U << previous)) && base < ends[previous] && bases[previous] < end",
        "false && base < ends[previous] && bases[previous] < end", 1),
        "FAIL: overlapping implementation windows rejected")
    variant("final-status", "smp_start_secondaries", lambda body: body.replace(
        "i != boot_cpu_idx && !spin_table[i].flag", "false && !spin_table[i].flag", 1),
        "FAIL: T6032 final status rejects an unstarted slot")
    variant("preflight-gate", "smp_init", lambda body: body.replace(
        "!smp_t6032_preflight(node)", "!true", 1),
        "FAIL: invalid inventory init fails through the preflight gate before release side effects")
    if STOP_TIMEOUT_ENABLED:
        variant("stop-timeout-returns", "smp_stop_cpu", lambda body: body.replace(
            "panic(\"SMP:", "printf(\"SMP:", 1),
            "FAIL: normal-stop timeout is non-returning and retains state")
        return 7
    return 6


def main() -> int:
    try:
        tree = materialize()
        sources = source_contracts(tree)
        bodies = function_bodies(tree)
        control_count = check_mutation_controls(sources)
        binary = compile_fixture(bodies)
        runtime_count = runtime_mutation_controls(tree, bodies)
        print(f"reviewed upstream SMP host regression passed; structural_controls={control_count}; runtime_controls={runtime_count}; binary={binary}")
        print("scope: source-extracted current SMP helpers; mock-only, no native/VM/MMIO/boot qualification")
        return 0
    except HarnessError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
