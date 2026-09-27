#!/usr/bin/env python3
"""Source-extracted host regression for the T6032 MMU entry lifecycle."""
from __future__ import annotations

import importlib.util
import pathlib
import re
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "tests/m1n1-mmu-entry.c"
MAPPING_RUNNER = ROOT / "scripts/test-m1n1-mapping-guard.py"
CLANG = shutil.which("clang")


def fail(message: str) -> None:
    raise RuntimeError(message)


def run(command: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=False)


def load_mapping_runner():
    spec = importlib.util.spec_from_file_location("m1n1_mapping_guard", MAPPING_RUNNER)
    if spec is None or spec.loader is None:
        fail("unable to load mapping runner")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    if CLANG is None:
        fail("clang is required")
    runner = load_mapping_runner()
    # The imported materializer normally carries only its harness inputs. Add
    # the register header before materializing so its hash-pinned copy is used.
    runner.SOURCE_FILES.add("src/arm_cpu_regs.h")
    with tempfile.TemporaryDirectory(dir=ROOT / "scratch") as directory:
        work = pathlib.Path(directory)
        tree = work / "m1n1"
        runner.materialize(tree)
        memory = (tree / "src/memory.c").read_text(encoding="utf-8")
        arm_regs = (tree / "src/arm_cpu_regs.h").read_text(encoding="utf-8")
        soc = (tree / "src/soc.h").read_text(encoding="utf-8")
        variable = re.search(r"^static bool t6032_mmu_initialized;\s*$", memory,
                             re.MULTILINE)
        if variable is None:
            fail("patch 0014 MMU lifecycle variable missing")
        mmu_init = runner.extract_function(memory, "void mmu_init(void)")
        mmu_disable = runner.extract_function(memory, "u64 mmu_disable(void)")
        mmu_restore = runner.extract_function(memory, "void mmu_restore(u64 state)")
        if "t6032_mmu_initialized" in mmu_disable or "t6032_mmu_initialized" in mmu_restore:
            fail("MMU disable/restore unexpectedly mutates T6032 lifecycle latch")
        default_mappings = runner.extract_function(
            memory, "static void mmu_add_default_mappings(void)")
        preflight = ("if (chip_id == T6032 && "
                     "mcc_unmap_carveouts_t6032(ram_size) < 0)")
        if preflight not in default_mappings or "panic(\"T6032 carveout validation failed!" not in default_mappings:
            fail("actual T6032 default-mapping preflight/panic contract missing")
        required = (
            "t6032_mmu_initialized = false;",
            "mcc_t6032_begin_carveout_setup();",
            "t6032_mmu_initialized = true;",
        )
        for text in required:
            if text not in mmu_init:
                fail(f"mmu_init missing patched lifecycle step: {text}")
        if "chip_id == T6032 && !t6032_mmu_initialized" not in mmu_init:
            fail("MMU inherited-state guard is not T6032/latch qualified")
        if mmu_init.find("t6032_mmu_initialized = false;") > mmu_init.find(
                "mcc_t6032_begin_carveout_setup();"):
            fail("MMU lifecycle flag is not cleared before carveout setup")
        if mmu_init.find("t6032_mmu_initialized = true;") < mmu_init.find(
                "write_sctlr(sctlr);"):
            fail("MMU lifecycle flag is published before SCTLR write")
        if mmu_init.find("mcc_t6032_begin_carveout_setup();") > mmu_init.find(
                "mmu_add_default_mappings();"):
            fail("T6032 carveout setup begins after the default-mapping stage")
        default_call = mmu_init.find("mmu_add_default_mappings();")
        configure_call = mmu_init.find("mmu_configure();")
        publish = mmu_init.find("t6032_mmu_initialized = true;")
        if not (0 <= default_call < configure_call < publish):
            fail("default mappings/configuration/latch publication are out of order")
        defines = [runner.extract_define(arm_regs, name) for name in (
            "SCTLR_LSMAOE", "SCTLR_nTLSMD", "SCTLR_TSCXT", "SCTLR_ITD",
            "SCTLR_I", "SCTLR_C", "SCTLR_M", "SCTLR_SPAN")]
        defines.extend(runner.extract_define(soc, name) for name in ("T6031", "T6032"))
        source = TEMPLATE.read_text(encoding="utf-8")
        replacements = {
            "/* INSERT_MMU_DEFINES */": "\n".join(defines),
            "/* INSERT_MMU_STATE */": variable.group(0),
            "/* INSERT_MMU_SOURCE */": mmu_init,
        }
        for marker, replacement in replacements.items():
            if source.count(marker) != 1:
                fail(f"template marker missing or duplicated: {marker}")
            source = source.replace(marker, replacement)
        generated = work / "mmu-entry.c"
        binary = work / "mmu-entry"
        generated.write_text(source, encoding="utf-8")
        compiled = run([CLANG, "-std=c11", "-O1", "-g", "-fno-omit-frame-pointer",
                        "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                        str(generated), "-o", str(binary)], ROOT)
        if compiled.returncode:
            fail(f"clang failed:\n{compiled.stdout}{compiled.stderr}")
        result = run([str(binary)], ROOT)
        if result.returncode:
            fail(f"MMU entry harness failed:\n{result.stdout}{result.stderr}")
        print(result.stdout, end="")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(f"m1n1 MMU entry harness: ERROR: {exc}")
        raise SystemExit(1)
