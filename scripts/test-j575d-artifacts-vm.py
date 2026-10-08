#!/usr/bin/env python3
"""Disposable RAM-only QEMU/HVF sanity check for J575d guest artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import selectors
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "scratch/j575d-artifact-vm-2026-10-07"
QEMU = Path("/opt/homebrew/bin/qemu-system-aarch64")
KERNEL = ROOT / "scratch/linux-j575d-kernel.HdzQNm/build/arch/arm64/boot/Image"
INITRD = ROOT / "scratch/j575d-initramfs.tZHcMp/output/initramfs.cpio.gz"
TIMEOUT = 30.0
EXPECTED = {
    KERNEL: "ad9b573e66738d13d7758619809cc7e8ff09cf9498e23ccec352dfe42b285f50",
    INITRD: "1a2cd5df6ed871974710566514133665f290ac224026fbb6f1819c681c92e986",
}
DEFAULT_MODULES = (
    "apple_dart",
    "apple_mailbox",
    "apple_rtkit",
    "apple_sart",
    "nvme_core",
    "nvme_apple",
)
MARKERS = {
    "diag": r"^J575D_INITRAMFS_DIAG: begin ram-only diagnostic; no persistent root, network, firmware, or raw devices(?:$|\[)",
    "uname": r"^J575D_INITRAMFS_DIAG: uname=Linux 7\.3\.0-rc6(?:\s|$)",
    "release": r"^J575D_INITRAMFS_DIAG: uname=Linux 7\.3\.0-rc6(?:\s|$)",
    "pagesize": r"^J575D_INITRAMFS_DIAG: runtime_pagesize=16384$",
    "cpu_online": r"^J575D_INITRAMFS_DIAG: cpu_online=0-3$",
    # printk can interleave a timestamp after PID1's flushed cmdline line.
    "cmdline": r"^J575D_INITRAMFS_DIAG: cmdline=earlycon=pl011,0x9000000 console=ttyAMA0 rdinit=/init(?:$|\[)",
    "cmdline_rdinit": r"^J575D_INITRAMFS_DIAG: cmdline=earlycon=pl011,0x9000000 console=ttyAMA0 rdinit=/init(?:$|\[)",
    "cmdline_console": r"^J575D_INITRAMFS_DIAG: cmdline=earlycon=pl011,0x9000000 console=ttyAMA0 rdinit=/init(?:$|\[)",
    "alive": r"^J575D_INITRAMFS_DIAG: alive; PID1 will not exit$",
}
MODULE_FAILURE_RE = re.compile(
    r"(?i)(?:module_load_failed|invalid module|unknown symbol|unresolved symbol|"
    r"exec format error|failed to load module|module .* failed|module .* error|error .* module)"
)
MODULE_ROW_RE = re.compile(r"^(?P<name>[A-Za-z0-9_+.-]+)\s+\d+\s+\d+\s+\S+\s+\S+\s+\S+$")


def sha256_argument(value: str) -> str:
    if not re.fullmatch(r"[0-9a-fA-F]{64}", value):
        raise argparse.ArgumentTypeError("must be exactly 64 hexadecimal SHA-256 digits")
    return value.lower()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--initramfs", type=Path, default=INITRD, help=f"initramfs to boot (default: {INITRD})")
    parser.add_argument(
        "--initramfs-sha256",
        type=sha256_argument,
        default=EXPECTED[INITRD],
        help="expected SHA-256 for --initramfs (the pinned default is retained)",
    )
    parser.add_argument("--module-package", type=Path, help="read-only package containing kernel modules")
    parser.add_argument(
        "--expect-module",
        action="append",
        dest="expected_modules",
        metavar="NAME",
        help="complete expected module set, including retained six; repeat for each module",
    )
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_text(path: Path, value: str) -> None:
    path.write_text(value, encoding="utf-8")


def terminate_child(proc: subprocess.Popen[bytes] | None) -> None:
    if proc is None or proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)


def marker_matches(pattern: str, text: str) -> bool:
    """Match retained serial diagnostics while accepting terminal CRLF framing."""
    return bool(re.search(pattern, text.replace("\r\n", "\n"), flags=re.MULTILINE))


def normalize_module_name(name: str) -> str:
    return name.replace("-", "_")


def module_snapshot(text: str) -> tuple[set[str], list[str]]:
    """Parse the prefixed /proc/modules line and its bare continuation rows."""
    lines = text.replace("\r\n", "\n").splitlines()
    names: set[str] = set()
    rows: list[str] = []
    for index, line in enumerate(lines):
        prefix = "J575D_INITRAMFS_DIAG: modules="
        if not line.startswith(prefix):
            continue
        candidates = [line[len(prefix):]]
        for continuation in lines[index + 1:]:
            if continuation.startswith("J575D_INITRAMFS_DIAG:"):
                break
            candidates.append(continuation)
        for row in candidates:
            match = MODULE_ROW_RE.fullmatch(row)
            if match is not None:
                names.add(normalize_module_name(match.group("name")))
                rows.append(row)
        break
    return names, rows


def parse_builder_modinfo(path: Path, release: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    raw = path.read_text(encoding="utf-8")
    for line in raw.splitlines():
        key, separator, value = line.partition(":")
        if separator and key in {"name", "depends", "vermagic"}:
            fields.setdefault(key, value.strip())
    missing = [field for field in ("name", "depends", "vermagic") if field not in fields]
    if missing:
        raise RuntimeError(f"builder modinfo missing fields for {path.name}: {', '.join(missing)}")
    if not fields["name"] or fields["vermagic"].split()[0] != release:
        raise RuntimeError(f"builder modinfo release/name mismatch for {path.name}")
    return fields


def prepare_module_package(
    package: Path,
    expected_modules: tuple[str, ...],
    run_out: Path,
    status: dict[str, object],
) -> list[dict[str, object]]:
    package = package.expanduser().resolve()
    if not package.is_dir():
        raise RuntimeError(f"module package is not a directory: {package}")
    manifest = package / "modules.load"
    if not manifest.is_file():
        raise RuntimeError(f"module package manifest missing: {manifest}")

    guest_paths: list[str] = []
    release: str | None = None
    package_root = package.resolve()
    for raw_line in manifest.read_text(encoding="utf-8").splitlines():
        guest_path = raw_line.strip()
        if not guest_path:
            continue
        match = re.fullmatch(r"/lib/modules/([^/]+)/kernel/(.+\.ko)", guest_path)
        if match is None:
            raise RuntimeError(f"invalid modules.load entry: {guest_path}")
        this_release = match.group(1)
        if release is None:
            release = this_release
        elif release != this_release:
            raise RuntimeError("modules.load contains multiple kernel releases")
        local_path = package / guest_path.lstrip("/")
        resolved_path = local_path.resolve()
        if not resolved_path.is_relative_to(package_root) or not resolved_path.is_file():
            raise RuntimeError(f"module package file missing or escapes package: {local_path}")
        guest_paths.append(guest_path)
    if release is None or len(guest_paths) != len(set(guest_paths)):
        raise RuntimeError("modules.load must contain unique module paths")
    expected_normalized = {normalize_module_name(name) for name in expected_modules}
    if len(guest_paths) != len(expected_normalized):
        raise RuntimeError(
            f"modules.load must contain {len(expected_normalized)} expected modules, found {len(guest_paths)}"
        )

    release_root = package / "lib" / "modules" / release
    dependencies = release_root / "modules.dep"
    aliases = release_root / "modules.alias"
    for metadata_file in (dependencies, aliases):
        if not metadata_file.is_file() or metadata_file.stat().st_size == 0:
            raise RuntimeError(f"module package metadata missing or empty: {metadata_file}")
    builder_metadata = package.parent / "metadata"
    if not builder_metadata.is_dir():
        raise RuntimeError(f"builder module metadata directory missing: {builder_metadata}")

    records: list[dict[str, object]] = []
    for guest_path in guest_paths:
        local_path = package / guest_path.lstrip("/")
        relative_module = local_path.relative_to(release_root / "kernel")
        modinfo_path = builder_metadata / f"{str(relative_module).replace('/', '__')}.modinfo"
        if not modinfo_path.is_file():
            # The retained six-module builder uses legacy basename records.
            modinfo_path = builder_metadata / f"{local_path.name}.modinfo"
        if not modinfo_path.is_file():
            raise RuntimeError(f"builder modinfo record missing: {modinfo_path}")
        fields = parse_builder_modinfo(modinfo_path, release)
        records.append(
            {
                "name": fields["name"],
                "normalized_name": normalize_module_name(fields["name"]),
                "path": guest_path,
                "local_path": str(local_path),
                "sha256": sha256(local_path),
                "modinfo_path": str(modinfo_path),
                "modinfo_sha256": sha256(modinfo_path),
                "modinfo": fields,
            }
        )

    actual_names = {str(record["normalized_name"]) for record in records}
    missing = sorted(expected_normalized - actual_names)
    if missing:
        raise RuntimeError(f"expected module names absent from builder modinfo: {', '.join(missing)}")
    if len(actual_names) != len(records):
        raise RuntimeError("builder modinfo contains duplicate module names")

    write_text(run_out / "modules.load", manifest.read_text(encoding="utf-8"))
    status["module_package"] = str(package)
    status["module_release"] = release
    status["module_manifest"] = {"path": str(manifest), "sha256": sha256(manifest)}
    status["module_dep"] = {"path": str(dependencies), "sha256": sha256(dependencies)}
    status["module_alias"] = {"path": str(aliases), "sha256": sha256(aliases)}
    status["module_records"] = records
    return records


def run() -> int:
    args = parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    run_out = Path(tempfile.mkdtemp(prefix="run-", dir=OUT))
    dtb = run_out / "virt-generated.dtb"
    initrd = args.initramfs.expanduser().resolve()
    expected_modules = (
        tuple(args.expected_modules or DEFAULT_MODULES)
        if args.module_package
        else tuple(args.expected_modules or ())
    )
    status: dict[str, object] = {
        "scope": "guest artifacts under QEMU/HVF virt; no Apple hardware binding claim; not native J575d qualification",
        "ram_only": True,
        "disks": False,
        "network": "none",
        "firmware": False,
        "harness_argv": list(sys.argv),
        "initramfs": str(initrd),
        "initramfs_sha256_expected": args.initramfs_sha256,
        "module_expectations": list(expected_modules),
    }
    proc: subprocess.Popen[bytes] | None = None
    serial = bytearray()
    qemu_stderr = bytearray()
    try:
        if args.expected_modules and not args.module_package:
            raise RuntimeError("--expect-module requires --module-package")
        normalized_expectations = [normalize_module_name(name) for name in expected_modules]
        if args.module_package and len(set(normalized_expectations)) != len(normalized_expectations):
            raise RuntimeError("--expect-module names must be unique")
        if args.module_package:
            missing_defaults = sorted(set(DEFAULT_MODULES) - set(normalized_expectations))
            if missing_defaults:
                raise RuntimeError(f"module expectations must include: {', '.join(missing_defaults)}")
        if not QEMU.is_file() or not os.access(QEMU, os.X_OK):
            raise RuntimeError(f"required QEMU executable missing/non-executable: {QEMU}")
        artifacts = ((KERNEL, EXPECTED[KERNEL]), (initrd, args.initramfs_sha256))
        for path, expected in artifacts:
            if not path.is_file():
                raise RuntimeError(f"required guest artifact missing: {path}")
            actual = sha256(path)
            status[f"sha256:{path.name}"] = actual
            status.setdefault("artifact_hashes", {})[str(path)] = actual
            if actual != expected:
                raise RuntimeError(f"unexpected hash for {path}: {actual} != {expected}")

        module_records: list[dict[str, object]] = []
        if args.module_package:
            module_records = prepare_module_package(args.module_package, expected_modules, run_out, status)
        module_paths_by_name = {
            str(record["normalized_name"]): str(record["path"]) for record in module_records
        }
        required_markers = dict(MARKERS)
        for name in expected_modules:
            normalized = normalize_module_name(name)
            if normalized not in module_paths_by_name:
                raise RuntimeError(f"no module package path derived for expected module: {name}")
            required_markers[f"module_loaded:{normalized}"] = (
                rf"^J575D_INITRAMFS_DIAG: module_loaded={re.escape(module_paths_by_name[normalized])}$"
            )
        if module_records:
            required_markers["modules_snapshot"] = r"^J575D_INITRAMFS_DIAG: modules=.*$"
        expected_normalized = {normalize_module_name(name) for name in expected_modules}

        version = subprocess.run([str(QEMU), "--version"], check=False, capture_output=True, text=True, timeout=15)
        write_text(run_out / "qemu-version.stdout", version.stdout)
        write_text(run_out / "qemu-version.stderr", version.stderr)
        status["qemu_version_exit"] = version.returncode
        status["qemu_sha256"] = sha256(QEMU)
        status["qemu"] = {
            "path": str(QEMU),
            "sha256": status["qemu_sha256"],
            "version_argv": [str(QEMU), "--version"],
            "version_exit": version.returncode,
            "version_stdout": version.stdout,
            "version_stderr": version.stderr,
        }
        if version.returncode != 0:
            raise RuntimeError(f"QEMU --version failed: {version.returncode}")

        append = "earlycon=pl011,0x9000000 console=ttyAMA0 rdinit=/init"
        dump_cmd = [
            str(QEMU), "-M", f"virt,dumpdtb={dtb}", "-accel", "hvf", "-cpu", "host",
            "-smp", "4", "-m", "2G", "-kernel", str(KERNEL), "-initrd", str(initrd),
            "-append", append, "-nic", "none",
        ]
        write_text(run_out / "dumpdtb.argv", json.dumps(dump_cmd) + "\n")
        dump = subprocess.run(dump_cmd, check=False, capture_output=True, timeout=15)
        (run_out / "dumpdtb.stdout").write_bytes(dump.stdout)
        (run_out / "dumpdtb.stderr").write_bytes(dump.stderr)
        status["dumpdtb_exit"] = dump.returncode
        if dump.returncode != 0 or not dtb.is_file():
            raise RuntimeError(f"QEMU virt DTB generation failed: exit={dump.returncode}")
        status["virt_dtb_sha256"] = sha256(dtb)

        boot_cmd = [
            str(QEMU), "-M", "virt", "-accel", "hvf", "-cpu", "host", "-smp", "4", "-m", "2G",
            "-kernel", str(KERNEL), "-initrd", str(initrd), "-append", append,
            "-nographic", "-monitor", "none", "-serial", "stdio", "-nic", "none", "-no-reboot",
        ]
        write_text(run_out / "boot.argv", json.dumps(boot_cmd) + "\n")
        proc = subprocess.Popen(boot_cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert proc.stdout is not None and proc.stderr is not None
        selector = selectors.DefaultSelector()
        selector.register(proc.stdout, selectors.EVENT_READ, "serial")
        selector.register(proc.stderr, selectors.EVENT_READ, "qemu-stderr")
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            for key, _ in selector.select(max(0.0, deadline - time.monotonic())):
                data = key.fileobj.read1(65536)
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                if key.data == "serial":
                    serial.extend(data)
                else:
                    qemu_stderr.extend(data)
            text = serial.decode("utf-8", errors="replace")
            snapshot_names, _ = module_snapshot(text)
            snapshots_ready = not module_records or expected_normalized.issubset(snapshot_names)
            if all(marker_matches(marker, text) for marker in required_markers.values()) and snapshots_ready:
                status["readiness"] = "all required guest markers observed"
                break
            if proc.poll() is not None and not selector.get_map():
                break
        else:
            status["timeout_seconds"] = TIMEOUT
        write_text(run_out / "guest.serial.log", serial.decode("utf-8", errors="replace"))
        (run_out / "qemu.stderr.log").write_bytes(qemu_stderr)
        observed = serial.decode("utf-8", errors="replace")
        snapshot_names, snapshot_rows = module_snapshot(observed)
        status["markers"] = {
            name: marker_matches(marker, observed) for name, marker in required_markers.items()
        }
        status["module_snapshot_names"] = {
            normalize_module_name(name): normalize_module_name(name) in snapshot_names
            for name in expected_modules
        }
        status["module_snapshot_rows"] = snapshot_rows
        status["qemu_exit_before_cleanup"] = proc.poll()
        forbidden = [
            f"serial:{line}" for line in observed.splitlines() if MODULE_FAILURE_RE.search(line)
        ] + [
            f"qemu-stderr:{line}"
            for line in qemu_stderr.decode("utf-8", errors="replace").splitlines()
            if MODULE_FAILURE_RE.search(line)
        ]
        status["forbidden_module_diagnostics"] = forbidden
        missing = [
            name for name, marker in required_markers.items() if not marker_matches(marker, observed)
        ]
        if missing:
            raise RuntimeError(f"guest readiness markers missing: {', '.join(missing)}")
        if forbidden:
            raise RuntimeError("invalid module or unresolved-symbol diagnostics observed")
        if module_records:
            missing_snapshot = [
                name for name, present in status["module_snapshot_names"].items() if not present
            ]
            if missing_snapshot:
                raise RuntimeError(f"expected modules absent from /proc/modules snapshot: {', '.join(missing_snapshot)}")
        return 0
    except Exception as exc:
        status["failure"] = str(exc)
        return 1
    finally:
        terminate_child(proc)
        if proc is not None:
            status["qemu_exit_after_cleanup"] = proc.returncode
        # The child may have buffered a final fragment after readiness/timeout.
        if proc is not None and proc.stdout is not None and proc.stderr is not None:
            try:
                tail_out, tail_err = proc.communicate(timeout=5)
                if tail_out:
                    serial.extend(tail_out)
                if tail_err:
                    qemu_stderr.extend(tail_err)
                write_text(run_out / "guest.serial.log", serial.decode("utf-8", errors="replace"))
                (run_out / "qemu.stderr.log").write_bytes(qemu_stderr)
            except subprocess.TimeoutExpired:
                pass
        status["run_dir"] = str(run_out.relative_to(ROOT))
        write_text(run_out / "status.json", json.dumps(status, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    raise SystemExit(run())
