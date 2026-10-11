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

FORK_SOURCE_ROOT = ROOT / "scratch/m1n1-fork.xd2NO8"
FORK_REPORT_ROOT = ROOT / "scratch/m1n1-inline-package-tests-fork-current-2026-10-11"
FORK_COMMIT = "b91ede42c1eabe5feaebe575df0016191f003ac5"
FORK_LOADER_SHA256 = "7c1c0ef40b0ce7a578fd3fba74333655f89f3ee234968db44ae3fde4e0ba1c70"
FORK_LOADER_ELF_SHA256 = "427d01dc8df26aa9d9f56e5593b50dbc7a26b72f6f840039d2921b5b24f22d7a"
FORK_COMPILED_SOURCE_SHA256 = {
    "src/payload.c": "39dd637c06938dec8559008f2890bd15925b367e8c517f66dcbced2a53258e35",
    "src/tinf/adler32.c": "f35e2d7e6864cccccbdf6d8f1a34caacbbb69dbb70de276829a22216cbc4710f",
    "src/tinf/crc32.c": "7f9b8a8149134e4b9c8ed36d2f0426eebd7264f4117d4648a971fe207cea2350",
    "src/tinf/tinfgzip.c": "c7bdb2d4e14bba50f4d7c8835d504e5b523d75940100335f430f5f5c7fee509d",
    "src/tinf/tinflate.c": "1d4f7879a504a19745f5e88fe00de29bfc697c95fd9c56c08bcaa6b745e2fc83",
    "src/tinf/tinfzlib.c": "ba3df9315f8b547443052d277852f57a0ecde8a43f75c0a266ae470ec16696ca",
    "src/libfdt/fdt.c": "6c5e4ff1207fff0edd3c24762bd970880df3df519b442bf335a67785509eb7c8",
    "src/libfdt/fdt_addresses.c": "fdcac2596f2ce6b3cfc62fd0b29a1fdb5801002178ca018cffa3a5f4ad95a0e4",
    "src/libfdt/fdt_empty_tree.c": "aa6aa13010ea8a0a85320c0c177a4fb42193bce80a6bb72116ae4f8bb6317909",
    "src/libfdt/fdt_overlay.c": "550be2c090ea864130a3c895fa0cdaaeb168a49cf8abb39117b9ca272bdb0967",
    "src/libfdt/fdt_ro.c": "a365e54f12f9247e5c8653b69a7ae4ac6e661b46af435f6f6539640eac71f605",
    "src/libfdt/fdt_rw.c": "0f089361a8d954a1b07e739f38d958672b77b14986695cf36dc84c8fed29d226",
    "src/libfdt/fdt_strerror.c": "6ef50e24ae08912f621cb3c201efb2814e72dfa3b60fea002cce0b3e6bab6a4c",
    "src/libfdt/fdt_sw.c": "74996fdc1e036867ee3daa2fca9d39655f1a1f18a88f8664fff60bac09ec0661",
    "src/libfdt/fdt_wip.c": "b436653fb5d5d75ef54a909afd3be5affed97286aef5432947c194a278e1ca54",
}


def profile_config(name: str) -> dict[str, object]:
    if name == "historical":
        return {
            "name": name,
            "source_root": SOURCE_ROOT,
            "report_root": REPORT_ROOT,
            "loader": SOURCE_ROOT / "build/m1n1.bin",
            "loader_elf": SOURCE_ROOT / "build/m1n1-raw.elf",
            "expected_commit": None,
            "expected_loader_sha256": None,
            "expected_loader_elf_sha256": None,
            "expected_source_sha256": None,
        }
    if name == "fork-current":
        return {
            "name": name,
            "source_root": FORK_SOURCE_ROOT,
            "report_root": FORK_REPORT_ROOT,
            "loader": FORK_SOURCE_ROOT / "build/m1n1.bin",
            "loader_elf": FORK_SOURCE_ROOT / "build/m1n1-raw.elf",
            "expected_commit": FORK_COMMIT,
            "expected_loader_sha256": FORK_LOADER_SHA256,
            "expected_loader_elf_sha256": FORK_LOADER_ELF_SHA256,
            "expected_source_sha256": FORK_COMPILED_SOURCE_SHA256,
        }
    raise SystemExit(f"unknown profile: {name}")


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


def source_files(source_root: Path) -> list[Path]:
    src = source_root / "src"
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
    parser.add_argument("--profile", choices=("historical", "fork-current"),
                        default="historical",
                        help="source/artifact profile (default: historical)")
    parser.add_argument("--source-root", type=Path,
                        help="override the selected profile's source root")
    parser.add_argument("--loader", type=Path,
                        help="override the selected profile's m1n1.bin")
    parser.add_argument("--loader-elf", type=Path,
                        help="override the selected profile's raw ELF")
    parser.add_argument("--report-root", type=Path,
                        help="override the selected profile's scratch report root")
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

    profile = profile_config(args.profile)
    source_root = (args.source_root.resolve() if args.source_root
                   else profile["source_root"])
    loader_path = (args.loader.resolve() if args.loader
                   else profile["loader"])
    loader_elf_path = (args.loader_elf.resolve() if args.loader_elf
                       else profile["loader_elf"])
    report_root = (args.report_root.resolve() if args.report_root
                   else profile["report_root"])
    source_root = Path(source_root)
    loader_path = Path(loader_path)
    loader_elf_path = Path(loader_elf_path)
    report_root = Path(report_root)
    expected_commit = profile["expected_commit"]
    expected_loader_sha256 = profile["expected_loader_sha256"]
    expected_loader_elf_sha256 = profile["expected_loader_elf_sha256"]
    expected_source_sha256 = profile["expected_source_sha256"]

    if "\n" in args.bootargs or "\r" in args.bootargs:
        raise SystemExit("--bootargs must not contain a newline; the package adds one")
    payload_path = checked_path(args.payload, "--payload")
    image_path = checked_path(args.image, "--image")
    dtb_path = checked_path(args.dtb, "--dtb")
    initrd_path = checked_path(args.initramfs, "--initramfs")
    if not source_root.is_dir():
        raise SystemExit(f"selected source tree is missing: {source_root}")
    if not FIXTURE.is_file():
        raise SystemExit(f"fixture is missing: {FIXTURE}")
    loader_path = checked_path(loader_path, "--loader")
    loader_elf_path = checked_path(loader_elf_path, "--loader-elf")
    loader_digest = digest_file(loader_path)
    loader_elf_digest = digest_file(loader_elf_path)
    if (expected_loader_sha256 and
            loader_digest["sha256"] != expected_loader_sha256):
        raise SystemExit(
            f"{args.profile} loader SHA256 mismatch: expected {expected_loader_sha256}, "
            f"got {loader_digest['sha256']}")
    if (expected_loader_elf_sha256 and
            loader_elf_digest["sha256"] != expected_loader_elf_sha256):
        raise SystemExit(
            f"{args.profile} raw ELF SHA256 mismatch: expected {expected_loader_elf_sha256}, "
            f"got {loader_elf_digest['sha256']}")
    compiled_sources = source_files(source_root)
    source_digests = {str(path.relative_to(source_root)): digest_file(path)
                      for path in compiled_sources}
    if expected_source_sha256:
        for relative, expected in expected_source_sha256.items():
            actual = source_digests.get(relative, {}).get("sha256")
            if actual != expected:
                raise SystemExit(
                    f"{args.profile} compiled source SHA256 mismatch for {relative}: "
                    f"expected {expected}, got {actual}")
        unexpected = sorted(set(source_digests) - set(expected_source_sha256))
        if unexpected:
            raise SystemExit(
                f"{args.profile} compiled source set changed: {', '.join(unexpected)}")

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
    pinned_loader = read(loader_path)
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

    report_root.mkdir(parents=True, exist_ok=True)
    run_dir = Path(tempfile.mkdtemp(prefix="run-", dir=report_root))
    package_path = run_dir / "payload-package.bin"
    m1n1_path = run_dir / "m1n1-prefix.bin"
    generated_fixture = run_dir / "m1n1-inline-package.generated.c"
    executable = run_dir / "m1n1-inline-package"
    write_bytes(package_path, package)
    write_bytes(m1n1_path, m1n1_prefix)

    include_path = str((source_root / "src/payload.c").resolve()).replace('"', '\\"')
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
    libs = source_files(source_root)[1:]
    include_dirs = [source_root / "src", source_root / "build"]
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
            "profile": args.profile,
            "run_dir": str(run_dir),
            "source_provenance": {
                "root": str(source_root), "recorded_commit": expected_commit,
                "compiled_source_sha256": source_digests,
                "expected_source_sha256": expected_source_sha256,
                "expected_match": expected_source_sha256 is None or all(
                    source_digests.get(path, {}).get("sha256") == digest
                    for path, digest in expected_source_sha256.items()),
            },
            "loader_provenance": {
                "loader": loader_digest, "raw_elf": loader_elf_digest,
                "expected_loader_sha256": expected_loader_sha256,
                "expected_loader_elf_sha256": expected_loader_elf_sha256,
            },
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
        "profile": args.profile,
        "run_dir": str(run_dir),
        "input_mode": input_mode,
        "original_input": digest_file(payload_path),
        "inline_suffix": {"offset": prefix_len, "size": len(package) - prefix_len,
                           "sha256": sha256(package[prefix_len:])},
        "pinned_loader": loader_digest,
        "pinned_loader_elf": loader_elf_digest,
        "source_provenance": {
            "root": str(source_root), "recorded_commit": expected_commit,
            "compiled_source_sha256": source_digests,
            "expected_source_sha256": expected_source_sha256,
            "expected_match": expected_source_sha256 is None or all(
                source_digests.get(path, {}).get("sha256") == digest
                for path, digest in expected_source_sha256.items()),
        },
        "loader_provenance": {
            "expected_loader_sha256": expected_loader_sha256,
            "expected_loader_elf_sha256": expected_loader_elf_sha256,
        },
        "source": {"root": str(source_root), "payload_c": digest_file(source_root / "src/payload.c"),
                   "fixture": digest_file(FIXTURE),
                   "decoder_sources": [digest_file(path) for path in source_files(source_root)[1:]]},
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
        "scope": "positive valid contiguous payload recognition and stream advancement only; host compilation exercises selected source, not ARM loader execution or native handoff",
    }
    (run_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"status": status, "run_dir": str(run_dir), "package_size": len(package),
                      "compile_exit": compile_exit, "run_exit": run_exit,
                      "mismatches": len(mismatches)}, sort_keys=True))
    return 0 if status == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
