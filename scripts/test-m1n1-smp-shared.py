#!/usr/bin/env python3
"""Host/source regression for the promoted m1n1 SMP-shared mapping.

The MMU remap function is extracted from the materialized, hash-pinned source
and executed against a recorder.  The recorder is deliberately the only host
stub: it checks the actual four calls made by the extracted function.
"""
from __future__ import annotations

import hashlib
import importlib.util
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from types import ModuleType

ROOT = pathlib.Path(__file__).resolve().parents[1]
PINNED = ROOT / "scratch/m1n1-cpu-audit/m1n1-4184923ffb2dff079b384d6a32cc02142aa14572"
ARCHIVE = ROOT / "scratch/m1n1-cpu-audit/source.tar.gz"
ARCHIVE_SHA256 = "6425983260ab96d55c36fdaab3b456830c3bd80f06b7759a61ed2bcca924d973"
PATCH_DIR = ROOT / "patches/m1n1"
TEMPLATE = ROOT / "tests/m1n1-smp-shared.c"
CLANG = shutil.which("clang")

# These are the inputs used by the existing runners.  Patch headers below add
# any newly touched files (notably both linker scripts and arm_cpu_regs.h).
SOURCE_FILES = {
    "src/mcc.c", "src/mcc.h", "src/memory.c", "src/memory.h", "src/utils.h",
    "src/types.h", "src/cpu_regs.h", "src/arm_cpu_regs.h", "src/xnuboot.h",
    "src/heapblock.h", "src/heapblock.c", "src/main.c", "src/kboot.c",
    "src/hv.c", "src/hv.h", "src/smp.c", "src/smp.h", "src/soc.h",
    "src/cpufreq.c",
    "src/proxy.c", "src/proxy.h", "src/payload.c", "src/startup.c",
    "m1n1.ld", "m1n1-raw.ld",
}


def fail(message: str) -> None:
    raise RuntimeError(message)


def run(command: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=False)


def extract_function(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        fail(f"missing function: {signature}")
    brace = source.find("{", start)
    if brace < 0:
        fail(f"missing body: {signature}")
    depth = 0
    quote = None
    escaped = line = block = False
    for index in range(brace, len(source)):
        char = source[index]
        nxt = source[index + 1] if index + 1 < len(source) else ""
        if line:
            if char == "\n":
                line = False
        elif block:
            if char == "*" and nxt == "/":
                block = False
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
            line = True
        elif char == "/" and nxt == "*":
            block = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    fail(f"unterminated function: {signature}")


def extract_define(source: str, name: str) -> str:
    match = re.search(rf"^#define\s+{re.escape(name)}(?:\s|$)", source, re.MULTILINE)
    if match is None:
        fail(f"missing define: {name}")
    lines = source[match.start():].splitlines(keepends=True)
    selected = [lines[0]]
    while selected[-1].rstrip().endswith("\\"):
        if len(selected) == len(lines):
            fail(f"unterminated define: {name}")
        selected.append(lines[len(selected)])
    return "".join(selected).rstrip("\n")


def patch_paths() -> list[pathlib.Path]:
    patches = []
    for index in range(1, 17):
        matches = sorted(PATCH_DIR.glob(f"{index:04d}-*.patch"))
        if len(matches) != 1:
            fail(f"missing/ambiguous patch {index:04d}: {matches}")
        patches.append(matches[0])
    return patches


def patch_input_paths(patches: list[pathlib.Path]) -> set[str]:
    paths = set(SOURCE_FILES)
    for patch in patches:
        for match in re.finditer(r"^\+\+\+ b/(\S+)", patch.read_text(), re.MULTILINE):
            paths.add(match.group(1))
        for match in re.finditer(r"^--- a/(\S+)", patch.read_text(), re.MULTILINE):
            paths.add(match.group(1))
    return {path for path in paths if path != "/dev/null"}


def materialize_experiment(work: pathlib.Path, *, nested: bool = True) -> pathlib.Path:
    """Build exactly pinned14 plus promoted patches 0015 and 0016."""
    if hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() != ARCHIVE_SHA256:
        fail("pinned source archive hash mismatch")
    patches = patch_paths()
    tree = work / "m1n1" if nested else work
    paths = patch_input_paths(patches)
    with tarfile.open(ARCHIVE) as archive:
        for relative in sorted(paths):
            member = f"{PINNED.name}/{relative}"
            try:
                original = archive.extractfile(member)
            except KeyError:
                fail(f"source archive lacks {relative}")
            if original is None:
                fail(f"source archive entry is not a file: {relative}")
            data = original.read()
            source = PINNED / relative
            if not source.is_file() or source.read_bytes() != data:
                fail(f"pinned source mismatch: {relative}")
            destination = tree / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
    for index, patch in enumerate(patches):
        # The pinned local series has historically needed patch's default
        # context handling.  The new experiment itself is required to apply
        # with zero fuzz, which is the backport boundary this test owns.
        command = ["patch", "-p1", "--batch", "--forward", "-i", str(patch)]
        if index == len(patches) - 1:
            command.insert(4, "--fuzz=0")
        result = run(command, tree)
        if result.returncode:
            fail(f"patch failed: {patch.name}\n{result.stdout}{result.stderr}")
    return tree


def mapping_audit(memory: str, memory_h: str) -> str:
    function = extract_function(memory, "static void mmu_remap_smp_shared(void)")
    expected = (
        "mmu_add_mapping(base, base, size, MAIR_IDX_DEVICE_nGnRnE, PERM_RW);",
        "mmu_add_mapping(base | REGION_RWX_EL0, base, size, "
        "MAIR_IDX_DEVICE_nGnRnE, PERM_RW_EL0);",
        "mmu_add_mapping(base | REGION_RW_EL0, base, size, "
        "MAIR_IDX_DEVICE_nGnRnE, PERM_RW_EL0);",
        "mmu_add_mapping(base | REGION_RX_EL1, base, size, "
        "MAIR_IDX_DEVICE_nGnRnE, PERM_RW_EL0);",
    )
    normalized = re.sub(r"\s+", " ", function)
    if any(re.sub(r"\s+", " ", call) not in normalized for call in expected):
        fail("SMP-shared remap does not contain the four exact upstream mapping calls")
    if function.count("mmu_add_mapping(") != 4:
        fail("SMP-shared remap mapping-call count changed")
    definitions = "\n".join(extract_define(memory_h, name) for name in (
        "PTE_AP_EL0", "PTE_PXN", "PTE_UXN", "REGION_RWX_EL0", "REGION_RW_EL0",
        "REGION_RX_EL1", "PERM_RW", "PERM_RW_EL0", "MAIR_IDX_DEVICE_nGnRnE",
    ))
    ready = re.search(r"^static bool\s+mmu_smp_shared_ready_state\s*;", memory, re.MULTILINE)
    if ready is not None:
        definitions += "\n" + ready.group(0)
    return definitions


def annotation_span(source: str, name: str) -> str:
    pattern = re.compile(rf"^.*\b{re.escape(name)}\b.*;\s*$", re.MULTILINE)
    matches = [match.group(0) for match in pattern.finditer(source)
               if "#define" not in match.group(0)]
    if not matches:
        fail(f"missing SMP_SHARED declaration: {name}")
    for match in matches:
        if "SMP_SHARED" in match or ".data.smp_shared" in match:
            return match
    fail(f"SMP_SHARED annotation missing from {name}")


def audit_smp_state(smp: str) -> None:
    for name in (
        "_reset_stack", "_reset_stack_el1", "secondary_stacks", "secondary_stacks_el3",
        "wfe_mode", "target_cpu", "spin_table", "boot_cpu_idx", "boot_cpu_mpidr",
    ):
        annotation_span(smp, name)
    signature = "static bool smp_start_cpu(" if "static bool smp_start_cpu(" in smp \
        else "static void smp_start_cpu("
    start_cpu = extract_function(smp, signature)
    if "dc_civac_range(" in start_cpu:
        fail("MMU-off SMP start still performs cache maintenance on shared state")
    if start_cpu.count('sysop("dsb sy")') < 1:
        fail("SMP start lost its required dsb sy barrier")


def audit_linker(linker: str, path: pathlib.Path) -> None:
    has_input = re.search(r"\.data\.smp_shared(?:\W|$)", linker) is not None
    has_output = re.search(r"(?<!data)\.smp_shared(?:\W|$)", linker) is not None
    if not has_input and not has_output:
        fail(f"{path.name} lacks the SMP-shared linker input/output section")
    data_pos = linker.find(".data :")
    data_block = linker[data_pos:data_pos + 1200] if data_pos >= 0 else ""
    if not re.search(r"\.data\.smp_shared(?:\W|$)", data_block) \
            or ". = ALIGN(0x10000);" not in data_block:
        fail(f"{path.name} SMP-shared section is not 64KiB aligned")
    if "_smp_shared_start" not in linker or "_smp_shared_end" not in linker:
        fail(f"{path.name} lacks _smp_shared_start/_smp_shared_end symbols")
    data = linker.find(".data :")
    start = linker.find("_data_start")
    if data < 0 or start < 0:
        fail(f"{path.name} lacks ordinary data bounds")
    # _data_start must describe the .data output section, not an alignment gap
    # introduced by the preceding 64KiB shared section.
    local = linker[start:start + 160]
    before = linker[max(0, start - 120):start]
    if start < data and "_data_start = ADDR(.data)" not in local \
            and ". = ALIGN(0x10000);" not in before:
        fail(f"{path.name} _data_start precedes .data and counts the shared gap")


def audit_order(memory: str) -> None:
    defaults = extract_function(memory, "static void mmu_add_default_mappings(void)")
    positions = [defaults.find(token) for token in (
        "mmu_remap_ranges();", "mmu_remap_smp_shared();",
        "mcc_unmap_carveouts_t6032(ram_size)",
    )]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        fail("SMP-shared remap/preflight ordering changed")
    init = extract_function(memory, "void mmu_init(void)")
    required = ("t6032_mmu_initialized = false;", "mcc_t6032_begin_carveout_setup();",
                "mmu_add_default_mappings();", "mmu_configure();",
                "write_sctlr(sctlr);", "t6032_mmu_initialized = true;")
    positions = [init.find(token) for token in required]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        fail("0014 T6032 MMU lifecycle ordering was not preserved")


def audit_t6032_carveout_wrapper(mcc: str) -> None:
    wrapper = extract_function(mcc, "int mcc_unmap_carveouts(void)")
    if "if (chip_id == T6032)" not in wrapper or "return -1;" not in wrapper:
        fail("native T6032 carveout dispatch was re-enabled")


def audit_cpu_dispatch(smp: str, cpufreq: str) -> None:
    for source, path in ((smp, "smp.c"), (cpufreq, "cpufreq.c")):
        if re.search(r"case\s+T6032\s*:", source):
            fail(f"native T6032 dispatch was re-enabled in {path}")


def build_harness(tree: pathlib.Path, memory: str, memory_h: str,
                  directory: pathlib.Path, tag: str = "smp-shared",
                  *, audit: bool = True, function_override: str | None = None) -> pathlib.Path:
    source = TEMPLATE.read_text(encoding="utf-8")
    if audit:
        definitions = mapping_audit(memory, memory_h)
    else:
        definitions = "\n".join(extract_define(memory_h, name) for name in (
            "PTE_AP_EL0", "PTE_PXN", "PTE_UXN", "REGION_RWX_EL0", "REGION_RW_EL0",
            "REGION_RX_EL1", "PERM_RW", "PERM_RW_EL0", "MAIR_IDX_DEVICE_nGnRnE",
            "MAIR_IDX_NORMAL"))
        ready = re.search(r"^static bool\s+mmu_smp_shared_ready_state\s*;", memory, re.MULTILINE)
        if ready is not None:
            definitions += "\n" + ready.group(0)
    source = source.replace("/* INSERT_MEMORY_DEFINES */", definitions)
    function = function_override or extract_function(memory, "static void mmu_remap_smp_shared(void)")
    source = source.replace("/* INSERT_MMU_REMAP_FUNCTION */", function)
    generated = directory / f"{tag}.c"
    binary = directory / tag
    generated.write_text(source, encoding="utf-8")
    result = run([CLANG, "-std=c11", "-O1", "-g", "-fno-omit-frame-pointer",
                  "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                  str(generated), "-o", str(binary)], ROOT)
    if result.returncode:
        fail(f"clang failed for {tag}:\n{result.stdout}{result.stderr}")
    return binary


def expect_mutation_rejected(tree: pathlib.Path, memory: str, memory_h: str,
                             smp: str, linker: str, directory: pathlib.Path) -> None:
    # An unshared EL3 pointer table declaration is rejected.
    mutated = smp
    match = re.search(r"^.*\bsecondary_stacks_el3\b.*;$", mutated, re.MULTILINE)
    if match is None:
        fail("mutation fixture could not find secondary_stacks_el3")
    mutated = mutated[:match.start()] + match.group(0).replace("SMP_SHARED", "", 1) + mutated[match.end():]
    try:
        audit_smp_state(mutated)
    except RuntimeError:
        pass
    else:
        fail("negative unshared-EL3-table mutation was accepted")

    # Wrong memory type must fail the executable recorder even when the static
    # exact-call audit is deliberately bypassed for this mutation.
    signature = "static void mmu_remap_smp_shared(void)"
    function = extract_function(memory, signature)
    wrong_function = function.replace("MAIR_IDX_DEVICE_nGnRnE", "MAIR_IDX_NORMAL", 1)
    wrong_binary = build_harness(tree, memory, memory_h, directory,
                                 tag="wrong-attribute", audit=False,
                                 function_override=wrong_function)
    wrong_result = run([str(wrong_binary)], ROOT)
    if wrong_result.returncode != 1 or "mappings[i].attribute_index ==" not in wrong_result.stderr:
        fail("wrong-attribute mutation did not fail its intended assertion")

    signature = "static void mmu_remap_smp_shared(void)"
    missing = extract_function(memory, signature)
    missing = missing.rsplit("mmu_add_mapping(base | REGION_RX_EL1", 1)[0] + "}"
    missing_binary = build_harness(tree, memory, memory_h, directory,
                                   tag="missing-mapping", audit=False,
                                   function_override=missing)
    missing_result = run([str(missing_binary)], ROOT)
    if missing_result.returncode != 1 or "mapping_count == 4" not in missing_result.stderr:
        fail("missing-mapping mutation did not fail its intended assertion")

    # A normal (non-SMP_SHARED) spin table must not pass as shared state.
    spin = re.search(r"^.*\bspin_table\b.*;$", smp, re.MULTILINE)
    if spin is None:
        fail("mutation fixture could not find spin_table")
    normal = smp[:spin.start()] + spin.group(0).replace("SMP_SHARED", "", 1) + smp[spin.end():]
    try:
        audit_smp_state(normal)
    except RuntimeError:
        pass
    else:
        fail("negative unshared-spin-table mutation was accepted")

    # Removing the linker alias/section must be rejected independently.
    absent = linker.replace(".data.smp_shared", ".data.smp_shared_removed")
    try:
        audit_linker(absent, pathlib.Path("mutated.ld"))
    except RuntimeError:
        pass
    else:
        fail("negative missing-linker-alias mutation was accepted")


def load(path: pathlib.Path, name: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        fail(f"unable to load {path.name}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_adjacent() -> None:
    """Run existing source harnesses against this exact pinned14+0015 tree."""
    mapping = load(ROOT / "scripts/test-m1n1-mapping-guard.py", "smp_mapping")
    mapping.materialize = lambda tree: materialize_experiment(tree, nested=False)
    mapping.main()

    mmu = load(ROOT / "scripts/test-m1n1-mmu-entry.py", "smp_mmu")
    mmu.load_mapping_runner = lambda: mapping
    mmu.main()

    carveout = load(ROOT / "scripts/test-m1n1-carveout-preflight.py", "smp_carveout")
    carveout.materialize = lambda tree: materialize_experiment(tree, nested=False)
    carveout.main()

    status = load(ROOT / "scripts/test-m1n1-cpu-start-status.py", "smp_status")
    status.materialize = lambda work: materialize_experiment(work, nested=True)
    previous_guard = os.environ.get("TEST_MMU_SMP_GUARD")
    os.environ["TEST_MMU_SMP_GUARD"] = "1"
    try:
        status.main()
    finally:
        if previous_guard is None:
            os.environ.pop("TEST_MMU_SMP_GUARD", None)
        else:
            os.environ["TEST_MMU_SMP_GUARD"] = previous_guard


def main() -> int:
    if CLANG is None:
        fail("clang is required")
    with tempfile.TemporaryDirectory(dir=ROOT / "scratch") as directory_name:
        directory = pathlib.Path(directory_name)
        tree = materialize_experiment(directory)
        memory = (tree / "src/memory.c").read_text(encoding="utf-8")
        memory_h = (tree / "src/memory.h").read_text(encoding="utf-8")
        smp = (tree / "src/smp.c").read_text(encoding="utf-8")
        cpufreq = (tree / "src/cpufreq.c").read_text(encoding="utf-8")
        mcc = (tree / "src/mcc.c").read_text(encoding="utf-8")
        audit_smp_state(smp)
        audit_order(memory)
        audit_t6032_carveout_wrapper(mcc)
        audit_cpu_dispatch(smp, cpufreq)
        linkers = [tree / name for name in ("m1n1.ld", "m1n1-raw.ld") if (tree / name).is_file()]
        if len(linkers) != 2:
            fail("both m1n1 linker scripts are required for the experiment")
        for linker_path in linkers:
            linker = linker_path.read_text(encoding="utf-8")
            audit_linker(linker, linker_path)
            expect_mutation_rejected(tree, memory, memory_h, smp, linker, directory)
        binary = build_harness(tree, memory, memory_h, directory)
        result = run([str(binary)], ROOT)
        if result.returncode:
            fail(f"SMP-shared mapping harness failed:\n{result.stdout}{result.stderr}")
        print(result.stdout.strip())
        # The existing runners create their own temporary trees; each receives
        # this explicit materializer, so no default runner is silently reused.
        run_adjacent()
    print("SMP-shared source/linker audit passed; adjacent pinned14+0016 harnesses passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"m1n1 SMP-shared harness: ERROR: {error}")
        raise SystemExit(1)
