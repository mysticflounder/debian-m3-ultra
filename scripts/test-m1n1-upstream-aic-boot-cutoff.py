#!/usr/bin/env python3
"""Host ASan/UBSan tests for AIC status propagation into m1n1 startup.

The existing aperture fixture is assembled unchanged as a prefix, with its
main renamed.  This file appends the real source-extracted m1n1_main startup
prefix and bounded host mocks.  No native MMIO, firmware, VM, disk, network,
or boot qualification is performed.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
from typing import NoReturn


ROOT = pathlib.Path(__file__).resolve().parents[1]
APERTURE_RUNNER = ROOT / "scripts/test-m1n1-upstream-aic-aperture.py"
APERTURE_TEMPLATE = ROOT / "tests/m1n1-aic-aperture.c"
BOOT_TEMPLATE = ROOT / "tests/m1n1-aic-boot-cutoff.c"
PATCH_0027 = ROOT / "patches/m1n1/upstream-2460b60/0027-stop-on-aic-init-failure.patch"
SANITIZER_MARKERS = (
    "AddressSanitizer", "UndefinedBehaviorSanitizer", "runtime error:",
    "SUMMARY: AddressSanitizer", "SUMMARY: UndefinedBehaviorSanitizer",
    "RuntimeError", "runtime error", "ERROR:",
)


def fail(message: str) -> NoReturn:
    raise RuntimeError(message)


def load_aperture():
    spec = importlib.util.spec_from_file_location("aic_aperture_runner", APERTURE_RUNNER)
    if spec is None or spec.loader is None:
        fail("cannot load AIC aperture runner")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def extract_function(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        fail(f"missing function: {signature}")
    brace = source.find("{", start)
    if brace < 0:
        fail(f"missing function body: {signature}")
    depth = 0
    quote: str | None = None
    escaped = line_comment = block_comment = False
    for index in range(brace, len(source)):
        char = source[index]
        nxt = source[index + 1] if index + 1 < len(source) else ""
        if line_comment:
            if char == "\n":
                line_comment = False
        elif block_comment:
            if char == "*" and nxt == "/":
                block_comment = False
        elif quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
        elif char in "\"'":
            quote = char
        elif char == "/" and nxt == "/":
            line_comment = True
        elif char == "/" and nxt == "*":
            block_comment = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    fail(f"unterminated function: {signature}")


def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        fail(f"{label}: expected one source site, found {count}")
    return source.replace(old, new, 1)


def materialize(report: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path, str, str, str, list[pathlib.Path], str, dict[str, str]]:
    if not PATCH_0027.is_file() or not BOOT_TEMPLATE.is_file():
        fail("AIC boot patch or template missing")
    aperture = load_aperture()
    smp = aperture.load("aic_boot_smp", "test-m1n1-upstream-smp.py")
    memory = aperture.load("aic_boot_memory", "test-m1n1-upstream-memory-guards.py")
    cpufreq = aperture.load("aic_boot_cpufreq", "test-m1n1-upstream-cpufreq.py")
    tree, work, source = aperture.materialize()
    applied = aperture.run(
        ["patch", "-p1", "--batch", "--forward", "--fuzz=0",
         "--no-backup-if-mismatch", "-i", str(PATCH_0027)], tree)
    (report / "0027-apply.stdout").write_text(applied.stdout, encoding="utf-8")
    (report / "0027-apply.stderr").write_text(applied.stderr, encoding="utf-8")
    if applied.returncode:
        fail(f"0027 did not apply:\n{applied.stdout}{applied.stderr}")
    if any(tree.rglob("*.rej")):
        fail("patch reject artifacts remain")
    source_path = tree / "src/aic.c"
    main_path = tree / "src/main.c"
    header_path = tree / "src/aic.h"
    if any(not path.is_file() for path in (source_path, main_path, header_path)):
        fail("materialized AIC/main/header source missing")
    source = source_path.read_text(encoding="utf-8")
    main_source = main_path.read_text(encoding="utf-8")
    main_function = extract_function(main_source, "void m1n1_main(void)")
    start = main_function.find("    firmware_init();")
    end_marker = "    run_actions();"
    end = main_function.find(end_marker, start)
    if start < 0 or end < 0:
        fail("m1n1_main startup prefix markers missing")
    prefix = main_function[start:end + len(end_marker)]
    if prefix.count("aic_init()") != 1 or prefix.count("smp_init()") != 1:
        fail("startup prefix AIC/SMP call count changed")
    if prefix.find("aic_init()") > prefix.find("smp_init()"):
        fail("AIC call moved after SMP")
    guard = 'if (aic_init() < 0)\n        panic("AIC initialization failed!\\n");'
    if prefix.count(guard) != 1:
        fail("AIC startup cutoff guard missing or ambiguous")
    if "#ifndef BRINGUP" not in prefix:
        fail("BRINGUP startup guard missing")

    production_headers = report / "production-headers"
    host_include = report / "host-include"
    production_headers.mkdir(parents=True, exist_ok=True)
    host_include.mkdir(parents=True, exist_ok=True)
    source_hashes: dict[str, str] = {}
    for name in ("types.h", "aic.h", "aic_regs.h", "soc.h"):
        raw = (tree / "src" / name).read_bytes()
        source_hashes[name] = sha256_bytes(raw)
        (production_headers / name).write_bytes(raw)
        if name != "soc.h":
            host_data = raw.decode("utf-8")
            if name == "types.h":
                host_data = host_data.replace("typedef u64 uintptr_t;\n", "")
                host_data = host_data.replace("typedef s64 ptrdiff_t;\n", "")
                host_data = host_data.replace("typedef s64 ssize_t;\n", "")
            (host_include / name).write_text(host_data, encoding="utf-8")
    shutil.copy2(source_path, report / "aic.c")
    shutil.copy2(main_path, report / "main.c")
    shutil.copy2(header_path, report / "aic.h")
    (report / "startup-prefix.c").write_text(prefix, encoding="utf-8")
    soc_source = (tree / "src/soc.h").read_text(encoding="utf-8")
    soc_defines: list[str] = []
    for name in ("T6032", "T6031", "T6020"):
        match = re.search(rf"(?m)^#define {name}\s+[^\n]+$", soc_source)
        if match is None:
            fail(f"production soc.h missing {name}")
        soc_defines.append(match.group(0))
    soc_defines.append("#define AIC_TEST_LEGACY_CHIP T6020")
    patch_paths = ([ROOT / "patches/m1n1/upstream-2460b60" / name
                    for name in smp.PATCHES] +
                   list(memory.INPUT_PATCHES) + list(memory.MEMORY_PATCHES) +
                   list(cpufreq.DVFS_PATCHES) + list(aperture.PATCHES) + [PATCH_0027])
    if len(patch_paths) != 25 or any(not path.is_file() for path in patch_paths):
        fail("expected complete ordered 25-patch stack")
    return tree, host_include, source, prefix, patch_paths, "\n".join(soc_defines), source_hashes


def build_source(aic_source: str, startup_prefix: str, soc_defines: str) -> str:
    aperture = APERTURE_TEMPLATE.read_text(encoding="utf-8")
    boot = BOOT_TEMPLATE.read_text(encoding="utf-8")
    if boot.count("/* INSERT_SOC_DEFINES */") != 1:
        fail("production soc define marker is missing or ambiguous")
    if aperture.count("/* INSERT_AIC_SOURCE */") != 1:
        fail("aperture AIC source marker is missing or ambiguous")
    if aperture.count("int main(void)") != 1:
        fail("aperture main marker is missing or ambiguous")
    if boot.count("/* INSERT_MAIN_STARTUP_PREFIX */") != 1:
        fail("startup source marker is missing or ambiguous")
    assembled = aperture.replace("/* INSERT_AIC_SOURCE */", aic_source, 1)
    assembled = assembled.replace("int main(void)", "static int aperture_fixture_main(void)", 1)
    assembled += "\n\n" + boot.replace("/* INSERT_SOC_DEFINES */", soc_defines, 1)
    assembled = assembled.replace("/* INSERT_MAIN_STARTUP_PREFIX */",
                                          "void startup_prefix(void)\n{\n" + startup_prefix + "\n}", 1)
    return assembled


def run_command(command: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
    environment = {
        **os.environ,
        "ASAN_OPTIONS": "detect_leaks=0",
        "UBSAN_OPTIONS": "halt_on_error=1:print_stacktrace=1",
    }
    return subprocess.run(command, cwd=cwd, env=environment, text=True,
                          capture_output=True, timeout=90, check=False)


def execute(source: str, include: pathlib.Path, report: pathlib.Path, label: str,
            manifest: dict[str, object], defines: tuple[str, ...] = (),
            expected_failure: str | None = None) -> None:
    generated = report / f"{label}.c"
    binary = report / label
    generated.write_text(source, encoding="utf-8")
    clang = shutil.which("clang")
    if clang is None:
        fail("clang is required")
    command = [clang, "-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
               "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
               "-fno-omit-frame-pointer", "-I", str(include)]
    command.extend(f"-D{name}" for name in defines)
    command.extend([str(generated), "-o", str(binary)])
    variant: dict[str, object] = {
        "label": label,
        "defines": list(defines),
        "compiler_argv": command,
        "source_sha256": sha256_bytes(source.encode("utf-8")),
        "expected_exit": 1 if expected_failure is not None else 0,
        "expected_witness": expected_failure,
    }
    compiled = run_command(command, report)
    variant["compile_exit"] = compiled.returncode
    (report / f"{label}.compile.log").write_text(
        compiled.stdout + compiled.stderr, encoding="utf-8")
    if compiled.returncode:
        manifest.setdefault("variants", []).append(variant)
        fail(f"{label}: compile failed; see {label}.compile.log")
    result = run_command([str(binary)], report)
    output = result.stdout + result.stderr
    variant["run_exit"] = result.returncode
    variant["binary_sha256"] = sha256_bytes(binary.read_bytes()) if binary.is_file() else None
    manifest.setdefault("variants", []).append(variant)
    (report / f"{label}.run.log").write_text(output, encoding="utf-8")
    sanitizer = any(marker in output for marker in SANITIZER_MARKERS)
    if expected_failure is None:
        if result.returncode or sanitizer:
            fail(f"{label}: expected success, got {result.returncode}; see run log")
        return
    if result.returncode != 1 or sanitizer or expected_failure not in result.stderr:
        fail(f"{label}: designated failure missing; see run log")


def main() -> int:
    if shutil.which("clang") is None:
        fail("clang is required")
    report_root = ROOT / "scratch/aic-boot-cutoff-tests"
    report_root.mkdir(parents=True, exist_ok=True)
    report = pathlib.Path(tempfile.mkdtemp(prefix="run-", dir=report_root))
    manifest: dict[str, object] = {"status": "started", "run_directory": str(report)}
    try:
        (tree, include, aic_source, startup_prefix, patch_paths,
         soc_defines, source_hashes) = materialize(report)
        source = build_source(aic_source[aic_source.index("#define MASK_REG"):],
                              startup_prefix, soc_defines)
        source_hashes["main.c"] = sha256_bytes((tree / "src/main.c").read_bytes())
        source_hashes["aic-aperture-template.c"] = sha256_bytes(
            APERTURE_TEMPLATE.read_bytes())
        source_hashes["aic-boot-cutoff-template.c"] = sha256_bytes(
            BOOT_TEMPLATE.read_bytes())
        manifest.update({
            "patch_order": [path.name for path in patch_paths],
            "patch_count": len(patch_paths),
            "patch_hashes": {path.name: sha256_bytes(path.read_bytes()) for path in patch_paths},
            "materialized_tree": str(tree),
            "aic_source_sha256": sha256_bytes(aic_source.encode("utf-8")),
            "startup_prefix_sha256": sha256_bytes(startup_prefix.encode("utf-8")),
            "generated_source_sha256": sha256_bytes(source.encode("utf-8")),
            "source_hashes": source_hashes,
            "aic_source_bytes": len(aic_source.encode("utf-8")),
            "startup_prefix_bytes": len(startup_prefix.encode("utf-8")),
            "fixture": str(BOOT_TEMPLATE),
            "scope": "host mock only; no native/MMIO qualification",
        })
        execute(source, include, report, "baseline", manifest)
        execute(source, include, report, "baseline-bringup", manifest, ("BRINGUP",))
        bad_footer = replace_once(aic_source, "return aic ? 0 : -1;", "return 0;",
                                  "AIC status footer")
        bad_footer_source = build_source(
            bad_footer[bad_footer.index("#define MASK_REG"):], startup_prefix, soc_defines)
        execute(bad_footer_source, include, report, "mutation-footer-success", manifest,
                expected_failure="FAIL: AIC1 IRQ capacity returned success")
        skip_guard = replace_once(
            startup_prefix,
            'if (aic_init() < 0)\n        panic("AIC initialization failed!\\n");',
            'if (aic_init() < 0 && false)\n        panic("AIC initialization failed!\\n");',
            "startup AIC cutoff")
        execute(build_source(aic_source[aic_source.index("#define MASK_REG"):],
                skip_guard, soc_defines), include, report,
                "mutation-skip-cutoff", manifest,
                expected_failure="FAIL: T6032 AIC1-short failure reached SMP/actions")
        moved = replace_once(
            startup_prefix,
            'if (aic_init() < 0)\n        panic("AIC initialization failed!\\n");\n    smp_init();',
            'aic_init();\n    smp_init();\n    if (!aic)\n        panic("AIC initialization failed!\\n");',
            "startup AIC cutoff location")
        execute(build_source(aic_source[aic_source.index("#define MASK_REG"):],
                             moved, soc_defines), include, report,
                "mutation-cutoff-after-smp", manifest,
                expected_failure="FAIL: T6032 AIC1-short failure reached SMP/actions")
        bringup_aic = replace_once(
            startup_prefix,
            "    run_actions();",
            "#ifdef BRINGUP\n    (void)aic_init();\n#endif\n    run_actions();",
            "BRINGUP AIC bypass")
        execute(build_source(aic_source[aic_source.index("#define MASK_REG"):],
                             bringup_aic, soc_defines), include, report,
                "mutation-bringup-aic", manifest, ("BRINGUP",),
                expected_failure="FAIL: BRINGUP unexpectedly ran AIC")
        manifest["status"] = "passed"
        (report / "result.txt").write_text(
            "baseline + BRINGUP + footer/skip/location mutation checks passed\n",
            encoding="utf-8")
    except Exception as exc:
        manifest["status"] = "failed"
        manifest["error"] = str(exc)
        raise
    finally:
        manifest["artifact_paths"] = sorted(
            {str(path.relative_to(report)) for path in report.rglob("*") if path.is_file()}
            | {"manifest.json"})
        (report / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n",
                                               encoding="utf-8")
    print(f"AIC boot-cutoff artifacts: {report}")
    print("AIC boot-cutoff harness: status, startup, BRINGUP and mutation checks passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(f"AIC boot-cutoff harness: ERROR: {exc}")
        raise SystemExit(1)
