#!/usr/bin/env python3
"""Offline source-extracted AIC aperture/stride regression.

Materializes the reviewed 21-patch stack, applies ADT 0024/0025 and AIC
0026 with zero fuzz, and runs bounded host observers.  It never performs
physical MMIO or native/firmware/VM/disk operations.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
PATCH_DIR = ROOT / "patches/m1n1/upstream-2460b60"
PATCHES = (
    PATCH_DIR / "0024-check-adt-physical-spans.patch",
    PATCH_DIR / "0025-check-adt-boot-relocation.patch",
    PATCH_DIR / "0026-bound-aic-register-aperture.patch",
)
TEMPLATE = ROOT / "tests/m1n1-aic-aperture.c"
FIXTURE_GROUPS = (
    "valid_layouts", "single_die_zero_stride", "large_stride_cast",
    "aperture_rejections", "stride_and_capacity_guards",
    "existing_metadata_guards", "runtime_guards",
)
SANITIZER_MARKERS = (
    "AddressSanitizer", "UndefinedBehaviorSanitizer", "runtime error:",
    "SUMMARY: AddressSanitizer", "SUMMARY: UndefinedBehaviorSanitizer",
    "RuntimeError", "runtime error", "ERROR:",
)


def fail(message: str) -> None:
    raise RuntimeError(message)


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    if spec is None or spec.loader is None:
        fail(f"cannot load {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(command: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        check=False, timeout=120,
        env={**os.environ, "ASAN_OPTIONS": "detect_leaks=0",
             "UBSAN_OPTIONS": "halt_on_error=1:print_stacktrace=1"},
    )


def apply_patch(tree: pathlib.Path, patch: pathlib.Path) -> None:
    result = run(["patch", "-p1", "--batch", "--forward", "--fuzz=0",
                  "--no-backup-if-mismatch", "-i", str(patch)], tree)
    if result.returncode:
        fail(f"{patch.name} did not apply:\n{result.stdout}{result.stderr}")


def materialize() -> tuple[pathlib.Path, pathlib.Path, str]:
    if not TEMPLATE.is_file() or any(not p.is_file() for p in PATCHES):
        fail("AIC aperture template or patch is missing")
    cpufreq = load("aic_reviewed_cpufreq_materializer", "test-m1n1-upstream-cpufreq.py")
    tree, work, _before, _memory, _smp = cpufreq.materialize()
    for patch in PATCHES:
        apply_patch(tree, patch)
    if any(tree.rglob("*.rej")):
        fail("patch reject artifacts remain")
    source_path = tree / "src/aic.c"
    if not source_path.is_file():
        fail("materialized AIC source is missing")
    source = source_path.read_text(encoding="utf-8")
    if source.count("#define MASK_REG") != 1:
        fail("AIC source body marker is missing or ambiguous")
    include = work / "aic-aperture-include"
    include.mkdir(exist_ok=True)
    for name in ("types.h", "aic.h", "aic_regs.h"):
        data = (tree / "src" / name).read_text(encoding="utf-8")
        if name == "types.h":
            # The production header's freestanding typedefs conflict with
            # Darwin libc; preserve its integer/bit macros while making this
            # host-only copy ABI-neutral.  aic.h/aic_regs.h are byte-for-byte.
            data = data.replace("typedef u64 uintptr_t;\n", "")
            data = data.replace("typedef s64 ptrdiff_t;\n", "")
            data = data.replace("typedef s64 ssize_t;\n", "")
        (include / name).write_text(data, encoding="utf-8")
    return tree, work, source


def body(source: str) -> str:
    return source[source.index("#define MASK_REG"):]


def replace_once(source: str, old: str, new: str, label: str) -> str:
    if source.count(old) != 1:
        fail(f"{label}: expected one source site")
    return source.replace(old, new, 1)


def mutate_no_aperture_guard(source: str) -> str:
    old = "if (!aic->base || (aic->base & 3) || !aic_aperture ||\n        aic_aperture > UINT64_MAX - aic->base)"
    new = "if (false && (!aic->base || (aic->base & 3) || !aic_aperture ||\n        aic_aperture > UINT64_MAX - aic->base))"
    return replace_once(source, old, new, "public aperture guard")


def mutate_no_stride_guard(source: str) -> str:
    old = "if ((stride & 3) || (aic->nr_die > 1 && stride < size))"
    new = "if (false && ((stride & 3) || (aic->nr_die > 1 && stride < size)))"
    return replace_once(source, old, new, "bank stride guard")


def mutate_no_capacity_guard(source: str) -> str:
    old = ("if (!aic->max_irq || aic->max_irq > AIC_MAX_HW_NUM || (aic->max_irq & 31) ||\n"
           "        aic->nr_irq > aic->max_irq)")
    new = ("if (false && (!aic->max_irq || aic->max_irq > AIC_MAX_HW_NUM || (aic->max_irq & 31) ||\n"
           "        aic->nr_irq > aic->max_irq))")
    return replace_once(source, old, new, "IRQ capacity guard")


def mutate_no_u64_die_cast(source: str) -> str:
    return replace_once(source, "(u64)die * aic->extintrcfg_stride",
                        "die * aic->extintrcfg_stride", "die-stride cast")


def compile_and_run(work: pathlib.Path, source: str, label: str) -> subprocess.CompletedProcess[str]:
    marker = "/* INSERT_AIC_SOURCE */"
    template = TEMPLATE.read_text(encoding="utf-8")
    if template.count(marker) != 1:
        fail("AIC aperture template marker is missing or ambiguous")
    generated = work / f"{label}.c"
    binary = work / label
    generated.write_text(template.replace(marker, body(source)), encoding="utf-8")
    clang = shutil.which("clang")
    if clang is None:
        fail("clang is required")
    compiled = run([clang, "-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
                    "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                    "-fno-omit-frame-pointer", "-I", str(work / "aic-aperture-include"),
                    str(generated), "-o", str(binary)], work)
    (work / f"{label}.compile.stdout").write_text(compiled.stdout, encoding="utf-8")
    (work / f"{label}.compile.stderr").write_text(compiled.stderr, encoding="utf-8")
    (work / f"{label}.compile.log").write_text(
        compiled.stdout + compiled.stderr, encoding="utf-8")
    if compiled.returncode:
        fail(f"{label}: clang failed:\n{compiled.stdout}{compiled.stderr}")
    result = run([str(binary)], work)
    (work / f"{label}.run.stdout").write_text(result.stdout, encoding="utf-8")
    (work / f"{label}.run.stderr").write_text(result.stderr, encoding="utf-8")
    (work / f"{label}.run.log").write_text(
        result.stdout + result.stderr, encoding="utf-8")
    return result


def expect_success(result: subprocess.CompletedProcess[str], label: str) -> None:
    text = result.stdout + result.stderr
    if result.returncode or any(marker in text for marker in SANITIZER_MARKERS):
        fail(f"{label}: expected success, got {result.returncode}:\n{result.stdout}{result.stderr}")


def expect_failure(result: subprocess.CompletedProcess[str], label: str, diagnostic: str) -> None:
    text = result.stdout + result.stderr
    if result.returncode != 1:
        fail(f"{label}: expected exact exit 1, got {result.returncode}:\n{text}")
    if diagnostic not in result.stderr:
        fail(f"{label}: missing designated diagnostic {diagnostic!r}:\n{text}")
    if any(marker in text for marker in SANITIZER_MARKERS):
        fail(f"{label}: sanitizer/runtime diagnostic masked designated failure:\n{text}")


def main() -> int:
    report_root = ROOT / "scratch/aic-aperture-tests"
    report_root.mkdir(parents=True, exist_ok=True)
    report = pathlib.Path(tempfile.mkdtemp(prefix="run-", dir=report_root))
    manifest: dict[str, object] = {
        "status": "started",
        "patch_order": [patch.name for patch in PATCHES],
        "comparison_stack_count": 21,
        "fixture_group_count": len(FIXTURE_GROUPS),
        "fixture_groups": list(FIXTURE_GROUPS),
        "template_sha256": hashlib.sha256(TEMPLATE.read_bytes()).hexdigest(),
        "artifact_paths": [],
        "run_directory": str(report),
    }
    try:
        _tree, work, source = materialize()
        manifest["source_sha256"] = hashlib.sha256(source.encode("utf-8")).hexdigest()
        manifest["source_bytes"] = len(source.encode("utf-8"))
        # Keep the materialized headers/source available beside generated logs.
        (report / "aic.c").write_text(source, encoding="utf-8")
        include = report / "aic-aperture-include"
        include.mkdir()
        production = report / "production-headers"
        production.mkdir()
        for name in ("types.h", "aic.h", "aic_regs.h"):
            shutil.copy2(work / "aic-aperture-include" / name, include / name)
            shutil.copy2(_tree / "src" / name, production / name)
        baseline = compile_and_run(report, source, "baseline")
        expect_success(baseline, "baseline")
        mutations = (
            ("mutation-no-aperture-guard", mutate_no_aperture_guard(source),
             "FAIL: null AIC base read MMIO"),
            ("mutation-no-stride-guard", mutate_no_stride_guard(source),
             "FAIL: short multi-die config bank was accepted"),
            ("mutation-no-capacity-guard", mutate_no_capacity_guard(source),
             "FAIL: zero max IRQ was accepted"),
            ("mutation-no-u64-die-cast", mutate_no_u64_die_cast(source),
             "FAIL: large die stride wrapped before 64-bit multiplication"),
        )
        manifest["mutation_diagnostics"] = {label: diagnostic for label, _source, diagnostic in mutations}
        for label, mutated, diagnostic in mutations:
            expect_failure(compile_and_run(report, mutated, label), label, diagnostic)
        (report / "result.txt").write_text(
            "baseline + 4 designated AIC aperture/stride mutations passed\n", encoding="utf-8")
        manifest["status"] = "passed"
    except Exception as exc:
        manifest["status"] = "failed"
        manifest["error"] = str(exc)
        raise
    finally:
        manifest["artifact_paths"] = sorted(
            {str(path.relative_to(report)) for path in report.rglob("*") if path.is_file()}
            | {"manifest.json"})
        (report / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"AIC aperture/stride artifacts: {report}")
    print("AIC aperture/stride harness: baseline + 4 mutation checks passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(f"AIC aperture harness: ERROR: {exc}")
        raise SystemExit(1)
