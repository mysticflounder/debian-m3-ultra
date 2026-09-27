#!/usr/bin/env python3
"""Host ASan/UBSan regression for the extracted T6032 inventory preflight."""

from __future__ import annotations

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
PATCHES = [ROOT / "patches/m1n1" / name for name in (
    "0001-expand-cpu-capacity-and-fix-bounds.patch",
    "0003-guard-secondary-start-prerequisites.patch",
    "0004-abort-on-secondary-start-timeout.patch",
    "0005-t6032-cpu-start-masks.patch",
    "0006-preflight-t6032-cpu-inventory.patch",
)]
EXPECTED = {
    "src/smp.c": "173ae51dd860d1b075a071d78d06945e3ed929910ce06ab0f76cd6b9e261371b",
    "src/smp.h": "d4bd759b232d47930893c4d0fb90280935741929e4e4dca5a15654fb0a316c83",
    "src/soc.h": "3569ce0f11ad808f724bf0c050b1fc8381dd199791ec95729f411ad8c2359bca",
    "src/kboot.c": "11294702663baab7a3e0d0c7ac426688d6dc39f8543ca8c3088bf5cdd4f5d926",
    "src/hv.c": "764adf7001dd94bdd017c57b70893c87369716bf0034e64f7bf70dc9a74cd1cd",
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
    for relative in EXPECTED:
        source = PINNED / relative
        if not source.is_file() or sha256(source) != EXPECTED[relative]:
            fail(f"pinned source hash mismatch: {relative}")
        (tree / relative).write_bytes(source.read_bytes())
    for patch in PATCHES:
        applied = run(["patch", "-p1", "--batch", "--forward", "-i", str(patch)], tree)
        if applied.returncode:
            fail(f"{patch.name} did not apply:\n{applied.stdout}{applied.stderr}")
    return tree


def main() -> int:
    clang = shutil.which("clang")
    if clang is None:
        fail("clang is required")
    helper = load_extractor()
    with tempfile.TemporaryDirectory(prefix="m1n1-cpu-preflight-", dir=ROOT / "scratch") as name:
        work = pathlib.Path(name)
        tree = materialize(work)
        smp = (tree / "src/smp.c").read_text(encoding="utf-8")
        soc = (tree / "src/soc.h").read_text(encoding="utf-8")
        smp_header = (tree / "src/smp.h").read_text(encoding="utf-8")
        defines = [line for text in (smp, smp_header) for line in text.splitlines()
                   if line.startswith("#define ")]
        defines += [line for line in soc.splitlines()
                    if re.match(r"#define\s+(?:S5L|S800|T[0-9]+)", line)]
        try:
            functions = {
                "mask": helper.extract_function(smp, "static bool smp_cpu_start_masks(", tree / "src/smp.c"),
                "u32": helper.extract_function(smp, "static bool smp_t6032_u32(", tree / "src/smp.c"),
                "preflight": helper.extract_function(smp, "static bool smp_t6032_preflight(", tree / "src/smp.c"),
                "start_cpu": helper.extract_function(smp, "static void smp_start_cpu(", tree / "src/smp.c"),
                "start_secondaries": helper.extract_function(smp, "void smp_start_secondaries(void)", tree / "src/smp.c"),
            }
        except helper.HarnessError as exc:
            fail(str(exc))
        source = TEMPLATE.read_text(encoding="utf-8")
        fixture = json.loads((ROOT / "docs/inventory/t6032-startup-metadata-2026-09-26.json").read_text(encoding="utf-8"))
        cpus = fixture.get("cpus")
        if fixture.get("cpu_count") != 32 or not isinstance(cpus, list) or len(cpus) != 32:
            fail("startup metadata fixture is not exactly 32 CPUs")
        if fixture.get("running_cpu_id") not in range(32):
            fail("startup metadata fixture has invalid running CPU")
        ids = [int(cpu["cpu_id"]) for cpu in cpus]
        if sorted(ids) != list(range(32)) or len(set(ids)) != 32:
            fail("startup metadata fixture IDs are not unique and dense")
        states = [cpu.get("state") for cpu in cpus]
        if any(state not in ("running", "waiting") for state in states):
            fail("startup metadata fixture has an invalid state")
        if states.count("running") != 1 or ids[states.index("running")] != fixture["running_cpu_id"]:
            fail("startup metadata fixture running state does not identify running_cpu_id")
        regs = [int(cpu["reg"], 16) for cpu in cpus]
        for cpu, reg in zip(cpus, regs):
            expected_reg = (int(cpu["die"]) << 11) | (int(cpu["cluster"]) << 8) | int(cpu["core"])
            if reg != expected_reg:
                fail("startup metadata fixture reg/coordinate mismatch")
        bases = ", ".join(f"0x{int(cpu['cpu_impl_base'], 16):x}ULL" for cpu in cpus)
        sizes = ", ".join(f"0x{int(cpu['cpu_impl_size'], 16):x}ULL" for cpu in cpus)
        ids_c = ", ".join(str(int(cpu["cpu_id"])) for cpu in cpus)
        regs_c = ", ".join(f"0x{int(cpu['reg'], 16):x}U" for cpu in cpus)
        dies_c = ", ".join(str(int(cpu["die"])) for cpu in cpus)
        clusters_c = ", ".join(str(int(cpu["cluster"])) for cpu in cpus)
        cores_c = ", ".join(str(int(cpu["core"])) for cpu in cpus)
        states_c = ", ".join("{" + ", ".join(str(byte) for byte in (state.encode() + b"\0")) + "}"
                             for state in states)
        live = (f"#define LIVE_RUNNING_ID {int(fixture['running_cpu_id'])}\n"
                f"static const u32 live_ids[32] = {{{ids_c}}};\n"
                f"static const u32 live_regs[32] = {{{regs_c}}};\n"
                f"static const u32 live_dies[32] = {{{dies_c}}};\n"
                f"static const u32 live_clusters[32] = {{{clusters_c}}};\n"
                f"static const u32 live_cores[32] = {{{cores_c}}};\n"
                f"static const u8 live_states[32][8] = {{{states_c}}};\n"
                f"static const u64 live_bases[32] = {{{bases}}};\n"
                f"static const u64 live_sizes[32] = {{{sizes}}};")
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
        generated = work / "preflight.c"
        binary = work / "preflight"
        generated.write_text(source, encoding="utf-8")
        compiled = run([clang, "-std=c11", "-O1", "-g", "-fno-omit-frame-pointer",
                        "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                        str(generated), "-o", str(binary)], work)
        if compiled.returncode:
            fail(f"clang failed:\n{compiled.stdout}{compiled.stderr}")
        completed = run([str(binary)], work)
        if completed.returncode:
            fail(f"preflight harness failed ({completed.returncode}):\n{completed.stdout}{completed.stderr}")
        print(completed.stdout, end="")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(f"m1n1 CPU preflight harness: ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
