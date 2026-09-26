#!/usr/bin/env python3
"""Compile the pinned m1n1 dt_set_cpus() against synthetic host libfdt tests."""

from __future__ import annotations

import hashlib
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
PINNED = ROOT / "scratch/m1n1-cpu-audit/m1n1-4184923ffb2dff079b384d6a32cc02142aa14572"
PATCH = ROOT / "patches/m1n1/0001-expand-cpu-capacity-and-fix-bounds.patch"
TEMPLATE = ROOT / "tests/m1n1-cpu-handoff.c"
KBOOT_SHA256 = "11294702663baab7a3e0d0c7ac426688d6dc39f8543ca8c3088bf5cdd4f5d926"
LIBFDT_SOURCES = (
    "fdt.c",
    "fdt_ro.c",
    "fdt_rw.c",
    "fdt_wip.c",
    "fdt_sw.c",
    "fdt_empty_tree.c",
    "fdt_strerror.c",
    "fdt_addresses.c",
    "fdt_overlay.c",
)


class HarnessError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise HarnessError(message)


def run(command: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=False)


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def extract_function(source: str) -> str:
    signature = "static int dt_set_cpus(void)"
    start = source.find(signature)
    if start < 0:
        fail("dt_set_cpus signature missing; pinned source shape changed")
    brace = source.find("{", start)
    if brace < 0:
        fail("dt_set_cpus body missing")
    depth = 0
    quote: str | None = None
    escaped = False
    line_comment = False
    block_comment = False
    i = brace
    while i < len(source):
        c = source[i]
        n = source[i + 1] if i + 1 < len(source) else ""
        if line_comment:
            if c == "\n":
                line_comment = False
        elif block_comment:
            if c == "*" and n == "/":
                block_comment = False
                i += 1
        elif quote:
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == quote:
                quote = None
        elif c in ("'", '"'):
            quote = c
        elif c == "/" and n == "/":
            line_comment = True
            i += 1
        elif c == "/" and n == "*":
            block_comment = True
            i += 1
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return source[start:i + 1]
        i += 1
    fail("unterminated dt_set_cpus body")


def prepare_patched_source(work: pathlib.Path) -> pathlib.Path:
    if not PINNED.is_dir() or not PATCH.is_file():
        fail("pinned source or capacity patch missing")
    kboot = PINNED / "src/kboot.c"
    if sha256(kboot) != KBOOT_SHA256:
        fail("pinned kboot.c SHA-256 mismatch; refusing to test unknown source")
    destination = work / "m1n1"
    (destination / "src").mkdir(parents=True)
    for relative in ("src/kboot.c", "src/smp.h", "src/hv.c"):
        (destination / relative).write_bytes((PINNED / relative).read_bytes())
    applied = run(["patch", "-p1", "--batch", "--forward", "-i", str(PATCH)], destination)
    if applied.returncode:
        fail(f"capacity patch did not apply:\n{applied.stdout}{applied.stderr}")
    smp = (destination / "src/smp.h").read_text(encoding="utf-8")
    if not re.search(r"^#define\s+MAX_CPUS\s+32\s*$", smp, re.MULTILINE):
        fail("patched src/smp.h does not define MAX_CPUS 32")
    if not re.search(r"^#define\s+MAX_EL3_CPUS\s+4\s*$", smp, re.MULTILINE):
        fail("patched src/smp.h MAX_EL3_CPUS changed unexpectedly")
    return destination


def main() -> int:
    if shutil.which("clang") is None:
        fail("clang is required; no host C compiler available")
    if not TEMPLATE.is_file():
        fail(f"missing C harness template: {TEMPLATE}")
    libdir = PINNED / "src/libfdt"
    for source in LIBFDT_SOURCES:
        if not (libdir / source).is_file():
            fail(f"pinned libfdt source missing: {source}")

    with tempfile.TemporaryDirectory(prefix="m1n1-cpu-handoff-", dir=ROOT / "scratch") as temporary:
        work = pathlib.Path(temporary)
        patched = prepare_patched_source(work)
        function = extract_function((patched / "src/kboot.c").read_text(encoding="utf-8"))
        template = TEMPLATE.read_text(encoding="utf-8")
        marker = "/* INSERT_DT_SET_CPUS */"
        if template.count(marker) != 1:
            fail("C harness insertion marker missing or duplicated")
        generated = template.replace(marker, function)
        generated_path = work / "handoff.c"
        binary = work / "handoff"
        generated_path.write_text(generated, encoding="utf-8")
        command = [
            "clang", "-std=c11", "-O1", "-g", "-fno-omit-frame-pointer",
            "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
            "-include", "stdlib.h", "-I", str(libdir),
            str(generated_path),
            *(str(libdir / source) for source in LIBFDT_SOURCES), "-o", str(binary),
        ]
        compiled = run(command, work)
        if compiled.returncode:
            fail(f"clang failed:\n{compiled.stdout}{compiled.stderr}")
        environment = {"ASAN_OPTIONS": "detect_leaks=0"}
        completed = subprocess.run([str(binary)], cwd=work, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env={**os.environ, **environment}, check=False)
        if completed.returncode:
            fail(f"handoff scenarios failed ({completed.returncode}):\n{completed.stdout}{completed.stderr}")
        if "known existing dt_set_cpus success-path allocation leak observed" not in completed.stdout:
            fail("harness did not report the known successful cpu-map allocation leak")
        interesting = [line for line in completed.stdout.splitlines()
                       if line.startswith("scenario ") or line.startswith("known existing")]
        print("\n".join(interesting))
    print("m1n1 CPU handoff harness passed: 32/two-die, dead-secondary pruning, 33rd rejection, mismatch, missing-reg, boot skip, legacy24")
    print("coverage is host libfdt + extracted dt_set_cpus only; no ARM execution, MMIO, firmware, or full m1n1 build")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HarnessError as exc:
        print(f"m1n1 CPU handoff harness: ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
