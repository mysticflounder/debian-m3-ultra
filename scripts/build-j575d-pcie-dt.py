#!/usr/bin/env python3
"""Build and verify the offline J575d four-port PCIe DT profile.

The pinned board source is compiled once unchanged and once with the local
status-only fragment included after it.  This is a host-only packaging check:
it does not fetch sources, launch a VM, access hardware, or claim native probe
success.
"""

from __future__ import annotations

import difflib
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
DT_ROOT = ROOT / "scratch/m1n1-board-dt"
SOURCE_MANIFEST = ROOT / "docs/inventory/t6032-board-dt-sources-2026-09-26.json"
FRAGMENT = ROOT / "configs/j575d-pcie-ports.dtsi"
SCRIPT = pathlib.Path(__file__).resolve()
EXPECTED_BASELINE = "e92e5c9dc86731d76dc060759bb622cbad073e4e32e831bf0ca68deef3ff4cd5"
LABELS = (
    "port00", "port01", "port02", "port03",
    "pcie0_dart_0", "pcie0_dart_1", "pcie0_dart_2", "pcie0_dart_3",
)
TARGET_CHANGES = ("port01", "port02", "port03", "pcie0_dart_1", "pcie0_dart_2", "pcie0_dart_3")
INCLUDE_RE = re.compile(r"^\s*#include\s+[<\"]([^>\"]+)[>\"]")


class BuildError(RuntimeError):
    pass


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fail(message: str) -> None:
    raise BuildError(message)


def load_manifest() -> list[dict[str, str]]:
    try:
        entries = json.loads(SOURCE_MANIFEST.read_text(encoding="utf-8"))["source_files"]
    except (OSError, KeyError, json.JSONDecodeError) as exc:
        fail(f"cannot read board source manifest: {exc}")
    if len(entries) != 19:
        fail(f"expected 19 board closure files, found {len(entries)}")
    return entries


def verify_closure(entries: list[dict[str, str]]) -> dict[str, Any]:
    listed = {entry["local"] for entry in entries}
    discovered: set[str] = set()
    pending = ["t6032-j575d.dts"]
    while pending:
        relative = pending.pop()
        if relative in discovered:
            continue
        discovered.add(relative)
        source = DT_ROOT / relative
        if not source.is_file():
            fail(f"missing closure file: {relative}")
        for line in source.read_text(encoding="utf-8").splitlines():
            match = INCLUDE_RE.match(line)
            if not match:
                continue
            include = match.group(1)
            local = source.parent / include
            candidate = local.relative_to(DT_ROOT) if local.is_file() else pathlib.Path(include)
            name = candidate.as_posix()
            if name not in listed:
                fail(f"include absent from manifest: {name}")
            pending.append(name)
    if discovered != listed:
        fail(f"manifest/include mismatch: extra={sorted(listed - discovered)} missing={sorted(discovered - listed)}")

    actual: list[dict[str, str]] = []
    for entry in entries:
        path = DT_ROOT / entry["local"]
        digest = sha256(path)
        if digest != entry["sha256"]:
            fail(f"closure SHA-256 mismatch: {entry['local']}")
        actual.append({"local": entry["local"], "sha256": digest})
    return {"count": len(actual), "manifest": str(SOURCE_MANIFEST), "files": actual}


def record_command(work: pathlib.Path, name: str, argv: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
    commands = work / "commands"
    commands.mkdir(exist_ok=True)
    try:
        completed = subprocess.run(argv, cwd=cwd, text=True, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, check=False)
    except OSError as exc:
        completed = subprocess.CompletedProcess(argv, 127, "", str(exc))
    (commands / f"{name}.json").write_text(
        json.dumps({"argv": argv, "cwd": str(cwd), "exit": completed.returncode}, indent=2) + "\n",
        encoding="utf-8")
    (commands / f"{name}.stdout").write_text(completed.stdout, encoding="utf-8")
    (commands / f"{name}.stderr").write_text(completed.stderr, encoding="utf-8")
    (commands / f"{name}.exit").write_text(f"{completed.returncode}\n", encoding="utf-8")
    return completed


def compile_variant(work: pathlib.Path, name: str, source: pathlib.Path, dtc: str) -> dict[str, Any]:
    preprocessed = work / f"{name}.pp.dts"
    output = work / f"{name}.dtb"
    cpp_argv = ["clang", "-E", "-nostdinc", "-undef", "-D__DTS__", "-x", "assembler-with-cpp",
                "-I", str(DT_ROOT), "-I", str(DT_ROOT / "dt-bindings"), "-I", str(FRAGMENT.parent), str(source)]
    cpp = record_command(work, f"{name}-clang", cpp_argv, work)
    if cpp.returncode:
        fail(f"{name} DTS preprocessing failed; see commands/{name}-clang.stderr")
    preprocessed.write_text(cpp.stdout, encoding="utf-8")
    dtc_argv = [dtc, "-@", "-I", "dts", "-O", "dtb", "-o", str(output), str(preprocessed)]
    compiled = record_command(work, f"{name}-dtc", dtc_argv, work)
    if compiled.returncode:
        fail(f"{name} DTB compilation failed; see commands/{name}-dtc.stderr")
    warnings = [line for line in compiled.stderr.splitlines() if "Warning (" in line]
    (work / f"{name}.warnings").write_text("\n".join(warnings) + "\n", encoding="utf-8")
    return {"dtb": str(output), "sha256": sha256(output), "warnings": len(warnings),
            "warning_categories": sorted(set(re.findall(r"Warning \(([^)]+)\)", "\n".join(warnings))))}


def decompile(work: pathlib.Path, name: str, dtb: pathlib.Path, dtc: str) -> pathlib.Path:
    output = work / f"{name}.decompiled.dts"
    argv = [dtc, "-I", "dtb", "-O", "dts", "-o", str(output), str(dtb)]
    completed = record_command(work, f"{name}-decompile", argv, work)
    if completed.returncode:
        fail(f"{name} DTB decompile failed; see commands/{name}-decompile.stderr")
    return output


def label_paths(work: pathlib.Path, name: str, dtb: pathlib.Path, fdtget: str) -> dict[str, dict[str, str]]:
    result: dict[str, dict[str, str]] = {}
    for label in LABELS:
        path_argv = [fdtget, str(dtb), "/__symbols__", label]
        path_run = record_command(work, f"{name}-symbol-{label}", path_argv, work)
        path = path_run.stdout.strip()
        if path_run.returncode or not path.startswith("/"):
            fail(f"{name} __symbols__ missing {label}")
        status_argv = [fdtget, "-d", "okay", "-t", "s", str(dtb), path, "status"]
        status_run = record_command(work, f"{name}-status-{label}", status_argv, work)
        status = status_run.stdout.strip()
        if status_run.returncode or status not in ("okay", "disabled"):
            fail(f"{name} {label} status is {status!r}")
        result[label] = {"path": path, "status": status}
    return result


def verify_only_status_changes(work: pathlib.Path, baseline: pathlib.Path, profile: pathlib.Path) -> int:
    old = baseline.read_text(encoding="utf-8").splitlines(keepends=True)
    new = profile.read_text(encoding="utf-8").splitlines(keepends=True)
    diff = list(difflib.unified_diff(old, new, fromfile=str(baseline), tofile=str(profile)))
    (work / "baseline-profile.diff").write_text("".join(diff), encoding="utf-8")
    removed = [line[1:].strip() for line in diff if line.startswith("-") and not line.startswith("---")]
    added = [line[1:].strip() for line in diff if line.startswith("+") and not line.startswith("+++")]
    if removed != ["status = \"disabled\";"] * 6 or added != ["status = \"okay\";"] * 6:
        fail(f"DT profile changed more than six statuses: removed={removed!r} added={added!r}")
    return len(removed)


def tool_version(work: pathlib.Path, name: str, argv: list[str]) -> str:
    completed = record_command(work, f"tool-{name}", argv, ROOT)
    return (completed.stdout + completed.stderr).strip()


def main() -> int:
    if sys.argv[1:]:
        fail("usage: build-j575d-pcie-dt.py")
    if not DT_ROOT.is_dir() or not FRAGMENT.is_file():
        fail("pinned DT closure or local fragment missing")
    clang = shutil.which("clang")
    dtc = shutil.which("dtc") or ("/opt/homebrew/bin/dtc" if pathlib.Path("/opt/homebrew/bin/dtc").is_file() else None)
    fdtget = shutil.which("fdtget") or ("/opt/homebrew/bin/fdtget" if pathlib.Path("/opt/homebrew/bin/fdtget").is_file() else None)
    if not clang or not dtc or not fdtget:
        fail("clang, dtc, and fdtget are required")
    work = pathlib.Path(tempfile.mkdtemp(prefix="j575d-pcie-dt.", dir=ROOT / "scratch"))
    try:
        entries = load_manifest()
        closure = verify_closure(entries)
        board = DT_ROOT / "t6032-j575d.dts"
        if sha256(board) != next(entry["sha256"] for entry in entries if entry["local"] == "t6032-j575d.dts"):
            fail("candidate board source changed")
        versions = {"clang": tool_version(work, "clang-version", [clang, "--version"]),
                    "dtc": tool_version(work, "dtc-version", [dtc, "--version"]),
                    "fdtget": tool_version(work, "fdtget-version", [fdtget, "--version"])}
        baseline = compile_variant(work, "baseline", board, dtc)
        if baseline["sha256"] != EXPECTED_BASELINE:
            fail(f"baseline DTB SHA-256 {baseline['sha256']} != expected {EXPECTED_BASELINE}")
        wrapper = work / "profile-wrapper.dts"
        wrapper.write_text('#include "t6032-j575d.dts"\n#include "j575d-pcie-ports.dtsi"\n', encoding="utf-8")
        profile = compile_variant(work, "profile", wrapper, dtc)
        if baseline["warnings"] == 0 or profile["warnings"] == 0:
            fail("DTC warning receipts unexpectedly empty; warnings must remain visible")
        baseline_dts = decompile(work, "baseline", pathlib.Path(baseline["dtb"]), dtc)
        profile_dts = decompile(work, "profile", pathlib.Path(profile["dtb"]), dtc)
        changes = verify_only_status_changes(work, baseline_dts, profile_dts)
        baseline_labels = label_paths(work, "baseline", pathlib.Path(baseline["dtb"]), fdtget)
        profile_labels = label_paths(work, "profile", pathlib.Path(profile["dtb"]), fdtget)
        if any(baseline_labels[label]["path"] != profile_labels[label]["path"] for label in LABELS):
            fail("profile changed __symbols__ paths")
        for label in LABELS:
            expected = "disabled" if label in TARGET_CHANGES else "okay"
            if baseline_labels[label]["status"] != expected:
                fail(f"baseline {label} status {baseline_labels[label]['status']!r} != {expected!r}")
        for label in LABELS:
            if profile_labels[label]["status"] != "okay":
                fail(f"profile did not enable {label}")
        if baseline_labels["port00"]["status"] != "okay" or baseline_labels["pcie0_dart_0"]["status"] != "okay":
            fail("baseline port00/DART0 are not enabled as expected")

        manifest = {
            "schema_version": 1,
            "status": "offline_board_profile_pass",
            "native_boot_approved": False,
            "scope": "offline DT packaging only; not hardware/probe proof",
            "workspace": str(work),
            "source_closure": closure,
            "source_hashes": {"candidate_dts": sha256(board), "fragment": sha256(FRAGMENT),
                              "manifest": sha256(SOURCE_MANIFEST), "wrapper": sha256(wrapper),
                              "builder": sha256(SCRIPT)},
            "original_dt": {"path": str(board), "sha256": sha256(board), "unchanged": True},
            "baseline": baseline,
            "profile": profile,
            "status_changes": changes,
            "baseline_labels": baseline_labels,
            "labels": profile_labels,
            "tools": versions,
            "recipe": {"cpp": "clang -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp -I closure -I configs",
                        "dtc": "dtc -@ -I dts -O dtb", "include_order": ["t6032-j575d.dts", str(FRAGMENT)]},
            "checks": {"baseline_sha_matches_pinned": True, "only_six_status_changes": True,
                       "all_four_ports_enabled": True, "all_four_darts_enabled": True,
                       "warnings_retained": True, "native_or_probe_tested": False},
        }
        (work / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"workspace={work}")
        print(f"baseline_sha256={baseline['sha256']} profile_sha256={profile['sha256']}")
        print(f"closure_files={closure['count']} status_changes={changes} warnings={profile['warnings']}")
        print(f"manifest={work / 'manifest.json'}")
    except Exception:
        # Keep the fresh workspace and command receipts for diagnosis.
        raise
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BuildError as exc:
        print(f"j575d PCIe DT build: ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
