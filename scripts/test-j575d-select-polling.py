#!/usr/bin/env python3
"""Offline host tests for the opt-in ACE3 selector polling prototype.

The C fixture is only a fake SPMI/clock/completion environment.  Selector,
read, write, and IRQ bodies are extracted from the isolated, patched driver;
the polling algorithm is never reimplemented by this test.
"""
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
DEFAULT_PATCH = ROOT / "patches/linux/j575d-602042bf/0006-typec-tipd-experimental-select-polling.patch"
BASE_BINDING_PATCH = ROOT / "patches/linux/j575d-602042bf/0004-apple-spmi-and-ace3-bindings.patch"
SPMI = pathlib.Path("drivers/usb/typec/tipd/spmi.c")
HEADER = pathlib.Path("drivers/usb/typec/tipd/tps6598x.h")
SN_BINDING = pathlib.Path("Documentation/devicetree/bindings/usb/apple,sn201202x.yaml")
SPMI_BINDING = pathlib.Path("Documentation/devicetree/bindings/spmi/apple,spmi.yaml")
FIXTURE = ROOT / "tests/test-j575d-select-polling.c"


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def function_source(text: str, name: str) -> str:
    match = re.search(r"(?m)^(?:static\s+)?[A-Za-z_][\w\s\*]*?\s*" +
                      re.escape(name) + r"\s*\(", text)
    if not match:
        raise AssertionError(f"missing implementation function {name}")
    opening = text.find("{", match.end())
    if opening < 0:
        raise AssertionError(f"missing opening brace for {name}")
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
    raise AssertionError(f"unterminated implementation function {name}")


def copy_input(source: pathlib.Path, isolated: pathlib.Path) -> None:
    rels = (SPMI, HEADER, SPMI_BINDING)
    if (source / SN_BINDING).is_file():
        rels += (SN_BINDING,)
    for rel in rels:
        src = source / rel
        if not src.is_file():
            raise AssertionError(f"missing frozen source input: {src}")
        dst = isolated / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)


def apply_patch(root: pathlib.Path, patch: pathlib.Path) -> None:
    result = subprocess.run(["patch", "--batch", "--forward", "--fuzz=0", "-p0"],
                            cwd=root, input=patch.read_bytes(), capture_output=True)
    if result.returncode:
        raise AssertionError(f"patch failed: {patch}\n{result.stderr.decode(errors='replace')}")


def isolated_driver(source: pathlib.Path, patch: pathlib.Path, out: pathlib.Path) -> pathlib.Path:
    tree = out / "isolated-source"
    tree.mkdir(parents=True)
    copy_input(source, tree)
    spmi = tree / SPMI
    if "sn201202x_select_reg_poll" in spmi.read_text(encoding="utf-8"):
        raise AssertionError("source already contains polling helper; runner requires an unpatched base")
    if not (tree / SN_BINDING).is_file():
        # The retained source has the ACE3 driver but not its binding.  Apply
        # only the retained binding patch in the isolated copy before 0006.
        apply_patch(tree, BASE_BINDING_PATCH)
    text = spmi.read_text(encoding="utf-8")
    apply_patch(tree, patch)
    if "sn201202x_select_reg_poll" not in spmi.read_text(encoding="utf-8"):
        raise AssertionError("isolated driver did not contain polling helper")
    return spmi


def render_fixture(spmi: pathlib.Path, *, mutate: bool = False) -> str:
    text = spmi.read_text(encoding="utf-8")
    names = ("sn201202x_validate_polling_irqs", "sn201202x_select_reg_poll",
             "regmap_sn201202x_select_reg", "regmap_sn201202x_read",
             "regmap_sn201202x_write", "sn201202x_irq", "sn201202x_probe")
    bodies = [function_source(text, name) for name in names]
    macros = "\n".join(re.findall(r"(?m)^#define SN201202X_POLL_[^\n]+$", text))
    if mutate:
        helper = bodies[1]
        changed = helper.replace("if (busy_seen) {", "if (true) {", 1)
        if changed == helper:
            changed = helper.replace("if (busy_seen)\n", "if (true)\n", 1)
        if changed == helper:
            raise AssertionError("freshness guard mutation target not found")
        bodies[1] = changed
    template = FIXTURE.read_text(encoding="utf-8")
    template = template.replace("/* ACTUAL_MACROS_BEGIN */\n/* ACTUAL_MACROS_END */", macros)
    return template.replace("/* ACTUAL_FUNCTIONS_BEGIN */\n/* ACTUAL_FUNCTIONS_END */",
                            "\n\n".join(bodies))


def compile_fixture(source: str, out: pathlib.Path, tag: str) -> pathlib.Path:
    c_file = out / f"{tag}.c"
    binary = out / tag
    c_file.write_text(source, encoding="utf-8")
    clang = shutil.which("clang")
    if not clang:
        raise AssertionError("clang is required for the host fixture")
    flags = [clang, "-std=c11", "-Wall", "-Wextra", "-Werror",
             "-Wno-unused-parameter", "-O0"]
    if tag == "mutant":
        flags.append("-Wno-unused-but-set-variable")
    if tag == "fixture" and subprocess.run([clang, "--version"], capture_output=True).returncode == 0:
        flags += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
    result = subprocess.run(flags + [str(c_file), "-o", str(binary)],
                            capture_output=True, text=True)
    if result.returncode:
        raise AssertionError(f"compile failed ({tag}):\n{result.stderr}")
    return binary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", type=pathlib.Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output-dir", type=pathlib.Path, required=True)
    parser.add_argument("--patch", type=pathlib.Path, default=DEFAULT_PATCH)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    run = pathlib.Path(tempfile.mkdtemp(prefix="select-polling-", dir=args.output_dir))
    spmi = isolated_driver(args.source_dir, args.patch, run)
    driver_text = spmi.read_text(encoding="utf-8")
    required_markers = (
        "sn201202x_validate_polling_irqs", "sn201202x_select_reg_poll",
        "SN201202X_POLL_TIMEOUT_US", "of_find_property", "poll_prop->length",
        "sn->experimental_polling", "of_irq_count",
        "if (!tps->irq || !irq_sleep || !irq_wake)",
        "if (experimental_polling)", "skip_select_irq",
    )
    missing = [marker for marker in required_markers if marker not in driver_text]
    if missing:
        raise AssertionError(f"driver contract markers missing: {missing}")
    binding_text = (run / "isolated-source" / SN_BINDING).read_text(encoding="utf-8")
    binding_markers = (
        "apple,experimental-select-polling", "allOf:",
        "- const: irq", "- const: sleep", "- const: wake", "- const: select",
    )
    missing = [marker for marker in binding_markers if marker not in binding_text]
    if missing:
        raise AssertionError(f"polling binding/parser markers missing: {missing}")
    original = render_fixture(spmi)
    binary = compile_fixture(original, run, "fixture")
    result = subprocess.run([str(binary)], capture_output=True, text=True)
    (run / "host.stdout").write_text(result.stdout, encoding="utf-8")
    (run / "host.stderr").write_text(result.stderr, encoding="utf-8")
    if result.returncode:
        raise AssertionError(f"host fixture failed ({result.returncode}); see {run}")

    stale_binary = compile_fixture(render_fixture(spmi, mutate=False), run, "stale")
    stale = subprocess.run([str(stale_binary), "stale-only"], capture_output=True, text=True)
    if stale.returncode:
        raise AssertionError(f"stale-ready control failed ({stale.returncode})")
    mutant = compile_fixture(render_fixture(spmi, mutate=True), run, "mutant")
    mutation = subprocess.run([str(mutant), "stale-only"], capture_output=True, text=True)
    (run / "mutation.stdout").write_text(mutation.stdout, encoding="utf-8")
    (run / "mutation.stderr").write_text(mutation.stderr, encoding="utf-8")
    if mutation.returncode != 1:
        raise AssertionError(f"freshness mutation exit was {mutation.returncode}, expected exact 1")
    if "expect_select(ready, 1, -ETIMEDOUT)" not in mutation.stderr:
        raise AssertionError("freshness mutation lacked designated stale-ready CHECK witness")
    receipt = (f"source={args.source_dir}\nsource_spmi_sha256={sha256(args.source_dir / SPMI)}\n"
               f"patched_spmi_sha256={sha256(spmi)}\nfixture_sha256={sha256(FIXTURE)}\n"
               f"patch_sha256={sha256(args.patch)}\nrun={run}\n"
               f"host_exit={result.returncode}\nmutation_exit={mutation.returncode}\n")
    (run / "receipt.txt").write_text(receipt, encoding="utf-8")
    print(f"PASS host_fixture=1 mutation_witness={mutation.returncode} run={run}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, subprocess.SubprocessError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
