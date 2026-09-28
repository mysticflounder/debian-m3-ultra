#!/usr/bin/env python3
"""Host/source regression for the promoted 0016 SMP-shared runtime guard."""
from __future__ import annotations

import importlib.util
import pathlib
import re
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "tests/m1n1-smp-shared-guard.c"
CLANG = shutil.which("clang")


def fail(message: str) -> None:
    raise RuntimeError(message)


def run(command: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=False)


def load_shared():
    spec = importlib.util.spec_from_file_location("smp_shared_base", ROOT / "scripts/test-m1n1-smp-shared.py")
    if spec is None or spec.loader is None:
        fail("unable to load shared materializer")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def extract_function(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        fail(f"missing function: {signature}")
    brace = source.find("{", start)
    if brace < 0:
        fail(f"missing body: {signature}")
    depth = 0
    quote = None
    escaped = line = block = False
    for index in range(brace, len(source)):
        char = source[index]
        nxt = source[index + 1] if index + 1 < len(source) else ""
        if line:
            if char == "\n": line = False
        elif block:
            if char == "*" and nxt == "/": block = False
        elif quote:
            if escaped: escaped = False
            elif char == "\\": escaped = True
            elif char == quote: quote = None
        elif char in "\"'": quote = char
        elif char == "/" and nxt == "/": line = True
        elif char == "/" and nxt == "*": block = True
        elif char == "{": depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0: return source[start:index + 1]
    fail(f"unterminated function: {signature}")


def extract_define(source: str, name: str) -> str:
    match = re.search(rf"^#define\s+{re.escape(name)}(?:\s|$).*?$", source, re.MULTILINE)
    if match is None:
        fail(f"missing define: {name}")
    return match.group(0)


def function_signature(source: str, name: str) -> str:
    match = re.search(rf"(?:^|\n)((?:static\s+)?[A-Za-z_][\w\s\*]*\b{re.escape(name)}\s*\([^;{{]*\))\s*\{{",
                      source)
    if match is None:
        fail(f"missing function signature: {name}")
    return match.group(1)


def source_parts(memory: str, memory_h: str) -> tuple[str, str, str]:
    explicit = [
        "mmu_init_pagetables", "mmu_remap_smp_shared", "mmu_smp_start_allowed", "mmu_add_mapping",
        "mmu_rm_mapping", "mmu_map_framebuffer",
    ]
    helpers = sorted(set(re.findall(
        r"(?:static\s+)?[A-Za-z_]\w*\s+(mmu_\w*(?:smp_shared|start_allowed)\w*)\s*\(",
        memory)))
    names = list(dict.fromkeys(helpers + explicit))
    names.sort(key=memory.find)
    functions = []
    for name in names:
        if re.search(rf"\b{re.escape(name)}\s*\(", memory):
            signature = function_signature(memory, name)
            functions.append(extract_function(memory, signature))
    required = ("mmu_init_pagetables", "mmu_remap_smp_shared", "mmu_smp_start_allowed", "mmu_add_mapping",
                "mmu_rm_mapping", "mmu_map_framebuffer")
    if any(not any(re.search(rf"\b{re.escape(name)}\s*\(", fn) for fn in functions)
           for name in required):
        fail("0016 guard API is incomplete")
    ready = re.search(r"^static bool\s+(\w*shared\w*ready\w*)\s*;", memory, re.MULTILINE)
    if ready is None:
        fail("shared-ready lifecycle flag missing")
    ready_decl = ready.group(0)
    define_names = (
        "PTE_ACCESS", "PTE_VALID", "PTE_AP_RO", "PTE_AP_EL0", "PTE_PXN", "PTE_UXN",
        "PTE_SH_OS", "REGION_RWX_EL0", "REGION_RW_EL0", "REGION_RX_EL1", "PERM_RW",
        "PERM_RW_EL0", "MAIR_IDX_NORMAL", "MAIR_IDX_NORMAL_NC", "MAIR_IDX_DEVICE_nGnRnE",
    )
    defines = "\n".join(extract_define(memory_h, name) for name in define_names)
    return ready_decl, defines, "\n\n".join(functions)


def audit_order(memory: str, smp: str) -> None:
    ready_match = re.search(r"^static bool\s+(\w*shared\w*ready\w*)\s*;", memory, re.MULTILINE)
    if ready_match is None:
        fail("shared-ready lifecycle flag missing")
    ready_name = ready_match.group(1)
    init_pt = extract_function(memory, function_signature(memory, "mmu_init_pagetables"))
    if f"{ready_name} = false;" not in init_pt:
        fail("MMU page-table rebuild does not reset shared-ready state")
    remap = extract_function(memory, function_signature(memory, "mmu_remap_smp_shared"))
    ready_pos = remap.find(f"{ready_name} = true;")
    maps = [m.start() for m in re.finditer(r"mmu_add_mapping\s*\(", remap)]
    if ready_pos < 0 or not maps or ready_pos < max(maps):
        fail("shared-ready state is published before all four remaps")
    for name in ("mmu_add_mapping", "mmu_rm_mapping", "mmu_map_framebuffer"):
        body = extract_function(memory, function_signature(memory, name))
        side_effect = body.find("mmu_map(") if name != "mmu_map_framebuffer" else body.find("dc_civac_range(")
        guard = min((p for p in (body.find("mmu_smp_shared"), body.find("mmu_smp_shared_allowed")) if p >= 0),
                    default=-1)
        if guard < 0 or side_effect < 0 or guard > side_effect:
            fail(f"{name} guard is not before its side effects")
    start = extract_function(smp, function_signature(smp, "smp_start_secondaries"))
    if start.find("mmu_smp_start_allowed") < 0 or start.find("mmu_smp_start_allowed") > start.find("int pmgr_path"):
        fail("SMP top-level start gate is not first")
    leaf = extract_function(smp, function_signature(smp, "smp_start_cpu"))
    if leaf.find("mmu_smp_start_allowed") < 0 or leaf.find("mmu_smp_start_allowed") > leaf.find("if (index"):
        fail("SMP CPU-leaf start gate is not before allocation/MMIO checks")


def make_adapter(ready_name: str) -> str:
    base = "(u64)(uintptr_t)_smp_shared_start"
    size = "(size_t)(_smp_shared_end - _smp_shared_start)"
    return f'''\nextern u8 _smp_shared_start[], _smp_shared_end[];
static void set_ready(bool value) {{ {ready_name} = value; }}
static u64 dynamic_from, dynamic_to, dynamic_size, dynamic_perms;
static u8 dynamic_attr;
static void op_dynamic_map(void) {{ mmu_add_mapping(dynamic_from, dynamic_to, dynamic_size, dynamic_attr, dynamic_perms); }}
static void op_dynamic_remove(void) {{ mmu_rm_mapping(dynamic_from, dynamic_size); }}
static void op_remap(void) {{ mmu_remap_smp_shared(); }}
static void op_fifth_alias(void) {{ mmu_add_mapping({base} | BIT(44), {base}, {size}, MAIR_IDX_DEVICE_nGnRnE, PERM_RW_EL0); }}
static void op_wrong_attr(void) {{ mmu_add_mapping({base}, {base}, {size}, MAIR_IDX_NORMAL, PERM_RW); }}
static void op_wrong_perm(void) {{ mmu_add_mapping({base}, {base}, {size}, MAIR_IDX_DEVICE_nGnRnE, PERM_RW | PTE_ACCESS); }}
static void op_raw_pte(void) {{ mmu_add_mapping({base}, {base}, {size}, MAIR_IDX_DEVICE_nGnRnE, PERM_RW | PTE_VALID); }}
static void op_attr8(void) {{ mmu_add_mapping({base}, {base}, {size}, 8, PERM_RW); }}
static void op_remove(void) {{ mmu_rm_mapping({base}, {size}); }}
static void op_framebuffer(void) {{ mmu_map_framebuffer({base}, {size}); }}
static void op_overflow(void) {{ mmu_add_mapping(~0ULL - 0x100, {base}, 0x200, MAIR_IDX_DEVICE_nGnRnE, PERM_RW); }}
static void op_raw_target_bits(void) {{ mmu_add_mapping({base} | 0x100000, {base} | PTE_UXN, {size}, MAIR_IDX_DEVICE_nGnRnE, PERM_RW); }}
static void op_raw_perms_pa(void) {{ mmu_add_mapping({base} | 0x200000, 0, {size}, MAIR_IDX_DEVICE_nGnRnE, PERM_RW | {base}); }}
static void op_noncanonical_va(void) {{ mmu_add_mapping({base} | (1ULL << 48), {base}, {size}, MAIR_IDX_DEVICE_nGnRnE, PERM_RW); }}
static void op_remove_noncanonical(void) {{ mmu_rm_mapping({base} | (1ULL << 48), {size}); }}
static void op_mirror_wrong_attr(void) {{ mmu_add_mapping((~0x0000ffffffffffffULL) | {base}, {base}, {size}, MAIR_IDX_NORMAL, PERM_RW); }}
static void op_remove_mirror(void) {{ mmu_rm_mapping((~0x0000ffffffffffffULL) | {base}, {size}); }}
static void op_high_legacy_reject(void) {{ mmu_add_mapping(0xffff000000200000ULL, 0x200000, 0x1000, MAIR_IDX_NORMAL, PERM_RW); }}
static bool expect_remap_failure(unsigned nth)
{{
    set_ready(false); fail_map_call = nth; map_effects = 0; panic_count = 0;
    catch_panic = true;
    if (setjmp(panic_env) == 0)
        mmu_remap_smp_shared();
    catch_panic = false; fail_map_call = 0;
    return panic_count == 1 && map_effects == nth && !{ready_name};
}}
static int test_guard_matrix(void)
{{
    u64 base = {base}; size_t size = {size};
    CHECK(base % 0x1000 == 0 && base % 0x4000 == 0 && size == 0x10000);
    CHECK((base | BIT(44)) != base);

    /* Exercise the real rebuild/remap lifecycle, including every map fault point. */
    set_ready(true); alloc_effects = 0; mmu_init_pagetables();
    CHECK(!{ready_name} && alloc_effects == 1);
    for (unsigned nth = 1; nth <= 4; nth++) {{
        mmu_init_pagetables(); CHECK(!{ready_name});
        CHECK(expect_remap_failure(nth));
        CHECK(!{ready_name});
    }}
    mmu_init_pagetables(); map_effects = 0; fail_map_call = 0;
    mmu_remap_smp_shared(); CHECK({ready_name} && map_effects == 4);
    mmu_init_pagetables(); CHECK(!{ready_name});

    map_effects = remove_effects = cache_effects = barrier_effects = panic_count = 0;
    set_ready(false); mock_mmu_active = true;
    CHECK(mmu_smp_start_allowed() == false);
    mmu_add_mapping(0x1000, 0x1000, 0x1000, MAIR_IDX_NORMAL, PERM_RW);
    CHECK(map_effects == 1);
    mock_mmu_active = false; CHECK(mmu_smp_start_allowed() == true);
    set_ready(true); mock_mmu_active = true; CHECK(mmu_smp_start_allowed() == true);

    for (unsigned granule_i = 0; granule_i < 2; granule_i++) {{
        u64 granule = granule_i ? 0x4000 : 0x1000;
        u64 aliases[] = {{0, REGION_RWX_EL0, REGION_RW_EL0, REGION_RX_EL1}};
        u64 alias_perms[] = {{PERM_RW, PERM_RW_EL0, PERM_RW_EL0, PERM_RW_EL0}};
        mock_page_size = granule;
        map_effects = remove_effects = cache_effects = barrier_effects = panic_count = 0;
        set_ready(true);
        mmu_add_mapping(granule, granule, granule, MAIR_IDX_NORMAL, PERM_RW);
        CHECK(map_effects == 1);
        for (unsigned i = 0; i < ARRAY_SIZE(aliases); i++)
            mmu_add_mapping(base | aliases[i], base, size, MAIR_IDX_DEVICE_nGnRnE, alias_perms[i]);
        CHECK(map_effects == 5);
        for (unsigned i = 0; i < ARRAY_SIZE(aliases); i++)
            mmu_add_mapping(base | aliases[i], base, size, MAIR_IDX_DEVICE_nGnRnE, alias_perms[i]);
        CHECK(map_effects == 9);

        for (unsigned i = 0; i < ARRAY_SIZE(aliases); i++) {{
            u64 alias = base | aliases[i];
            dynamic_attr = MAIR_IDX_DEVICE_nGnRnE; dynamic_perms = alias_perms[i];
            dynamic_from = alias + granule; dynamic_to = base + granule;
            dynamic_size = size - 2 * granule;
            mmu_add_mapping(dynamic_from, dynamic_to, dynamic_size, dynamic_attr, dynamic_perms);
            dynamic_from = alias - granule; dynamic_to = base - granule; dynamic_size = granule;
            dynamic_attr = MAIR_IDX_NORMAL; dynamic_perms = PERM_RW;
            mmu_add_mapping(dynamic_from, dynamic_to, dynamic_size, dynamic_attr, dynamic_perms);
            dynamic_from = alias + size; dynamic_to = base + size;
            mmu_add_mapping(dynamic_from, dynamic_to, dynamic_size, dynamic_attr, dynamic_perms);
            dynamic_from = alias + granule; dynamic_to = base + granule;
            dynamic_size = size; dynamic_attr = MAIR_IDX_DEVICE_nGnRnE; dynamic_perms = alias_perms[i];
            panic_count = 0; CHECK(expect_panic(op_dynamic_map));
            dynamic_from = alias; dynamic_to = base + granule; dynamic_size = size;
            panic_count = 0; CHECK(expect_panic(op_dynamic_map));
            dynamic_from = alias + 1; dynamic_to = base + 1; dynamic_size = granule;
            panic_count = 0; CHECK(expect_panic(op_dynamic_map));
            dynamic_from = alias; dynamic_to = base; dynamic_size = granule + 1;
            panic_count = 0; CHECK(expect_panic(op_dynamic_map));
            dynamic_from = alias + granule; dynamic_size = size - 2 * granule;
            panic_count = 0; CHECK(expect_panic(op_dynamic_remove));
            dynamic_from = alias; dynamic_size = size;
            panic_count = 0; CHECK(expect_panic(op_dynamic_remove));
            dynamic_from = alias - granule; dynamic_size = granule;
            mmu_rm_mapping(dynamic_from, dynamic_size);
        }}
        CHECK(cache_effects == 0);
        panic_count = 0; CHECK(expect_panic(op_fifth_alias));
        panic_count = 0; CHECK(expect_panic(op_wrong_attr));
        panic_count = 0; CHECK(expect_panic(op_wrong_perm));
        panic_count = 0; CHECK(expect_panic(op_raw_pte));
        panic_count = 0; CHECK(expect_panic(op_attr8));
        panic_count = 0; CHECK(expect_panic(op_remove));
        panic_count = 0; CHECK(expect_panic(op_framebuffer));
        dynamic_from = base; dynamic_to = base; dynamic_size = 0;
        mmu_add_mapping(base, base, 0, MAIR_IDX_DEVICE_nGnRnE, PERM_RW);
        panic_count = 0; CHECK(expect_panic(op_overflow));
        panic_count = 0; CHECK(expect_panic(op_raw_target_bits));
        panic_count = 0; CHECK(expect_panic(op_raw_perms_pa));
        panic_count = 0; CHECK(expect_panic(op_noncanonical_va));
        panic_count = 0; CHECK(expect_panic(op_remove_noncanonical));
        panic_count = 0; CHECK(expect_panic(op_mirror_wrong_attr));
        panic_count = 0; CHECK(expect_panic(op_remove_mirror));
        panic_count = 0; CHECK(expect_panic(op_high_legacy_reject));
        mmu_add_mapping((1ULL << 48) - granule, 0x200000, granule,
                        MAIR_IDX_NORMAL, PERM_RW);
    }}
    CHECK(cache_effects == 0);
    return 0;
}}
'''


def main() -> int:
    if CLANG is None:
        fail("clang is required")
    shared = load_shared()
    with tempfile.TemporaryDirectory(dir=ROOT / "scratch") as name:
        directory = pathlib.Path(name)
        tree = shared.materialize_experiment(directory)
        memory = (tree / "src/memory.c").read_text()
        memory_h = (tree / "src/memory.h").read_text()
        smp = (tree / "src/smp.c").read_text()
        ready_decl, defines, functions = source_parts(memory, memory_h)
        audit_order(memory, smp)
        source = TEMPLATE.read_text()
        source = source.replace("/* INSERT_MEMORY_DEFINES */", defines)
        source = source.replace("/* INSERT_GUARD_SOURCE */", ready_decl + "\n\n" + functions)
        source = source.replace("/* INSERT_TEST_ADAPTERS */", make_adapter(
            re.search(r"static bool\s+(\w*shared\w*ready\w*)", ready_decl).group(1)))
        generated = directory / "smp-shared-guard.c"
        binary = directory / "smp-shared-guard"
        generated.write_text(source)
        result = run([CLANG, "-std=c11", "-O1", "-g", "-fsanitize=address,undefined",
                      "-fno-sanitize-recover=all", str(generated), "-o", str(binary)], ROOT)
        if result.returncode:
            fail(f"clang failed:\n{result.stdout}{result.stderr}")
        result = run([str(binary)], ROOT)
        if result.returncode:
            fail(f"guard harness failed (exit {result.returncode}):\n{result.stdout}{result.stderr}")
        print(result.stdout.strip())
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"m1n1 SMP-shared guard: ERROR: {error}")
        raise SystemExit(1)
