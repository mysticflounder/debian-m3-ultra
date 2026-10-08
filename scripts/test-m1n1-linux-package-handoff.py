#!/usr/bin/env python3
"""Offline final-DTB handoff fixture for an actual initramfs package input.

The runner inserts exact functions from the pinned m1n1 kboot.c into a host
libfdt fixture.  It executes kboot_set_initrd(), dt_set_chosen(),
dt_set_memory(), and dt_set_cpus().  dt_set_memory() receives an explicit
synthetic ADT provider for the three properties it reads.  No native
execution, MMIO, firmware, VM, or disk work occurs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
PINNED = ROOT / "scratch/m1n1-upstream-xz-seek-guards.m9h56j/m1n1-2460b604c6f016956ead711823605eea840c602e"
TEMPLATE = ROOT / "tests/m1n1-linux-package-handoff.c"
KBOOT_SHA256 = "14822d4bef8af488ec4f2dbb9cd06e36fec8dc8882c7f78e92e6dcd810c61391"
MOCK_RAM_BASE = 0x10000000000
MOCK_RAM_SIZE = 0x400000000
MOCK_LINUX_WINDOW_SIZE = 0x40000000
MOCK_IMAGE_BASE = MOCK_RAM_BASE + 0x02000000
MOCK_IMAGE_SPAN = 44040192
MOCK_INITRD_BASE = MOCK_RAM_BASE + 0x08000000
LIBFDT_SOURCES = (
    "fdt.c", "fdt_ro.c", "fdt_rw.c", "fdt_wip.c", "fdt_sw.c",
    "fdt_empty_tree.c", "fdt_strerror.c", "fdt_addresses.c", "fdt_overlay.c",
)


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, text=True, capture_output=True, check=False)


def extract_function(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        raise RuntimeError(f"missing retained source function: {signature}")
    brace = source.find("{", start)
    if brace < 0:
        raise RuntimeError(f"missing function body: {signature}")
    depth = 0
    quote: str | None = None
    escaped = False
    line_comment = False
    block_comment = False
    for index in range(brace, len(source)):
        char = source[index]
        next_char = source[index + 1] if index + 1 < len(source) else ""
        if line_comment:
            if char == "\n":
                line_comment = False
        elif block_comment:
            if char == "*" and next_char == "/":
                block_comment = False
        elif quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
        elif char in "'\"":
            quote = char
        elif char == "/" and next_char == "/":
            line_comment = True
        elif char == "/" and next_char == "*":
            block_comment = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise RuntimeError(f"unterminated function: {signature}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dtb", action="append", required=True,
                        help="one or more actual input DTBs")
    parser.add_argument("--initramfs", required=True,
                        help="actual input initramfs package")
    parser.add_argument("--bootargs", default="earlycon console=ttySAC0 rdinit=/init",
                        help="bootargs passed to the chosen-property fixture")
    args = parser.parse_args()

    dtbs = [pathlib.Path(path).resolve() for path in args.dtb]
    initramfs = pathlib.Path(args.initramfs).resolve()
    if not TEMPLATE.is_file() or not (PINNED / "src/kboot.c").is_file():
        raise RuntimeError("fixture template or pinned source missing")
    if sha256(PINNED / "src/kboot.c") != KBOOT_SHA256:
        raise RuntimeError("retained kboot.c SHA-256 mismatch")
    if not initramfs.is_file() or any(not path.is_file() for path in dtbs):
        raise RuntimeError("DTB/initramfs input missing")
    source = (PINNED / "src/kboot.c").read_text(encoding="utf-8")
    template = TEMPLATE.read_text(encoding="utf-8")
    generated = template.replace("/* INSERT_KBOOT_SET_INITRD */",
                                extract_function(source, "void kboot_set_initrd(void *start, size_t size)"))
    generated = generated.replace("/* INSERT_DT_SET_CHOSEN */",
                                extract_function(source, "static int dt_set_chosen(void)"))
    generated = generated.replace("/* INSERT_DT_SET_MEMORY */",
                                extract_function(source, "static int dt_set_memory(void)"))
    generated = generated.replace("/* INSERT_DT_SET_CPUS */",
                                extract_function(source, "static int dt_set_cpus(void)"))
    if "INSERT_" in generated:
        raise RuntimeError("fixture insertion marker missing")

    work = pathlib.Path(tempfile.mkdtemp(prefix="m1n1-linux-package-handoff.", dir=ROOT / "scratch"))
    generated_path = work / "m1n1-linux-package-handoff.generated.c"
    binary = work / "m1n1-linux-package-handoff"
    generated_path.write_text(generated, encoding="utf-8")
    libdir = PINNED / "src/libfdt"
    compile_argv = [
        "clang", "-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
        "-include", "stdlib.h",
        "-I", str(libdir), str(generated_path),
        *(str(libdir / source_name) for source_name in LIBFDT_SOURCES),
        "-o", str(binary),
    ]
    compiled = run(compile_argv, work)
    (work / "compile.stdout.log").write_text(compiled.stdout, encoding="utf-8")
    (work / "compile.stderr.log").write_text(compiled.stderr, encoding="utf-8")
    if compiled.returncode:
        raise RuntimeError(f"compile failed; evidence retained at {work}")

    package_size = initramfs.stat().st_size
    records: list[dict[str, object]] = []
    for index, dtb in enumerate(dtbs):
        label = f"dtb-{index:02d}"
        output = work / f"{label}.post-fixup.dtb"
        argv = [str(binary), str(dtb), str(package_size), str(output), args.bootargs]
        completed = run(argv, work)
        (work / f"{label}.stdout.log").write_text(completed.stdout, encoding="utf-8")
        (work / f"{label}.stderr.log").write_text(completed.stderr, encoding="utf-8")
        if completed.returncode or not output.is_file():
            raise RuntimeError(f"{label} failed; evidence retained at {work}")
        records.append({
            "label": label,
            "argv": argv,
            "returncode": completed.returncode,
            "input_dtb": str(dtb),
            "input_dtb_sha256": sha256(dtb),
            "post_fixup_dtb": output.name,
            "post_fixup_dtb_sha256": sha256(output),
            "stdout": f"{label}.stdout.log",
            "stderr": f"{label}.stderr.log",
        })

    manifest = {
        "source_tree": str(PINNED),
        "kboot_sha256": KBOOT_SHA256,
        "runner_sha256": sha256(pathlib.Path(__file__).resolve()),
        "template_sha256": sha256(TEMPLATE),
        "generated_source_sha256": sha256(generated_path),
        "libfdt_sha256": {name: sha256(libdir / name) for name in LIBFDT_SOURCES},
        "initramfs": str(initramfs),
        "initramfs_size": package_size,
        "initramfs_sha256": sha256(initramfs),
        "compile_argv": compile_argv,
        "runs": records,
        "executed_functions": ["kboot_set_initrd", "dt_set_chosen", "dt_set_memory", "dt_set_cpus"],
        "memory_fixup": "exact retained dt_set_memory body with synthetic ADT provider",
        "synthetic_adt": "/chosen node=1; dram-base=0x10000000000; dram-size=0x400000000; page-size=0x4000",
        "synthetic_layout": {
            "ram_base": hex(MOCK_RAM_BASE),
            "ram_size": hex(MOCK_RAM_SIZE),
            "image_base": hex(MOCK_IMAGE_BASE),
            "image_span": MOCK_IMAGE_SPAN,
            "initrd_base": hex(MOCK_INITRD_BASE),
            "initrd_span": "actual initramfs size",
            "same_window_size": hex(MOCK_LINUX_WINDOW_SIZE),
            "assertions": ["all ranges inside RAM", "image/initrd non-overlap", "same 1GiB window", "memory.reg differs from 8GiB DT placeholder"],
        },
        "bootargs": args.bootargs,
        "synthetic_contract": "32 live CPU release addresses at MOCK_RAM_BASE+0x101000+i*0x1000",
        "initramfs_usage": "actual input bytes hashed and size passed; fixture does not map or copy package bytes",
    }
    (work / "execution-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n",
                                                    encoding="utf-8")
    print(f"PASS: {len(records)} DTB handoff(s); chosen/initrd/memory/CPU fixups; memory=actual+synthetic-ADT")
    print(f"Evidence: {work}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"FAIL: {error}", file=__import__("sys").stderr)
        raise SystemExit(1)
