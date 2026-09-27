#!/usr/bin/env python3
"""Source-extracted host test for the T6032 cpufreq caller guard."""
from __future__ import annotations

import importlib.util
import pathlib
import re
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
PATCH = ROOT / "patches/m1n1/0011-propagate-t6032-cpufreq-failures.patch"
TEMPLATE = ROOT / "tests/m1n1-cpufreq-status.c"


def fail(message: str) -> None:
    raise RuntimeError(message)


def load_status_module():
    path = ROOT / "scripts/test-m1n1-cpu-start-status.py"
    spec = importlib.util.spec_from_file_location("m1n1_cpu_status", path)
    if spec is None or spec.loader is None:
        fail("cannot load existing CPU-status materializer")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def extract_function(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        fail(f"missing function: {signature}")
    brace = source.find("{", start)
    if brace < 0:
        fail(f"missing function body: {signature}")
    depth = 0
    quote = None
    escaped = False
    line = block = False
    for index in range(brace, len(source)):
        char = source[index]
        nxt = source[index + 1] if index + 1 < len(source) else ""
        if line:
            if char == "\n":
                line = False
        elif block:
            if char == "*" and nxt == "/":
                block = False
        elif quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
        elif char in "\"'":
            quote = char
        elif char == "/" and nxt == "/":
            line = True
        elif char == "/" and nxt == "*":
            block = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    fail(f"unterminated function: {signature}")


def run(command: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=False)


def snapshot(tree: pathlib.Path) -> dict[pathlib.Path, bytes]:
    return {
        path.relative_to(tree): path.read_bytes()
        for path in tree.rglob("*") if path.is_file()
    }


def main() -> int:
    clang = shutil.which("clang")
    if clang is None:
        fail("clang is required")
    if not PATCH.is_file() or not TEMPLATE.is_file():
        fail("cpufreq patch or harness template missing")

    status = load_status_module()
    with tempfile.TemporaryDirectory(dir=ROOT / "scratch") as directory:
        work = pathlib.Path(directory)
        tree = status.materialize(work)
        before = snapshot(tree)
        before_payload = before[pathlib.Path("src/payload.c")].decode()
        applied = run(["patch", "-p1", "--batch", "--forward", "--no-backup-if-mismatch",
                       "-i", str(PATCH)], tree)
        if applied.returncode:
            fail(f"0011 did not apply:\n{applied.stdout}{applied.stderr}")
        after = snapshot(tree)
        changed = {
            path for path in set(before) | set(after)
            if before.get(path) != after.get(path)
        }
        if changed != {pathlib.Path("src/payload.c")}:
            fail(f"0011 changed unexpected paths: {sorted(str(path) for path in changed)}")

        after_payload = after[pathlib.Path("src/payload.c")].decode()
        payload = extract_function(after_payload, "int payload_run(void)")
        before_payload = extract_function(before_payload, "int payload_run(void)")
        start = payload.find("if (kernel && fdt) {")
        before_start = before_payload.find("if (kernel && fdt) {")
        if start < 0 or before_start < 0 or payload[:start] != before_payload[:before_start]:
            fail("0011 changed payload_run prefix before the kernel branch")
        end = payload.find("mitigations_perform();", start)
        if end < 0:
            fail("kernel cpufreq caller fragment missing")
        fragment = payload[start:end + len("mitigations_perform();")]
        if fragment.count("cpufreq_init(") != 1 or fragment.count("smp_start_secondaries(") != 1:
            fail("caller fragment does not call cpufreq/SMP exactly once")
        if not re.search(r"chip_id\s*==\s*T6032\s*&&\s*cpufreq_status\s*<\s*0", fragment):
            fail("T6032 cpufreq guard missing")
        if fragment.find("cpufreq_init(") > fragment.find("smp_start_secondaries("):
            fail("cpufreq call is after SMP")
        if fragment.find("smp_start_secondaries(") > fragment.find("mitigations_perform"):
            fail("SMP guard is after downstream work")

        # The extracted prefix intentionally stops at the first downstream
        # statement; close the real kernel branch in the minimal harness.
        template = TEMPLATE.read_text()
        marker = "/* INSERT_PAYLOAD_CPUFREQ_FRAGMENT */"
        if template.count(marker) != 1:
            fail("cpufreq harness marker must occur exactly once")
        source = template.replace(
            marker, fragment + "\n    }")
        generated = work / "cpufreq-status.c"
        binary = work / "cpufreq-status"
        generated.write_text(source)
        compiled = run([clang, "-std=c11", "-O1", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                        "-fno-omit-frame-pointer",
                        str(generated), "-o", str(binary)], work)
        if compiled.returncode:
            fail(f"clang failed:\n{compiled.stdout}{compiled.stderr}")
        completed = run([str(binary)], work)
        if completed.returncode:
            fail(f"cpufreq caller harness failed ({completed.returncode}):\n"
                 f"{completed.stdout}{completed.stderr}")
    print("T6032 cpufreq caller: 9 cases passed; 0011 scope/order verified")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(f"m1n1 cpufreq status harness: ERROR: {exc}")
        raise SystemExit(1)
