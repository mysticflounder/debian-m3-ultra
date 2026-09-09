#!/bin/bash
# No-VM fixtures for hvf-new-id-probe.c.  All VM/vCPU lifecycle and runtime
# register calls are mocked; only the real vCPU configuration API is linked.
set -euo pipefail
umask 077

HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
/bin/mkdir -p "$HERE/scratch"
fixture_dir="$(/usr/bin/mktemp -d "$HERE/scratch/hvf-new-id-probe.XXXXXX")"
probe_obj="$fixture_dir/hvf-new-id-probe.o"
probe_bin="$fixture_dir/hvf-new-id-probe-fixture"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
COMMON=(-isysroot "$SDK" -I"$SDK/System/Library/Frameworks/Hypervisor.framework/Headers" -Wall -Wextra -Werror -std=c11)

clang "${COMMON[@]}" \
    -Dmain=hvf_new_id_probe_main \
    -Dhv_vm_create=mock_hv_vm_create \
    -Dhv_vm_destroy=mock_hv_vm_destroy \
    -Dhv_vcpu_create=mock_hv_vcpu_create \
    -Dhv_vcpu_destroy=mock_hv_vcpu_destroy \
    -Dhv_vcpu_get_sys_reg=mock_hv_vcpu_get_sys_reg \
    -c "$HERE/scripts/hvf-new-id-probe.c" -o "$probe_obj"
clang "${COMMON[@]}" "$probe_obj" "$HERE/scripts/hvf-new-id-probe-fixture.c" \
    -F"$SDK/System/Library/Frameworks" -framework Hypervisor -o "$probe_bin"

JQ=/usr/bin/jq
tests=0
run_case() {
    local name=$1 expected=$2 filter=$3 output="$fixture_dir/$1.json" status
    set +e
    HVF_FIXTURE_MODE="$name" "$probe_bin" >"$output" 2>"$output.stderr"
    status=$?
    set -e
    [ "$status" -eq "$expected" ] || {
        echo "unexpected exit for $name: got $status expected $expected" >&2
        return 1
    }
    "$JQ" -e "$filter" "$output" >/dev/null || {
        echo "fixture assertion failed: $name" >&2
        return 1
    }
    tests=$((tests + 1))
}

run_case control 0 '
  .controls_ok == true and .cleanup_ok == true and
  .lifecycle.vm_create.status == "ok" and
  .lifecycle.vcpu_create.status == "ok" and
  .lifecycle.vcpu_destroy.status == "ok" and
  .lifecycle.vm_destroy.status == "ok" and
  ([.registers[] | select(.named_in_sdk == false)] | length) == 4 and
  all(.registers[] | select(.named_in_sdk == false);
      .vcpu.status == "api_rejected" and .vcpu.value == null)'

run_case target-zero 0 '
  .controls_ok == true and .cleanup_ok == true and
  ([.registers[] | select(.name == "ID_AA64PFR2_EL1")][0].vcpu |
    .status == "ok" and .value == "0x0000000000000000")'

run_case control-failure 1 '
  .controls_ok == false and .cleanup_ok == true and
  ([.registers[] | select(.name == "ID_AA64PFR0_EL1")][0].vcpu |
    .status == "error" and .value == null)'

run_case vcpu-create-failure 1 '
  .controls_ok == false and .cleanup_ok == false and
  .lifecycle.vcpu_create.status == "error" and
  .lifecycle.vcpu_destroy.status == "not_attempted" and
  .lifecycle.vm_destroy.status == "ok" and
  all(.registers[]; .vcpu.status == "not_attempted" and .vcpu.value == null)'

run_case destroy-failure 1 '
  .controls_ok == true and .cleanup_ok == false and
  .lifecycle.vcpu_destroy.status == "error" and
  .lifecycle.vm_destroy.status == "ok"'

/bin/bash -n "$HERE/scripts/test-hvf-new-id-probe.sh"
echo "HVF newer-ID probe fixtures passed: $tests no-VM mock cases"
echo "fixture artifacts: $fixture_dir"
