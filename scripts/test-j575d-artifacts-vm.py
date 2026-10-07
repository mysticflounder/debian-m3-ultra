#!/usr/bin/env python3
"""Disposable RAM-only QEMU/HVF sanity check for J575d guest artifacts."""

from __future__ import annotations

import hashlib
import json
import os
import re
import selectors
import subprocess
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


def run() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    run_out = Path(tempfile.mkdtemp(prefix="run-", dir=OUT))
    dtb = run_out / "virt-generated.dtb"
    status: dict[str, object] = {"scope": "guest artifacts under QEMU/HVF; not native J575d qualification"}
    proc: subprocess.Popen[bytes] | None = None
    serial = bytearray()
    qemu_stderr = bytearray()
    try:
        if not QEMU.is_file() or not os.access(QEMU, os.X_OK):
            raise RuntimeError(f"required QEMU executable missing/non-executable: {QEMU}")
        for path, expected in EXPECTED.items():
            if not path.is_file():
                raise RuntimeError(f"required guest artifact missing: {path}")
            actual = sha256(path)
            status[f"sha256:{path.name}"] = actual
            if actual != expected:
                raise RuntimeError(f"unexpected hash for {path}: {actual} != {expected}")

        version = subprocess.run([str(QEMU), "--version"], check=False, capture_output=True, text=True, timeout=15)
        write_text(run_out / "qemu-version.stdout", version.stdout)
        write_text(run_out / "qemu-version.stderr", version.stderr)
        status["qemu_version_exit"] = version.returncode
        status["qemu_sha256"] = sha256(QEMU)
        if version.returncode != 0:
            raise RuntimeError(f"QEMU --version failed: {version.returncode}")

        append = "earlycon=pl011,0x9000000 console=ttyAMA0 rdinit=/init"
        dump_cmd = [str(QEMU), "-M", f"virt,dumpdtb={dtb}", "-accel", "hvf", "-cpu", "host",
                    "-smp", "4", "-m", "2G", "-kernel", str(KERNEL), "-initrd", str(INITRD),
                    "-append", append, "-nic", "none"]
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
            "-kernel", str(KERNEL), "-initrd", str(INITRD), "-append", append,
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
            if all(marker_matches(marker, text) for marker in MARKERS.values()):
                status["readiness"] = "all required guest markers observed"
                break
            if proc.poll() is not None and not selector.get_map():
                break
        else:
            status["timeout_seconds"] = TIMEOUT
        write_text(run_out / "guest.serial.log", serial.decode("utf-8", errors="replace"))
        (run_out / "qemu.stderr.log").write_bytes(qemu_stderr)
        observed = serial.decode("utf-8", errors="replace")
        status["markers"] = {
            name: marker_matches(marker, observed)
            for name, marker in MARKERS.items()
        }
        status["qemu_exit_before_cleanup"] = proc.poll()
        missing = [
            name for name, marker in MARKERS.items()
            if not marker_matches(marker, observed)
        ]
        if missing:
            raise RuntimeError(f"guest readiness markers missing: {', '.join(missing)}")
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
