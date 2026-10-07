#!/usr/bin/env python3
"""Reviewed-source six-cluster DVFS and payload mock tests; never native MMIO.

Materializes the hash-pinned archive and the complete 21-patch comparison
stack. The actual cpufreq.c body and payload caller prefix run against safe
host mocks. This is not qualification of raw boot states or hardware effects.
"""

from __future__ import annotations

import importlib.util
import os
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
PATCH_DIR = ROOT / "patches/m1n1/upstream-2460b60"
DVFS_PATCHES = (
    PATCH_DIR / "0011-propagate-t6032-cpufreq-failures.patch",
    PATCH_DIR / "0023-contain-t6032-cpufreq-cluster-failures.patch",
)
TEMPLATE = ROOT / "tests/m1n1-upstream-cpufreq.c"


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def replace_once(source: str, old: str, new: str) -> str:
    if source.count(old) != 1:
        raise RuntimeError(f"missing/ambiguous source or mutation target: {old!r}")
    return source.replace(old, new, 1)


def materialize():
    memory = load("reviewed_memory_helpers", "test-m1n1-upstream-memory-guards.py")
    smp = load("reviewed_smp_materializer", "test-m1n1-upstream-smp.py")
    if tuple(smp.PATCHES) != memory.EXPECTED_SMP_PATCHES:
        raise RuntimeError("SMP stack changed; reconcile DVFS evidence")
    paths = (tuple(PATCH_DIR / name for name in smp.PATCHES) +
             memory.INPUT_PATCHES + memory.MEMORY_PATCHES + DVFS_PATCHES)
    if len(paths) != 21 or len(set(paths)) != 21:
        raise RuntimeError("expected exactly 21 unique comparison patches")
    tree = smp.materialize()
    memory_baseline = {name: (tree / f"src/{name}.c").read_text(encoding="utf-8")
                       for name in ("mcc", "memory")}
    for patch in (*memory.INPUT_PATCHES, *memory.MEMORY_PATCHES):
        result = memory.run(["patch", "-p1", "--batch", "--forward", "--fuzz=0",
                             "-i", str(patch)], tree)
        if result.returncode:
            raise RuntimeError(f"{patch.name} did not apply:\n{result.stdout}{result.stderr}")
    before = {name: (tree / f"src/{name}.c").read_text(encoding="utf-8")
              for name in ("cpufreq", "payload", "proxy")}
    log = []
    for patch in DVFS_PATCHES:
        result = memory.run(["patch", "-p1", "--batch", "--forward", "--fuzz=0",
                             "-i", str(patch)], tree)
        log.append(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"{patch.name} did not apply:\n{log[-1]}")
    if any(tree.rglob("*.rej")):
        raise RuntimeError("patch reject artifacts remain")
    work = tree.parent / "cpufreq-guards"
    work.mkdir()
    (work / "dvfs-patch.log").write_text("".join(log), encoding="utf-8")
    memory.audit_contracts(tree, memory_baseline, smp)
    return tree, work, before, memory, smp


def fixture_source(tree: pathlib.Path, before: dict[str, str], memory, smp) -> str:
    cpufreq = (tree / "src/cpufreq.c").read_text(encoding="utf-8")
    payload = (tree / "src/payload.c").read_text(encoding="utf-8")
    old_loop = "        err |= cpufreq_init_cluster(cluster++, features);"
    new_loop = ("        int status = cpufreq_init_cluster(cluster++, features);\n"
                "        if (chip_id == T6032 && status < 0)\n"
                "            return status;\n        err |= status;")
    if cpufreq != replace_once(before["cpufreq"], old_loop, new_loop):
        raise RuntimeError("0023 altered the driver beyond T6032 fail-fast containment")
    old_call = "        cpufreq_init();"
    new_call = ("        int cpufreq_status = cpufreq_init();\n"
                "        if (chip_id == T6032 && cpufreq_status < 0)\n"
                "            return -1;")
    if payload != replace_once(before["payload"], old_call, new_call):
        raise RuntimeError("0011 changed more than its local payload cutoff")
    proxy = (tree / "src/proxy.c").read_text(encoding="utf-8")
    if proxy != before["proxy"] or "reply->retval = cpufreq_init();" not in proxy:
        raise RuntimeError("proxy DVFS return contract changed")
    caller = smp.extract_function(payload, "payload_run")
    start = caller.index("if (kernel && fdt) {")
    end = caller.index("mitigations_perform();", start) + len("mitigations_perform();")
    fragment = caller[start:end] + "\n    }"
    if fragment.count("cpufreq_init(") != 1 or fragment.count("smp_start_secondaries(") != 1:
        raise RuntimeError("payload cpufreq/SMP prefix changed")
    types = (tree / "src/types.h").read_text(encoding="utf-8")
    soc = (tree / "src/soc.h").read_text(encoding="utf-8")
    firmware = (tree / "src/firmware.h").read_text(encoding="utf-8")
    code = re.sub(r"/\*.*?\*/|//[^\n]*", "", cpufreq, flags=re.S)
    names = sorted(set(re.findall(r"\b(?:T\d{4}|S\d[A-Z0-9]*)\b", code)))
    names = sorted(set(names) | {"T6032", "T6031"})
    defines = []
    for name in names:
        match = re.search(rf"(?m)^#define {name}\s+[^\n]+", soc)
        if match is None:
            raise RuntimeError(f"source chip constant missing: {name}")
        defines.append(match.group(0))
    for name in ("BIT", "MASK", "GENMASK", "_FIELD_LSB", "FIELD_PREP", "FIELD_GET"):
        match = re.search(rf"(?m)^#define {name}\([^\n]+", types)
        if match is None:
            raise RuntimeError(f"source bit macro missing: {name}")
        defines.append(match.group(0))
    enum = re.search(r"(?ms)^enum fw_version \{.*?^\};", firmware)
    if enum is None:
        raise RuntimeError("source firmware enum missing")
    defines.append(enum.group(0))
    body_start = cpufreq.index("#define CLUSTER_PSTATE ")
    return memory.replace_markers(TEMPLATE, {
        "INSERT_SOURCE_DEFINES": "\n".join(defines),
        "INSERT_CPUFREQ_SOURCE": cpufreq[body_start:],
        "INSERT_PAYLOAD_CPUFREQ_FRAGMENT": fragment,
    })


def execute(source: str, label: str, work: pathlib.Path, clang: str,
            expected_failure: str | None = None) -> None:
    generated = work / f"{label}.c"
    binary = work / label
    generated.write_text(source, encoding="utf-8")
    environment = {**os.environ, "ASAN_OPTIONS": "detect_leaks=0",
                   "UBSAN_OPTIONS": "halt_on_error=1:print_stacktrace=1"}
    compiled = subprocess.run([
        clang, "-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
        "-Wno-missing-field-initializers", "-fno-omit-frame-pointer",
        "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
        str(generated), "-o", str(binary),
    ], cwd=work, env=environment, text=True, capture_output=True, timeout=60)
    (work / f"{label}-compile.log").write_text(compiled.stdout + compiled.stderr,
                                               encoding="utf-8")
    if compiled.returncode:
        raise RuntimeError(f"{label} compile failed; see retained compile log")
    result = subprocess.run([str(binary)], cwd=work, env=environment, text=True,
                            capture_output=True, timeout=60)
    output = result.stdout + result.stderr
    (work / f"{label}.log").write_text(output, encoding="utf-8")
    sanitizer_failure = any(token in output for token in (
        "AddressSanitizer", "UndefinedBehaviorSanitizer", "runtime error:",
    ))
    if expected_failure is not None:
        if result.returncode != 1 or sanitizer_failure or expected_failure not in output:
            raise RuntimeError(f"{label} did not fail at its designated assertion; see log")
        print(f"{label}: designated assertion rejected (sanitizers clean)")
    elif result.returncode or sanitizer_failure:
        raise RuntimeError(f"{label} fixture failed; see retained log")
    else:
        print(f"{label}: PASS; log: {work / (label + '.log')}")


def main() -> int:
    clang = shutil.which("clang")
    if clang is None:
        raise RuntimeError("clang required for host fixtures")
    tree, work, before, memory, smp = materialize()
    source = fixture_source(tree, before, memory, smp)
    execute(source, "cpufreq-baseline", work, clang)
    execute(replace_once(source, "chip_id == T6032 && status < 0",
                         "false && status < 0"),
            "cpufreq-missing-fail-fast", work, clang,
            "T6032 DVFS continued after failed cluster")
    execute(replace_once(source, "chip_id == T6032 && cpufreq_status < 0",
                         "false && cpufreq_status < 0"),
            "cpufreq-missing-payload-cutoff", work, clang,
            "T6032 DVFS failure reached secondary startup")
    restore = ("        case T6030 ... T6034:\n        case T8122:\n"
               "            /* Unknown */\n"
               "            write64(cluster->base + 0x440f8, 1);")
    execute(replace_once(source, restore, restore.rsplit("\n", 1)[0]),
            "cpufreq-missing-restore", work, clang,
            "DVFS event/order mismatch")
    for label, fixture in memory.fixtures(tree).items():
        memory.compile_fixture(fixture, f"full-stack-{label}", work, clang)
    print(f"Retained reviewed source: {tree}")
    print(f"Retained host evidence: {work}")
    print("Scope: actual DVFS driver and payload prefix with mocks; no native/MMIO qualification")
    return 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
