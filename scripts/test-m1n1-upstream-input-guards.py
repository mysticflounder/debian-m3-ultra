#!/usr/bin/env python3
"""Reuse the complete AIC/ADT host regressions on reviewed upstream source.

Only source/archive identities and the AIC patch context are changed. The
existing materializers, assertions and negative controls run unchanged.
Nothing connects to hardware or a VM.
"""

from __future__ import annotations

import importlib.util
import pathlib


ROOT = pathlib.Path(__file__).resolve().parents[1]
REV = "2460b604c6f016956ead711823605eea840c602e"
PINNED = ROOT / f"scratch/m1n1-upstream-audit/m1n1-{REV}"
ARCHIVE = ROOT / f"scratch/m1n1-upstream-audit/source-{REV}.tar.gz"
ARCHIVE_SHA256 = "aa0ffbeb7ae9cc0eb7a5653f44474e26f826809cf7f0564f8deb395d25203b01"
ADT_SHA256 = "5e40126dddc35bbbf5b5715f29dcb42de2a0207ca64cbadc0a936abb09724184"
AIC_SHA256 = "9f55456f1d2fb0adae555a3a6ef4af7794b07c1b9af3106a430223025f57cbcf"
AIC_PATCH = ROOT / "patches/m1n1/upstream-2460b60/0019-validate-aic-init-metadata.patch"


def main() -> int:
    cases = (
        ("test-m1n1-adt-view.py", "rust/src/adt.rs", ADT_SHA256),
        ("test-m1n1-adt-copy.py", "rust/src/adt.rs", ADT_SHA256),
        ("test-m1n1-aic-init.py", "src/aic.c", AIC_SHA256),
    )
    for index, (script, source, source_hash) in enumerate(cases):
        spec = importlib.util.spec_from_file_location(f"upstream_guard_{index}", ROOT / "scripts" / script)
        if spec is None or spec.loader is None:
            raise RuntimeError(f"cannot load regression runner: {script}")
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        runner.PINNED = PINNED
        runner.ARCHIVE = ARCHIVE
        runner.ARCHIVE_SHA256 = ARCHIVE_SHA256
        runner.SOURCE = PINNED / source
        runner.SOURCE_SHA256 = source_hash
        if script == "test-m1n1-aic-init.py":
            runner.PATCH = AIC_PATCH
        print(f"Reviewed upstream {REV}: {script}", flush=True)
        result = runner.main()
        if result != 0:
            raise RuntimeError(f"{script}: nonzero result {result}")
    print("Reviewed upstream input guards: all three regression runners passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
