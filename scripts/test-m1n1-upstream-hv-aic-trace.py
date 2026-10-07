#!/usr/bin/env python3
"""Source-extracted, host-only regression tests for hv_aic.c (full-tree input)."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "tests/m1n1-hv-aic-trace.c"
SAN_MARKERS = ("AddressSanitizer", "UndefinedBehaviorSanitizer", "runtime error:",
               "SUMMARY: AddressSanitizer", "SUMMARY: UndefinedBehaviorSanitizer")

def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()

def source_body(src: str) -> str:
    marker = "#define IRQTRACE_IRQ BIT(0)"
    pos = src.find(marker)
    if pos < 0:
        raise ValueError("hv_aic.c production marker missing")
    return src[pos:]

def hv_public_types(src: str) -> str:
    typedef = re.search(r"typedef bool\(hv_hook_t\)\(struct exc_info \*ctx, u64 addr, u64 \*val, bool write, int width\);", src)
    struct = re.search(r"struct hv_evt_irqtrace \{.*?\n\};", src, re.S)
    if not typedef or not struct:
        raise ValueError("production hv public trace types missing")
    return "struct exc_info;\n" + typedef.group(0) + "\n\n" + struct.group(0)

def extract_python_method(path: Path) -> str:
    lines = path.read_text().splitlines(True)
    for i, line in enumerate(lines):
        if re.match(r"^    def trace_irq\(self, device, num, count, flags\):\s*$", line):
            out = [line]
            for nxt in lines[i + 1:]:
                if nxt.startswith("    ") and not nxt.startswith("        "):
                    break
                if nxt and not nxt[0].isspace():
                    break
                out.append(nxt)
            return "".join(out)
    raise ValueError("production trace_irq method not found")

def run_python_proxy(src: Path, report: Path) -> dict:
    method = extract_python_method(src)
    method_source = src.read_text()
    c_source = (src.parents[3] / "src/aic_regs.h").read_text()
    hw_type = int(re.search(r"AIC_EVENT_TYPE_HW\s+(\d+)", c_source).group(1))
    py_type = int(re.search(r"AIC_EVT_TYPE_HW\s*=\s*(\d+)", method_source).group(1))
    if hw_type != py_type:
        raise RuntimeError("Python/C AIC event-type constants disagree")
    (report / "trace_irq.production.py").write_text(method)
    class _Mode: RESERVED = object()
    class P:
        def __init__(self, result): self.result, self.calls = result, []
        def hv_trace_irq(self, *args): self.calls.append(args); return self.result
    class O:
        AIC_EVT_TYPE_HW = 1
        IRQTRACE_IRQ = 1
        def __init__(self, result):
            self.p, self.interrupt_map = P(result), {}
            self.adt = {"/arm-io/aic": type("Node", (), {"get_reg": lambda self, _: (0x1000, 0x100)})()}
            self.mmio_maps, self.dirty_maps = {}, set()
        def add_tracer(self, *args, **kwargs): self.mmio_maps[args[:2]] = args[2:]
        def del_tracer(self, *args): self.mmio_maps.pop(args, None)
    results = []
    for optimize in (0, 1):
        ns: dict[str, object] = {"irange": lambda start, size: (start, size), "TraceMode": _Mode}
        exec(compile(textwrap.dedent(method), str(src), "exec", optimize=optimize), ns)
        fn = ns["trace_irq"]
        checks = []
        obj = O(1); fn(obj, "dev", 7, 1, 1)
        enabled_map = dict(obj.interrupt_map); enabled_tracers = dict(obj.mmio_maps)
        fn(obj, "dev", 7, 1, 0)
        checks.append(enabled_map.get(7) == "dev" and 7 not in obj.interrupt_map and enabled_tracers and not obj.mmio_maps)
        checks.append(obj.p.calls == [(py_type, 7, 1, 1), (py_type, 7, 1, 0)])
        for result in (0, -1):
            obj = O(result); obj.interrupt_map = {9: "existing"}; obj.mmio_maps = {((0x1000, 0x100), "AIC_IRQ"): "existing"}
            before_map, before_tracers = dict(obj.interrupt_map), dict(obj.mmio_maps)
            try:
                fn(obj, "dev", 7, 1, 1)
            except RuntimeError as exc:
                checks.append(str(exc) == "Failed to configure AIC IRQ tracing" and
                              obj.interrupt_map == before_map and obj.mmio_maps == before_tracers and
                              obj.p.calls == [(py_type, 7, 1, 1)])
            else:
                checks.append(False)
        passed = all(checks)
        (report / f"python-regression-opt{optimize}.log").write_text(
            f"enable/disable map+tracer and 0/-1 reject-no-mutation (optimize={optimize}): {passed}\n")
        if not passed:
            raise RuntimeError(f"proxy trace_irq regression failed at optimize={optimize}")
        results.append({"optimize": optimize, "checks": len(checks), "passed": passed})
    return {"source": str(src.relative_to(ROOT)), "sha256": sha(src), "modes": results, "aic_evt_type_hw": py_type}

def compile_run(source: Path, out: Path, include: Path, report: Path, label: str) -> dict:
    cmd = ["clang", "-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
           "-fsanitize=address,undefined", "-fno-sanitize-recover=all", "-fno-omit-frame-pointer",
           f"-I{include}", str(source), "-o", str(out)]
    env = os.environ.copy(); env.update(ASAN_OPTIONS="detect_leaks=0", UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1")
    cp = subprocess.run(cmd, text=True, capture_output=True, env=env)
    (report / f"{label}.compile.stdout").write_text(cp.stdout)
    (report / f"{label}.compile.stderr").write_text(cp.stderr)
    if cp.returncode:
        raise RuntimeError(f"{label} compile failed ({cp.returncode})")
    rp = subprocess.run([str(out)], text=True, capture_output=True, env=env)
    (report / f"{label}.run.stdout").write_text(rp.stdout)
    (report / f"{label}.run.stderr").write_text(rp.stderr)
    combined = rp.stdout + rp.stderr
    if rp.returncode or any(m in combined for m in SAN_MARKERS):
        raise RuntimeError(f"{label} runtime failed or sanitizer masked it")
    return {"argv": cmd, "compile_exit": cp.returncode, "run_exit": rp.returncode,
            "source_sha256": sha(source), "binary_sha256": sha(out)}

def main() -> int:
    ap = argparse.ArgumentParser(); ap.add_argument("--source-tree", type=Path, required=True)
    args = ap.parse_args(); tree = args.source_tree.resolve(); hv = tree / "src/hv/hv_aic.c"
    if not hv.is_file(): raise SystemExit(f"missing source tree input: {hv}")
    report = ROOT / "scratch/hv-aic-trace-tests" / ("run-" + hashlib.sha256(os.urandom(16)).hexdigest()[:12])
    host, prod = report / "host-include", report / "production-headers"; host.mkdir(parents=True); prod.mkdir()
    headers = ["types.h", "aic.h", "aic_regs.h", "exception.h", "utils.h", "uartproxy.h"]
    for name in headers:
        p = tree / "src" / name; data = p.read_text(); (prod / name).write_text(data)
        if name == "types.h":
            data = re.sub(r"^typedef u64 uintptr_t;\n^typedef s64 ptrdiff_t;\n\ntypedef s64 ssize_t;\n", "", data, flags=re.M)
        (host / name).write_text(data)
    constants = re.search(r"EVT_IRQTRACE\s*=\s*(\d+)", (tree / "src/uartproxy.h").read_text()).group(1)
    body = source_body(hv.read_text())
    hv_header = tree / "src/hv/hv.h"
    (prod / "hv.h").write_text(hv_header.read_text())
    public_types = hv_public_types(hv_header.read_text())
    generated = report / "startup.c"
    c = TEMPLATE.read_text().replace("/* INSERT_PRODUCTION_CONSTANTS */", f"#define EVT_IRQTRACE {constants}\n#define dprintf(...) debug_printf(__VA_ARGS__)")
    c = c.replace("/* INSERT_PRODUCTION_HV_TYPES */", public_types)
    c = c.replace("/* INSERT_HV_AIC_SOURCE */", body)
    generated.write_text(c)
    (report / "hv_aic.production.c").write_text(hv.read_text())
    if (report / "hv_aic.production.c").read_bytes() != hv.read_bytes():
        raise RuntimeError("production hv_aic snapshot changed")
    py = tree / "proxyclient/m1n1/hv/__init__.py"
    manifest = {"source_tree": str(tree), "production": {}, "tests": {}, "python": run_python_proxy(py, report)}
    for p in [hv, hv_header, *(tree / "src" / n for n in headers), TEMPLATE, py]:
        rel = str(p.relative_to(tree) if p.is_relative_to(tree) else p)
        manifest["production"][rel] = sha(p)
    for name in headers + ["hv.h"]:
        original = hv_header if name == "hv.h" else tree / "src" / name
        if (prod / name).read_bytes() != original.read_bytes():
            raise RuntimeError(f"production header snapshot changed: {name}")
    patch_manifest = tree.parent / "PATCH_SHA256SUMS"
    if patch_manifest.is_file():
        shutil.copy2(patch_manifest, report / "PATCH_SHA256SUMS")
        manifest["patch_order_hashes"] = patch_manifest.read_text().splitlines()
    manifest["tests"]["normal"] = compile_run(generated, report / "hv-aic-trace", host, report, "normal")
    # Exact designated controls: each defect must be caught by a named assertion, not ASan.
    controls = [
        ("wrong-die-bound", "die >= aic->nr_die || num >= aic->nr_irq || count > aic->nr_irq - num", "die >= aic->max_irq || num >= aic->nr_irq || count > aic->nr_irq - num", "invalid global IRQ start was accepted"),
        ("map-failure-ignored", "if (hv_map_hook(aic->base, trace_aic_event, aic->regs.reg_size) < 0)", "if (hv_map_hook(aic->base, trace_aic_event, aic->regs.reg_size) < 0 && false)", "failed hv_map_hook mutated trace state"),
        ("event-die-bound", "die >= AIC_MAX_DIES || die >= aic->nr_die || num >= AIC_MAX_HW_NUM", "die >= AIC_MAX_DIES || num >= AIC_MAX_HW_NUM", "invalid event geometry emitted an event"),
    ]
    for label, old, new, witness in controls:
        mutated = body.replace(old, new, 1)
        if mutated == body: raise RuntimeError(f"mutation did not apply: {label}")
        msrc = report / f"{label}.c"; msrc.write_text(TEMPLATE.read_text().replace("/* INSERT_PRODUCTION_CONSTANTS */", f"#define EVT_IRQTRACE {constants}\n#define dprintf(...) debug_printf(__VA_ARGS__)").replace("/* INSERT_PRODUCTION_HV_TYPES */", public_types).replace("/* INSERT_HV_AIC_SOURCE */", mutated))
        exe = report / f"{label}.bin"; cmd = ["clang", "-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined", "-fno-sanitize-recover=all", f"-I{host}", str(msrc), "-o", str(exe)]
        cp = subprocess.run(cmd, text=True, capture_output=True); (report / f"{label}.compile.stderr").write_text(cp.stderr)
        (report / f"{label}.compile.stdout").write_text(cp.stdout)
        rp = subprocess.run([str(exe)], text=True, capture_output=True, env=os.environ | {"ASAN_OPTIONS":"detect_leaks=0", "UBSAN_OPTIONS":"halt_on_error=1"}) if cp.returncode == 0 else None
        stderr = rp.stderr if rp else ""
        (report / f"{label}.run.stdout").write_text(rp.stdout if rp else "")
        (report / f"{label}.run.stderr").write_text(stderr)
        exact_line = f"FAIL: {witness}"
        if (not rp or rp.returncode != 1 or exact_line not in stderr.splitlines() or
                any(m in stderr for m in SAN_MARKERS)):
            raise RuntimeError(f"negative control lacked exact witness: {label}")
        manifest["tests"][label] = {"argv": cmd, "compile_exit": cp.returncode, "run_exit": rp.returncode, "expected_stderr": exact_line, "source_sha256": sha(msrc), "binary_sha256": sha(exe)}
    (report / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"report": str(report), "normal": manifest["tests"]["normal"]["run_exit"], "negative_controls": len(controls)}))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
