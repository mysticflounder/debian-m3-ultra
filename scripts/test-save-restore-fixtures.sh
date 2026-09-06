#!/bin/bash
# No VM or disks opened: exercise QMP and serial evidence rejection paths.
set -euo pipefail
HERE="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
SAVE_RESTORE_SOURCE_ONLY=1 source "$HERE/scripts/save-restore-vm.sh"
QMP_LOG="$RUN_DIR/fixture.jsonl"
trap - EXIT INT TERM HUP
tests=0
expect_state() {
    local wanted=$1 data=$2 observed
    printf '%s\n' "$data" > "$QMP_LOG"
    observed="$(sr_job_state query snapshot snapshot-save 2>/dev/null)" || observed=REJECTED
    [ "$observed" = "$wanted" ] || { echo "wanted $wanted, got $observed" >&2; exit 1; }
    tests=$((tests+1))
}
expect_state concluded '{"id":"query","return":[{"id":"snapshot","type":"snapshot-save","status":"concluded"}]}'
expect_state running '{"id":"query","return":[{"id":"snapshot","type":"snapshot-save","status":"running"}]}'
expect_state REJECTED '{"id":"query","return":[{"id":"snapshot","type":"snapshot-save","status":"concluded","error":"disk full"}]}'
expect_state REJECTED '{"id":"query","return":[{"id":"snapshot","type":"snapshot-load","status":"concluded"}]}'
expect_state REJECTED '{"id":"query","return":[]}'
expect_state REJECTED '{"id":"query","error":{"class":"GenericError","desc":"failed"}}'
expect_state REJECTED '{"id":"query","return":[{"id":"snapshot","type":"snapshot-save","status":"concluded"},{"id":"snapshot","type":"snapshot-save","status":"concluded"}]}'
expect_state REJECTED $'{"id":"query","return":[]}\n{"id":"query","return":[]}'
expect_state REJECTED '{not JSON'
ready='M3_SR_READY token=trial-1 pid=91 boot=00112233-4455-6677-8899-aabbccddeeff cpus=1'
nonce=0123456789abcdef0123456789abcdef
pass="M3_SR_PASS nonce=$nonce ${ready#M3_SR_READY } ram=baseline disk=baseline timer=expired monotonic=progress"
sr_validate_pass "$ready" "$pass" "$nonce" 1
for bad in "${pass/pid=91/pid=92}" "${pass/disk=baseline/disk=mutated}" "${pass/ram=baseline/ram=mutated}" "${pass/nonce=$nonce/nonce=old}" "${pass/cpus=1/cpus=8}" "$pass extra"; do
    if sr_validate_pass "$ready" "$bad" "$nonce" 1; then echo "accepted invalid pass" >&2; exit 1; fi
    tests=$((tests+1))
done
# Exercise the real snapshot orchestration and response parser against a mock
# transport. Keep both jobs' replies in one log, as with a single QMP session.
(
    QMP_LOG="$RUN_DIR/snapshot-sequence.jsonl"
    requests="$RUN_DIR/snapshot-requests.jsonl"
    : > "$QMP_LOG"; : > "$requests"
    CONTROL_STEPS=2
    active_job=''; active_kind=''
    sr_request() {
        local command=$1 id=$2 arguments=${3:-'{}'} reply='{}'
        "$JQ" -cn --arg id "$id" --arg command "$command" --argjson arguments "$arguments" \
            '{id:$id,execute:$command,arguments:$arguments}' >> "$requests"
        case "$command" in
            snapshot-save|snapshot-load)
                active_kind="$command"
                active_job="$("$JQ" -r '.["job-id"]' <<< "$arguments")" ;;
            query-jobs)
                reply="$("$JQ" -cn --arg job "$active_job" --arg kind "$active_kind" \
                    '[{id:$job,type:$kind,status:"concluded"}]')" ;;
            job-dismiss)
                [ "$("$JQ" -r '.id' <<< "$arguments")" = "$active_job" ] || exit 1 ;;
            *) exit 1 ;;
        esac
        "$JQ" -cn --arg id "$id" --argjson reply "$reply" '{id:$id,return:$reply}' >> "$QMP_LOG"
        [ "$(qmp_success_count "$id")" = 1 ] || exit 1
    }
    sr_snapshot snapshot-save save-baseline
    sr_snapshot snapshot-load load-baseline
    "$JQ" -e -s '
      length == 6 and (map(.id) | unique | length) == 6 and
      map(.id) == ["save-baseline-start","save-baseline-query-0","save-baseline-dismiss",
                   "load-baseline-start","load-baseline-query-0","load-baseline-dismiss"] and
      ([.[] | select(.execute == "job-dismiss") | .arguments.id] == ["save-baseline","load-baseline"])
    ' "$requests" >/dev/null
)
tests=$((tests+1))
# A streamed PASS must not freeze the waiter at an unterminated EOF record.
(
    SERIAL_LOG="$RUN_DIR/streamed-marker.log"
    prefix='M3_SR_PASS nonce=fixture '
    marker="${prefix}ram=baseline disk=baseline"
    printf '%s' "$prefix" > "$SERIAL_LOG"
    [ -z "$(sr_complete_prefix_lines "$prefix")" ]
    printf '%s' 'ram=baseline disk=baseline' >> "$SERIAL_LOG"
    [ -z "$(sr_complete_prefix_lines "$prefix")" ]
    printf '\r\n' >> "$SERIAL_LOG"
    [ "$(sr_complete_prefix_lines "$prefix")" = "$marker" ]
    CONTROL_STEPS=1
    sr_wait_prefix "$prefix"
    [ "$SR_LINE" = "$marker" ]
    printf '%s\r\n' "$marker" >> "$SERIAL_LOG"
    [ "$(sr_complete_prefix_lines "$prefix")" = "$marker"$'\n'"$marker" ]
    if (sr_wait_prefix "$prefix") 2>/dev/null; then
        echo "accepted duplicate streamed marker" >&2; exit 1
    fi
    # An ANSI-adorned duplicate cannot bypass the original exact/raw checks.
    printf '%s\r\n\033[0m%s\r\n' "$marker" "$marker" > "$SERIAL_LOG"
    if (sr_wait_prefix "$prefix") 2>/dev/null; then
        echo "accepted ANSI-adorned duplicate" >&2; exit 1
    fi
)
tests=$((tests+4))
/bin/bash -n "$SR_HARNESS"
/bin/bash -n "$0"
echo "save/restore: $((tests+1)) protocol/evidence fixtures passed; Bash syntax passed; no VM launched"
echo "fixture artifacts: $RUN_DIR"
