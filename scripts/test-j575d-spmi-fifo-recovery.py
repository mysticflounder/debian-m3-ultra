#!/usr/bin/env python3
"""Offline host regression for the Apple-SPMI FIFO recovery register target."""
from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "scratch/j575d-phy-usb-common.W3594q/source"
PATCH = ROOT / "patches/linux/j575d-602042bf/0007-spmi-apple-fifo-recovery-register.patch"
REL = pathlib.Path("drivers/spmi/spmi-apple-controller.c")
FIXTURE = ROOT / "tests/test-j575d-spmi-fifo-recovery.c"


def digest(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def function_source(text: str, name: str) -> str:
    match = re.search(r"(?m)^(?:static\s+)?(?:inline\s+)?[A-Za-z_][\w\s\*]*?\s*" +
                      re.escape(name) + r"\s*\(", text)
    if not match:
        raise AssertionError(f"missing actual function {name}")
    opening = text.find("{", match.end())
    if opening < 0:
        raise AssertionError(f"missing opening brace {name}")
    depth = 0
    quote = None
    escaped = False
    for index in range(opening, len(text)):
        char = text[index]
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char in ('"', "'"):
            quote = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[match.start():index + 1]
    raise AssertionError(f"unterminated actual function {name}")


def apply_patch(root: pathlib.Path) -> None:
    result = subprocess.run(["patch", "--batch", "--forward", "--fuzz=0", "-p0"],
                            cwd=root, input=PATCH.read_bytes(), capture_output=True)
    if result.returncode:
        raise AssertionError(f"corrective patch failed: {result.stderr.decode(errors='replace')}")


def isolated_source(source: pathlib.Path, out: pathlib.Path) -> pathlib.Path:
    tree = out / "isolated-source"
    target = tree / REL
    target.parent.mkdir(parents=True)
    shutil.copyfile(source / REL, target)
    before = target.read_text(encoding="utf-8")
    if "writel(SPMI_ACT_FIFO_FLUSH, spmi->regs + SPMI_RSP_REG)" not in before:
        raise AssertionError("expected retained v10 RSP-target source not found")
    apply_patch(tree)
    after = target.read_text(encoding="utf-8")
    if "writel(SPMI_ACT_FIFO_FLUSH, spmi->regs + SPMI_ACT_REG)" not in after:
        raise AssertionError("corrective ACT target absent after patch")
    return target


def render(controller: pathlib.Path, mutation: bool = False) -> str:
    text = controller.read_text(encoding="utf-8")
    pack = function_source(text, "apple_spmi_pack_cmd")
    wait = function_source(text, "apple_spmi_wait_rx_not_empty")
    raw = function_source(text, "spmi_raw_cmd")
    if mutation:
        changed = raw.replace("spmi->regs + SPMI_ACT_REG", "spmi->regs + SPMI_RSP_REG", 1)
        if changed == raw:
            raise AssertionError("mutation target not found in actual raw command")
        raw = changed
    source = FIXTURE.read_text(encoding="utf-8")
    return source.replace("/* ACTUAL_FUNCTIONS_BEGIN */\n/* ACTUAL_FUNCTIONS_END */",
                          pack + "\n\n" + wait + "\n\n" + raw)


def compile_fixture(source: str, out: pathlib.Path, tag: str) -> pathlib.Path:
    c_file = out / f"{tag}.c"
    binary = out / tag
    c_file.write_text(source, encoding="utf-8")
    clang = shutil.which("clang")
    if not clang:
        raise AssertionError("clang unavailable")
    result = subprocess.run([clang, "-std=c11", "-Wall", "-Wextra", "-Werror",
                             "-Wno-unused-parameter", "-O0", "-fsanitize=address,undefined",
                             "-fno-omit-frame-pointer", str(c_file), "-o", str(binary)],
                            capture_output=True, text=True)
    if result.returncode:
        raise AssertionError(f"compile failed ({tag}):\n{result.stderr}")
    return binary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", type=pathlib.Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output-dir", type=pathlib.Path, required=True)
    args = parser.parse_args()
    source_file = args.source_dir / REL
    if not source_file.is_file() or not PATCH.is_file():
        raise AssertionError("missing source or corrective patch")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    run = pathlib.Path(tempfile.mkdtemp(prefix="fifo-recovery-", dir=args.output_dir))
    patched = isolated_source(args.source_dir, run)
    binary = compile_fixture(render(patched), run, "fixture")
    result = subprocess.run([str(binary)], capture_output=True, text=True)
    (run / "host.stdout").write_text(result.stdout, encoding="utf-8")
    (run / "host.stderr").write_text(result.stderr, encoding="utf-8")
    if result.returncode:
        raise AssertionError(f"host fixture failed ({result.returncode}); see {run}")
    mutant = compile_fixture(render(patched, mutation=True), run, "mutant")
    witness = subprocess.run([str(mutant), "mutation"], capture_output=True, text=True)
    (run / "mutation.stdout").write_text(witness.stdout, encoding="utf-8")
    (run / "mutation.stderr").write_text(witness.stderr, encoding="utf-8")
    if witness.returncode != 1:
        raise AssertionError(f"RSP-target mutation exit={witness.returncode}, expected exact 1")
    if "writes[1].offset == SPMI_ACT_REG" not in witness.stderr:
        raise AssertionError("mutation lacked designated ACT-register assertion")
    receipt = (f"source={args.source_dir}\nsource_sha256={digest(source_file)}\n"
               f"patch_sha256={digest(PATCH)}\npatched_sha256={digest(patched)}\n"
               f"fixture_sha256={digest(FIXTURE)}\nrun={run}\n"
               f"host_exit={result.returncode}\nmutation_exit={witness.returncode}\n")
    (run / "receipt.txt").write_text(receipt, encoding="utf-8")
    print(f"PASS normal=1 timeout_retry=1 mutation_exit={witness.returncode} run={run}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, subprocess.SubprocessError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
