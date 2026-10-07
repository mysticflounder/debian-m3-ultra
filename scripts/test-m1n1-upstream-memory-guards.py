#!/usr/bin/env python3
"""Exercise reviewed-upstream MCC/MMU helpers with retained host-only fixtures.

No legacy extractor materializer or main() is called. The reviewed source
archive is hash checked by the SMP materializer; all comparison guards apply at zero
fuzz in a fresh retained tree. Compiler outputs and fixtures remain in scratch.
These are mock tests, not native register/cache/CPU-entry qualification.
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
EXPECTED_SMP_PATCHES = (
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
INPUT_PATCHES = (
    PATCH_DIR / "0019-validate-aic-init-metadata.patch",
    ROOT / "patches/m1n1/0020-check-adt-copy-length-before-write.patch",
    ROOT / "patches/m1n1/0021-fix-adt-property-view-length.patch",
)
MEMORY_PATCHES = tuple(PATCH_DIR / name for name in (
    "0008-validate-t6032-mcc-layout.patch",
    "0009-preflight-t6032-carveout-removal.patch",
    "0010-guard-t6032-runtime-mappings.patch",
    "0012-decode-t6032-tz-relative-origin.patch",
    "0013-check-t6032-tz-plane-consistency.patch",
    "0014-reject-uninitialized-t6032-mmu-entry.patch",
    "0016-protect-smp-shared-mappings.patch",
))


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def replace_markers(template: pathlib.Path, replacements: dict[str, str]) -> str:
    source = template.read_text(encoding="utf-8")
    for name, replacement in replacements.items():
        marker = f"/* {name} */"
        if source.count(marker) != 1:
            raise RuntimeError(f"missing/ambiguous fixture marker {name} in {template}")
        source = source.replace(marker, replacement)
    if re.search(r"/\*\s*INSERT_\w+\s*\*/", source):
        raise RuntimeError(f"unfilled insertion marker in {template}")
    return source


def run(command: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["ASAN_OPTIONS"] = "detect_leaks=0"
    environment["UBSAN_OPTIONS"] = "halt_on_error=1:print_stacktrace=1"
    return subprocess.run(command, cwd=cwd, env=environment, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          check=False, timeout=60)


def compile_fixture(source: str, label: str, work: pathlib.Path, clang: str,
                    expected_failure: str | None = None) -> None:
    generated = work / f"{label}.c"
    binary = work / label
    generated.write_text(source, encoding="utf-8")
    result = run([clang, "-std=c11", "-O1", "-g", "-fno-omit-frame-pointer",
                  "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                  str(generated), "-o", str(binary)], work)
    if result.returncode:
        raise RuntimeError(f"{label} compile failed:\n{result.stdout}{result.stderr}")
    result = run([str(binary)], work)
    (work / f"{label}.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    output = result.stdout + result.stderr
    sanitizer_failure = any(token in output for token in (
        "AddressSanitizer", "UndefinedBehaviorSanitizer", "runtime error:",
    ))
    if expected_failure is not None:
        if result.returncode != 1 or sanitizer_failure or expected_failure not in output:
            raise RuntimeError(f"{label} did not fail for its designated assertion:\n{output}")
        print(f"{label}: designated assertion rejected (sanitizers clean)")
        return
    if result.returncode or sanitizer_failure:
        raise RuntimeError(f"{label} fixture failed:\n{result.stdout}{result.stderr}")
    print(f"{label}: PASS; {result.stdout.strip()}")


def audit_contracts(tree: pathlib.Path, baseline: dict[str, str], smp) -> None:
    """Check current caller coupling separately from executed unit fixtures."""
    texts = {name: (tree / f"src/{name}.c").read_text(encoding="utf-8")
             for name in ("mcc", "memory", "smp", "main", "kboot")}

    def body(module: str, name: str) -> str:
        return smp.extract_function(texts[module], name)

    def order(source: str, *tokens: str) -> None:
        offsets = [source.find(token) for token in tokens]
        if any(offset < 0 for offset in offsets) or offsets != sorted(set(offsets)):
            raise RuntimeError(f"missing/out-of-order source contract: {tokens}")

    init = body("mcc", "mcc_init")
    order(init, "mcc_t6032_invalidate();", "adt_path_offset_trace(",
          "return mcc_init_t6032(", "adt_is_compatible(")
    for name in ("mcc_init_m3", "mcc_init_t6031"):
        if body("mcc", name) != smp.extract_function(baseline["mcc"], name):
            raise RuntimeError(f"non-specialized upstream MCC initializer changed: {name}")
    wrapper = body("mcc", "mcc_unmap_carveouts")
    legacy = re.sub(r"\n    if \(chip_id == T6032\)\n        return -1;[^\n]*\n",
                    "\n", wrapper, count=1)
    if legacy != smp.extract_function(baseline["mcc"], "mcc_unmap_carveouts"):
        raise RuntimeError("legacy carveout wrapper changed beyond T6032 rejection")
    main = body("main", "m1n1_main")
    if not re.search(r'if \(chip_id == T6032\)\s*\{\s*if \(mcc_init\(\) < 0\)'
                     r'\s*panic\("T6032 MCC initialization failed!\\n"\);', main):
        raise RuntimeError("T6032 main MCC failure cutoff missing")
    order(main, "mcc_init()", "mmu_init();", "aic_init();", "smp_init()")
    boot = body("kboot", "kboot_boot")
    order(boot, "int mcc_ret = mcc_enable_cache();",
          "if (chip_id == T6032 && mcc_ret < 0)", "tunables_apply_static(")
    default = body("memory", "mmu_add_default_mappings")
    order(default, "mmu_remap_ranges();", "mmu_remap_smp_shared();",
          "mcc_unmap_carveouts_t6032(ram_size)")
    if "if (chip_id != T6032)\n        mcc_unmap_carveouts();" not in default:
        raise RuntimeError("legacy default-map carveout path missing")
    tail = default[default.index("mcc_unmap_carveouts_t6032(ram_size)"):]
    if re.search(r"\bmmu_(?:add_mapping|remap\w*)\s*\(", tail):
        raise RuntimeError("default mapping stage occurs after T6032 carveout removal")
    mmu_init = body("memory", "mmu_init")
    order(mmu_init, "if (read_sctlr() & SCTLR_M)",
          "t6032_mmu_initialized = false;", "mcc_t6032_begin_carveout_setup();",
          "mmu_init_pagetables();", "mmu_add_default_mappings();",
          "mmu_configure();", "write_sctlr(sctlr);", "t6032_mmu_initialized = true;")
    if "chip_id == T6032 && !t6032_mmu_initialized" not in mmu_init:
        raise RuntimeError("inherited-MMU lifecycle rejection missing")
    for name in ("mmu_disable", "mmu_restore"):
        if any(token in body("memory", name) for token in (
            "t6032_mmu_initialized", "mcc_t6032_begin_carveout_setup",
        )):
            raise RuntimeError(f"temporary MMU state change resets protection: {name}")
    order(body("mcc", "mcc_unmap_carveouts_t6032"),
          "if (mcc_carveouts_ready)", "mmu_rm_mapping(",
          "memcpy(mcc_carveouts, staged", "mcc_carveout_count = count;",
          "mcc_carveouts_ready = true;")
    for name, effect in (("mmu_add_mapping", "mmu_map("),
                         ("mmu_map_framebuffer", "dc_civac_range(")):
        order(body("memory", name), "mmu_smp_shared_mapping_allowed(",
              "mmu_t6032_mapping_allowed(", effect)
    order(body("memory", "mmu_rm_mapping"), "mmu_smp_shared_removal_allowed(", "mmu_map(")
    if "mmu_smp_shared_ready_state = false;" not in body("memory", "mmu_init_pagetables"):
        raise RuntimeError("page-table rebuild does not reset shared readiness")
    remap = body("memory", "mmu_remap_smp_shared")
    maps = [match.start() for match in re.finditer(r"(?m)^\s*mmu_add_mapping\(", remap)]
    if len(maps) != 4 or remap.find("mmu_smp_shared_ready_state = true;") < max(maps):
        raise RuntimeError("shared readiness is not after all four current remaps")
    order(body("smp", "smp_start_secondaries"), "mmu_smp_start_allowed()", "smp_initialized")
    leaf = body("smp", "smp_start_cpu")
    gate = leaf.find("if (!mmu_smp_start_allowed())")
    prefix = " ".join(leaf[leaf.find("{") + 1:gate].split())
    if gate < 0 or prefix != "int i; if (index < 0 || index >= MAX_CPUS) return false;":
        raise RuntimeError("cached SMP leaf readiness gate is not after only the index guard")
    print("current MCC/MMU/SMP caller contracts: PASS (structural)")


def fixtures(tree: pathlib.Path) -> dict[str, str]:
    layout = load("layout_source_extractors", "test-m1n1-mcc-layout.py")
    carveout = load("carveout_source_extractors", "test-m1n1-carveout-preflight.py")
    mapping = load("mapping_source_extractors", "test-m1n1-mapping-guard.py")
    shared = load("shared_source_extractors", "test-m1n1-smp-shared-guard.py")
    mcc = (tree / "src/mcc.c").read_text(encoding="utf-8")
    memory = (tree / "src/memory.c").read_text(encoding="utf-8")
    memory_h = (tree / "src/memory.h").read_text(encoding="utf-8")
    # Existing fixtures intentionally model the captured 20-entry/16-controller/
    # four-plane geometry. Fail rather than silently reuse them after source drift.
    for name, expected in (("T6032_MCC_HEADER_COUNT", 4), ("T6032_MCC_ENTRY_COUNT", 20),
                           ("T6032_MCC_INSTANCE_COUNT", 16), ("T6032_MCC_REG_OFFSET", 4),
                           ("PLANE_TZ_MAX_REGS", 4)):
        match = re.search(rf"(?m)^#define\s+{name}\s+(0x[0-9a-fA-F]+|[0-9]+)\s*$", mcc)
        if match is None or int(match.group(1), 0) != expected:
            raise RuntimeError(f"source geometry changed; update retained fixtures: {name}")
    fragment = layout.source_fragment(mcc)
    definitions, helpers = fragment.split("#define T6032_MCC_HEADER_COUNT", 1)
    result = {"mcc-layout": replace_markers(layout.TEMPLATE, {
        "INSERT_MCC_DEFS": definitions,
        "INSERT_MCC_SOURCE": "#define T6032_MCC_HEADER_COUNT" + helpers,
        "INSERT_FIRMWARE_FIXTURES": layout.fixture_source(),
    })}
    result["carveout-preflight"] = replace_markers(carveout.TEMPLATE, {
        "INSERT_MCC_DEFS": carveout.harness_defines(mcc, memory_h),
        "INSERT_MCC_SOURCE": carveout.source_fragment(mcc),
    })
    definitions, functions = mapping.source_fragment(mcc, memory, memory_h)
    result["mapping-guard"] = replace_markers(mapping.TEMPLATE, {
        "INSERT_GUARD_DEFS": definitions,
        "INSERT_GUARD_SOURCE": functions,
    })
    variable = re.search(r"^static bool t6032_mmu_initialized;\s*$", memory, re.M)
    if variable is None:
        raise RuntimeError("current-source MMU lifecycle latch missing")
    arm_regs = (tree / "src/arm_cpu_regs.h").read_text(encoding="utf-8")
    soc = (tree / "src/soc.h").read_text(encoding="utf-8")
    definitions = [mapping.extract_define(arm_regs, name) for name in (
        "SCTLR_LSMAOE", "SCTLR_nTLSMD", "SCTLR_TSCXT", "SCTLR_ITD",
        "SCTLR_I", "SCTLR_C", "SCTLR_M", "SCTLR_SPAN",
    )]
    definitions.extend(mapping.extract_define(soc, name) for name in ("T6031", "T6032"))
    result["mmu-entry"] = replace_markers(ROOT / "tests/m1n1-mmu-entry.c", {
        "INSERT_MMU_DEFINES": "\n".join(definitions),
        "INSERT_MMU_STATE": variable.group(0),
        "INSERT_MMU_SOURCE": mapping.extract_function(memory, "void mmu_init(void)"),
    })
    ready, definitions, functions = shared.source_parts(memory, memory_h)
    ready_name = re.search(r"static bool\s+(\w+)", ready).group(1)
    result["smp-shared-guard"] = replace_markers(shared.TEMPLATE, {
        "INSERT_MEMORY_DEFINES": definitions,
        "INSERT_GUARD_SOURCE": ready + "\n\n" + functions,
        "INSERT_TEST_ADAPTERS": shared.make_adapter(ready_name),
    })
    return result


def main() -> int:
    smp = load("reviewed_smp_materializer", "test-m1n1-upstream-smp.py")
    clang = shutil.which("clang")
    if clang is None:
        raise RuntimeError("clang required for host fixtures")
    if tuple(smp.PATCHES) != EXPECTED_SMP_PATCHES:
        raise RuntimeError("SMP materializer patch order changed; reconcile memory evidence")
    patch_paths = tuple(PATCH_DIR / name for name in EXPECTED_SMP_PATCHES) + INPUT_PATCHES + MEMORY_PATCHES
    if len(patch_paths) != 19 or len(set(patch_paths)) != 19:
        raise RuntimeError("expected exactly 19 unique comparison patches")
    tree = smp.materialize()
    baseline = {name: (tree / f"src/{name}.c").read_text(encoding="utf-8")
                for name in ("mcc", "memory")}
    for patch in (*INPUT_PATCHES, *MEMORY_PATCHES):
        result = run(["patch", "-p1", "--batch", "--forward", "--fuzz=0",
                      "-i", str(patch)], tree)
        if result.returncode:
            raise RuntimeError(f"{patch.name} did not apply:\n{result.stdout}{result.stderr}")
    if any(tree.rglob("*.rej")):
        raise RuntimeError("patch reject artifacts remain in reviewed tree")
    work = tree.parent / "memory-guards"
    work.mkdir()
    audit_contracts(tree, baseline, smp)
    sources = fixtures(tree)
    for label, source in sources.items():
        compile_fixture(source, label, work, clang)
    source = sources["mmu-entry"]
    condition = "chip_id == T6032 && !t6032_mmu_initialized"
    if source.count(condition) != 1:
        raise RuntimeError("missing/ambiguous inherited-MMU mutation target")
    mutation = source.replace(condition, "false && !t6032_mmu_initialized")
    compile_fixture(mutation, "mmu-entry-missing-inherited-guard", work, clang,
                    expected_failure="call_mmu_init(true) == 0 && panic_count == 1")
    print(f"Retained reviewed source: {tree}")
    print(f"Retained host fixture evidence: {work}")
    print("Scope: source-extracted MCC/MMU helpers, mock-only; no native/MMIO/VM/boot qualification")
    return 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
