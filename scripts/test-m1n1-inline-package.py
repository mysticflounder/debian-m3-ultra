#!/usr/bin/env python3
"""Run the positive host test for the pinned m1n1 inline payload layout.

The fixture is deliberately a valid-input test.  It assembles the documented
contiguous stream, compiles the pinned payload.c and decoder sources into the
host fixture, and retains every command/output artifact under scratch/.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "scratch/m1n1-upstream-xz-seek-guards.m9h56j/m1n1-2460b604c6f016956ead711823605eea840c602e"
FIXTURE = ROOT / "tests/m1n1-inline-package.c"
REPORT_ROOT = ROOT / "scratch/m1n1-inline-package-tests-2026-10-07"
IMAGE_DECLARED_OFFSET = 0x10
IMAGE_MAGIC_OFFSET = 0x38
IMAGE_MAGIC = b"ARM\x64"
INITRAMFS_MAGIC = b"m1n1_initramfs"
LOADER_PATH = SOURCE_ROOT / "build/m1n1.bin"
LOADER_ELF_PATH = SOURCE_ROOT / "build/m1n1-raw.elf"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read(path: Path) -> bytes:
    return path.read_bytes()


def digest_file(path: Path) -> dict[str, object]:
    data = read(path)
    return {"path": str(path), "size": len(data), "sha256": sha256(data)}


def write_bytes(path: Path, data: bytes) -> None:
    path.write_bytes(data)


def builder_gzip(data: bytes) -> bytes:
    output = io.BytesIO()
    with gzip.GzipFile(fileobj=output, filename="", mode="wb", mtime=0) as stream:
        stream.write(data)
    return output.getvalue()


def checked_path(path: Path, label: str) -> Path:
    path = path.resolve()
    if not path.is_file():
        raise SystemExit(f"{label} is not a file: {path}")
    return path


def source_files() -> list[Path]:
    src = SOURCE_ROOT / "src"
    files = [src / "payload.c"]
    # This positive package contains gzip, FDT and the initramfs wrapper.  The
    # pinned payload source declares XzDecode too, so the fixture supplies a
    # leaf stub; compiling the unrelated ARM-specific XZ implementation would
    # reintroduce its platform typedefs into this host-only test.
    for directory in (src / "tinf", src / "libfdt"):
        files.extend(sorted(directory.glob("*.c")))
    return files


def run_capture(argv: list[str], cwd: Path, stdout_path: Path, stderr_path: Path) -> int:
    result = subprocess.run(argv, cwd=cwd, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=False)
    stdout_path.write_bytes(result.stdout)
    stderr_path.write_bytes(result.stderr)
    return result.returncode


def parse_fixture_output(data: bytes) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in data.decode("utf-8", errors="replace").splitlines():
        if "=" not in raw_line:
            continue
        key, value = raw_line.split("=", 1)
        if key and key.replace("_", "").isalnum():
            values[key] = value
    return values


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--payload", required=True, type=Path,
                        help="full32 m1n1 prefix or assembled inline payload.bin")
    parser.add_argument("--image", required=True, type=Path,
                        help="original arm64 Image (not padded to image_size)")
    parser.add_argument("--dtb", required=True, type=Path,
                        help="J575d device tree blob")
    parser.add_argument("--initramfs", required=True, type=Path,
                        help="compressed cpio initramfs")
    parser.add_argument("--bootargs", required=True,
                        help="chosen.bootargs value without its terminating newline")
    args = parser.parse_args()

    if "\n" in args.bootargs or "\r" in args.bootargs:
        raise SystemExit("--bootargs must not contain a newline; the package adds one")
    payload_path = checked_path(args.payload, "--payload")
    image_path = checked_path(args.image, "--image")
    dtb_path = checked_path(args.dtb, "--dtb")
    initrd_path = checked_path(args.initramfs, "--initramfs")
    if not SOURCE_ROOT.is_dir():
        raise SystemExit(f"pinned source tree is missing: {SOURCE_ROOT}")
    if not FIXTURE.is_file():
        raise SystemExit(f"fixture is missing: {FIXTURE}")

    payload = read(payload_path)
    image = read(image_path)
    dtb = read(dtb_path)
    initrd = read(initrd_path)
    if len(image) < IMAGE_MAGIC_OFFSET + len(IMAGE_MAGIC):
        raise SystemExit("Image is too short for the arm64 Image header")
    if image[IMAGE_MAGIC_OFFSET:IMAGE_MAGIC_OFFSET + len(IMAGE_MAGIC)] != IMAGE_MAGIC:
        raise SystemExit("Image does not have the pinned ARM64 header magic")
    if len(image) < IMAGE_DECLARED_OFFSET + 8:
        raise SystemExit("Image is too short for image_size")
    declared_image_size = struct.unpack_from("<Q", image, IMAGE_DECLARED_OFFSET)[0]
    if declared_image_size < len(image):
        raise SystemExit("Image header image_size is smaller than the original Image")
    if not initrd:
        raise SystemExit("compressed cpio initramfs must be non-empty")

    image_gz = builder_gzip(image)
    bootargs_record = f"chosen.bootargs={args.bootargs}\n".encode("ascii")
    wrapper = INITRAMFS_MAGIC + struct.pack("<I", len(initrd)) + initrd
    trailer = bytes(64)
    inline_stream = bootargs_record + image_gz + dtb + wrapper + trailer
    pinned_loader = read(LOADER_PATH)
    if payload == pinned_loader:
        input_mode = "raw-prefix-assembled"
        m1n1_prefix = payload
        package = payload + inline_stream
    elif payload.startswith(pinned_loader) and len(payload) > len(pinned_loader):
        input_mode = "whole-combined-actual"
        m1n1_prefix = pinned_loader
        package = payload
    elif payload.startswith(b"chosen.bootargs="):
        input_mode = "inline-suffix-assembled"
        if payload != inline_stream:
            raise SystemExit("inline --payload does not match the supplied components")
        m1n1_prefix = b""
        package = payload
    else:
        raise SystemExit("--payload must be the pinned raw prefix, its combined package, or the exact inline suffix")

    prefix_len = len(m1n1_prefix)

    REPORT_ROOT.mkdir(parents=True, exist_ok=True)
    run_dir = Path(tempfile.mkdtemp(prefix="run-", dir=REPORT_ROOT))
    package_path = run_dir / "payload-package.bin"
    m1n1_path = run_dir / "m1n1-prefix.bin"
    generated_fixture = run_dir / "m1n1-inline-package.generated.c"
    executable = run_dir / "m1n1-inline-package"
    write_bytes(package_path, package)
    write_bytes(m1n1_path, m1n1_prefix)

    include_path = str((SOURCE_ROOT / "src/payload.c").resolve()).replace('"', '\\"')
    fixture_text = FIXTURE.read_text()
    marker = "/* INSERT_PAYLOAD_INCLUDE */"
    if fixture_text.count(marker) != 1:
        raise SystemExit("fixture include marker is missing or duplicated")
    generated_fixture.write_text(
        fixture_text.replace(marker, f'#include "{include_path}"', 1))

    compiler = os.environ.get("CC")
    compiler_path = shutil.which(compiler) if compiler else None
    if compiler_path is None:
        compiler_path = shutil.which("clang") or shutil.which("cc") or shutil.which("gcc")
    if compiler_path is None:
        raise SystemExit("no C compiler found (tried CC, clang, cc, gcc)")
    libs = source_files()[1:]
    include_dirs = [SOURCE_ROOT / "src", SOURCE_ROOT / "build"]
    compile_argv = [compiler_path, "-std=c11", "-O1", "-g",
                    "-Wno-unused-function", "-Wno-unused-parameter",
                    "-Wno-unused-variable", "-Wno-unused-but-set-variable",
                    "-include", "stdlib.h",
                    *[f"-I{directory}" for directory in include_dirs],
                    str(generated_fixture), *map(str, libs), "-o", str(executable)]
    compile_stdout = run_dir / "compile.stdout"
    compile_stderr = run_dir / "compile.stderr"
    compile_exit = run_capture(compile_argv, ROOT, compile_stdout, compile_stderr)
    if compile_exit != 0:
        report = {
            "status": "compile-failed",
            "run_dir": str(run_dir),
            "compile": {"argv": compile_argv, "exit": compile_exit,
                        "stdout": str(compile_stdout), "stderr": str(compile_stderr)},
        }
        (run_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({"status": report["status"], "run_dir": str(run_dir),
                          "compile_exit": compile_exit}, sort_keys=True))
        return 1

    run_argv = [str(executable), str(package_path), str(m1n1_path),
                str(image_path), str(dtb_path), str(initrd_path), args.bootargs]
    run_stdout = run_dir / "run.stdout"
    run_stderr = run_dir / "run.stderr"
    run_exit = run_capture(run_argv, ROOT, run_stdout, run_stderr)
    stdout = run_stdout.read_bytes()
    values = parse_fixture_output(stdout)
    expected = {
        "m1n1_size": prefix_len,
        "bootargs_end": prefix_len + len(bootargs_record),
        "gzip_offset": prefix_len + len(bootargs_record),
        "gzip_consumed": package.find(dtb, prefix_len + len(bootargs_record)) -
                         (prefix_len + len(bootargs_record)),
        "dtb_offset": package.find(dtb, prefix_len + len(bootargs_record)),
        "dtb_size": len(dtb),
        "initramfs_wrapper_offset": package.find(INITRAMFS_MAGIC,
                                                  package.find(dtb, prefix_len + len(bootargs_record)) + len(dtb)),
        "initramfs_offset": package.find(INITRAMFS_MAGIC,
                                          package.find(dtb, prefix_len + len(bootargs_record)) + len(dtb)) + len(INITRAMFS_MAGIC) + 4,
        "initramfs_size": len(initrd),
        "initrd_set_pointer_offset": package.find(INITRAMFS_MAGIC,
                                                    package.find(dtb, prefix_len + len(bootargs_record)) + len(dtb)) + len(INITRAMFS_MAGIC) + 4,
        "initrd_set_size": len(initrd),
        "trailer_offset": package.find(bytes(4),
                                        package.find(INITRAMFS_MAGIC,
                                                     package.find(dtb, prefix_len + len(bootargs_record)) + len(dtb)) + len(INITRAMFS_MAGIC) + 4 + len(initrd)),
        "stream_end": package.find(bytes(4),
                                    package.find(INITRAMFS_MAGIC,
                                                 package.find(dtb, prefix_len + len(bootargs_record)) + len(dtb)) + len(INITRAMFS_MAGIC) + 4 + len(initrd)),
        "dtb_selected_offset": package.find(dtb, prefix_len + len(bootargs_record)),
        "chosen_name": "bootargs",
        "chosen_bootargs": args.bootargs,
        "image_decoded_size": len(image),
        "image_declared_size": declared_image_size,
        "kernel_retained_span": declared_image_size,
        "kernel_tail_reservation": declared_image_size - len(image),
        "initrd_set_calls": 1,
        "dtb_prepare_calls": 1,
        "kernel_boot_calls": 1,
    }
    mismatches = {
        key: {"actual": values.get(key), "expected": str(value)}
        for key, value in expected.items() if values.get(key) != str(value)
    }
    if run_exit != 0:
        mismatches["exit"] = {"actual": run_exit, "expected": 0}
    if b"INLINE_PACKAGE_PASS" not in stdout:
        mismatches["pass_marker"] = {"actual": False, "expected": True}
    status = "pass" if not mismatches else "fail"
    report = {
        "status": status,
        "run_dir": str(run_dir),
        "input_mode": input_mode,
        "original_input": digest_file(payload_path),
        "inline_suffix": {"offset": prefix_len, "size": len(package) - prefix_len,
                           "sha256": sha256(package[prefix_len:])},
        "pinned_loader": digest_file(LOADER_PATH),
        "pinned_loader_elf": digest_file(LOADER_ELF_PATH),
        "source": {"root": str(SOURCE_ROOT), "payload_c": digest_file(SOURCE_ROOT / "src/payload.c"),
                   "fixture": digest_file(FIXTURE),
                   "decoder_sources": [digest_file(path) for path in source_files()[1:]]},
        "inputs": {"payload": digest_file(payload_path), "image": digest_file(image_path),
                   "dtb": digest_file(dtb_path), "initramfs": digest_file(initrd_path),
                   "bootargs": args.bootargs},
        "package": {"path": str(package_path), "size": len(package), "sha256": sha256(package),
                    "image_gzip_size": len(image_gz), "image_gzip_sha256": sha256(image_gz),
                    "initramfs_magic": INITRAMFS_MAGIC.decode("ascii"),
                    "trailer_size": len(trailer)},
        "compile": {"argv": compile_argv, "exit": compile_exit,
                    "stdout": str(compile_stdout), "stderr": str(compile_stderr)},
        "run": {"argv": run_argv, "exit": run_exit,
                "stdout": str(run_stdout), "stderr": str(run_stderr),
                "fields": values},
        "expected_fields": expected,
        "mismatches": mismatches,
        "scope": "positive valid contiguous payload recognition and stream advancement only; no native handoff or security testing",
    }
    (run_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"status": status, "run_dir": str(run_dir), "package_size": len(package),
                      "compile_exit": compile_exit, "run_exit": run_exit,
                      "mismatches": len(mismatches)}, sort_keys=True))
    return 0 if status == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
