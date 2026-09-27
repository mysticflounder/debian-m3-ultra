#!/usr/bin/env python3
"""Host-only tests for pinned m1n1 CPU-start selection and register contract."""

from __future__ import annotations

import importlib.util
import os
import pathlib
import json
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
PINNED = ROOT / "scratch/m1n1-cpu-audit/m1n1-4184923ffb2dff079b384d6a32cc02142aa14572"
TEMPLATE = ROOT / "tests/m1n1-cpu-startup.c"
SMP = PINNED / "src/smp.c"
PATCH = ROOT / "patches/m1n1/0003-guard-secondary-start-prerequisites.patch"
TIMEOUT_PATCH = ROOT / "patches/m1n1/0004-abort-on-secondary-start-timeout.patch"
SMP_SHA256 = "173ae51dd860d1b075a071d78d06945e3ed929910ce06ab0f76cd6b9e261371b"
UTILS_SHA256 = "c224e336539e24a23913f8567abf185fd68627c9bcd71874ba6ff6014996d23d"
SOC_SHA256 = "3569ce0f11ad808f724bf0c050b1fc8381dd199791ec95729f411ad8c2359bca"
PMGR_SHA256 = "5719c4ed311ea6088a5bea5be95a0ac051073677ee5bcf58c9b7eb410df26a78"
TOPOLOGY = ROOT / "docs/inventory/t6032-cpus-2026-09-26.json"


class HarnessError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise HarnessError(message)


def run(command: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=False,
                          env={**os.environ, "ASAN_OPTIONS": "detect_leaks=0"})


def sha256(path: pathlib.Path) -> str:
    import hashlib
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def helper_module():
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("m1n1_cpu_bounds", ROOT / "scripts/test-m1n1-cpu-bounds.py")
    if spec is None or spec.loader is None:
        fail("cannot load shared source extractor")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def variant_source(work: pathlib.Path, variant: int) -> pathlib.Path:
    """Materialize original, guarded, or guarded-plus-fatal-timeout smp.c."""
    name = ("baseline", "guarded", "fatal-timeout")[variant]
    tree = work / name
    source = tree / "src/smp.c"
    source.parent.mkdir(parents=True)
    shutil.copy2(SMP, source)
    for patch in (PATCH, TIMEOUT_PATCH)[:variant]:
        applied = run(["patch", "-p1", "--batch", "--forward", "-i", str(patch)], tree)
        if applied.returncode:
            fail(f"{patch.name} did not apply to pinned smp.c:\n{applied.stdout}{applied.stderr}")
    return source


def main() -> int:
    if shutil.which("clang") is None:
        fail("clang is required")
    source_paths = {
        "smp.c": (SMP, SMP_SHA256),
        "utils.h": (PINNED / "src/utils.h", UTILS_SHA256),
        "soc.h": (PINNED / "src/soc.h", SOC_SHA256),
        "pmgr.h": (PINNED / "src/pmgr.h", PMGR_SHA256),
    }
    for name, (path, expected) in source_paths.items():
        if not path.is_file() or sha256(path) != expected:
            fail(f"pinned {name} SHA-256 mismatch")
    if not TEMPLATE.is_file():
        fail("startup C template missing")
    if not PATCH.is_file():
        fail("startup prerequisite patch missing")
    if not TIMEOUT_PATCH.is_file():
        fail("startup timeout patch missing")
    if not TOPOLOGY.is_file():
        fail("source topology inventory missing")

    helper = helper_module()
    with tempfile.TemporaryDirectory(prefix="m1n1-cpu-startup-", dir=ROOT / "scratch") as temp:
        work = pathlib.Path(temp)
        try:
            patched = helper.apply_patch_copy(work)
            smp_header = (patched / "src/smp.h").read_text(encoding="utf-8")
            if helper.max_cpu(smp_header, patched / "src/smp.h") != 32:
                fail("capacity patch did not establish MAX_CPUS=32")
            helper.require_max_el3(smp_header)
            source_limits = "\n".join(line for line in smp_header.splitlines()
                                      if re.match(r"#define\s+(MAX_CPUS|MAX_EL3_CPUS)\s", line))
        except helper.HarnessError as exc:
            fail(str(exc))
        utils = (PINNED / "src/utils.h").read_text(encoding="utf-8")
        el_helpers = "\n\n".join(helper.extract_function(utils, signature, PINNED / "src/utils.h")
                                      for signature in ("static inline int in_el2(void)",
                                                        "static inline int in_el3(void)",
                                                        "static inline int has_el3(void)"))
        source_defines = []
        for path, prefixes in ((SMP, ("CPU_START_OFF_", "CPU_REG_", "RVBAR_")),
                               (PINNED / "src/soc.h", ("S5L", "S800", "T")),
                               (PINNED / "src/pmgr.h", ("PMGR_DIE_OFFSET",))):
            for line in path.read_text(encoding="utf-8").splitlines():
                if line.startswith("#define ") and any(line.startswith(f"#define {prefix}") for prefix in prefixes):
                    source_defines.append(line)
        inventory = json.loads(TOPOLOGY.read_text(encoding="utf-8"))["topology"]["affinity"]
        if len(inventory) != 32 or [item["cpu_id"] for item in inventory] != list(range(32)):
            fail("source topology inventory is not ordinal 0..31")
        topology = ", ".join("{%d, %d, %d}" % (item["die"], item["cluster"], item["core"])
                             for item in inventory)
        template = TEMPLATE.read_text(encoding="utf-8")
        markers = ("/* INSERT_SOURCE_CONSTANTS */", "/* INSERT_SOURCE_LIMITS */", "/* INSERT_SOURCE_EL_HELPERS */",
                   "/* INSERT_SMP_START_CPU */", "/* INSERT_SMP_START_SECONDARIES */",
                   "/* INSERT_TOPOLOGY */")
        if any(template.count(marker) != 1 for marker in markers):
            fail("startup insertion markers missing or duplicated")
        results = []
        for variant, name in enumerate(("baseline", "guarded", "fatal-timeout")):
            source_path = variant_source(work, variant)
            source = source_path.read_text(encoding="utf-8")
            start_cpu = helper.extract_function(source, "static void smp_start_cpu(", source_path)
            start_secondaries = helper.extract_function(source, "void smp_start_secondaries(void)", source_path)
            generated_text = template.replace("/* INSERT_SOURCE_CONSTANTS */", "\n".join(source_defines))
            generated_text = generated_text.replace("/* INSERT_SOURCE_LIMITS */", source_limits)
            generated_text = generated_text.replace("/* INSERT_SOURCE_EL_HELPERS */", el_helpers)
            generated_text = generated_text.replace("/* INSERT_SMP_START_CPU */", start_cpu)
            generated_text = generated_text.replace("/* INSERT_SMP_START_SECONDARIES */", start_secondaries)
            generated_text = generated_text.replace("/* INSERT_TOPOLOGY */", topology)
            generated = work / f"startup-{name}.c"
            generated.write_text(generated_text, encoding="utf-8")
            binary = work / f"startup-{name}"
            compiled = run(["clang", "-std=c11", "-O1", "-g", "-fno-omit-frame-pointer",
                            "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                            f"-DEXPECT_PATCHED={int(variant > 0)}",
                            f"-DEXPECT_FATAL_TIMEOUT={int(variant == 2)}",
                            "-include", "stdlib.h", str(generated), "-o", str(binary)], work)
            if compiled.returncode:
                fail(f"clang {name} failed:\n"
                     f"{compiled.stdout}{compiled.stderr}")
            completed = run([str(binary)], work)
            if completed.returncode:
                fail(f"startup {name} harness failed "
                     f"({completed.returncode}):\n{completed.stdout}{completed.stderr}")
            results.append((name, completed.stdout))
        for name, output in results:
            interesting = [line for line in output.splitlines()
                           if line.startswith(("selection:", "start_cpu:", "timeout:", "variant:", "note:"))]
            print(f"[{name}]\n" + "\n".join(interesting))
    print("m1n1 CPU-start harness passed: original, guarded and fatal-timeout source variants")
    print("all variants use limits from 0001-patched smp.h; baseline means original startup logic, not stock capacity")
    print("start_secondaries was extracted exactly; ADT CPU enumeration is intentionally no-child mocked")
    print("coverage is mocked host execution only; no native boot, MMIO, firmware, or T6032 dispatch")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HarnessError as exc:
        print(f"m1n1 CPU-start harness: ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
