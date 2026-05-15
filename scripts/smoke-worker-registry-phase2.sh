#!/usr/bin/env bash
# scripts/smoke-worker-registry-phase2.sh
#
# Phase 2 smoke for worker-registry (S5~S9).
#
# 결정문: docs/decisions/2026-05-12-worker-registry-phase2.md v0.5 D4/D5

set -uo pipefail
# lib 가 set -euo pipefail 로 로드되므로 source 후 set -e 끄기 필요.
# Phase 2 smoke 는 의도적으로 비 0 return (registry_worker_exists rc=1) 검증.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/worker-registry-lib.sh"
COLLECTOR="${SCRIPT_DIR}/result-collector.sh"

[[ -f "${LIB}" ]] || { echo "smoke: worker-registry-lib.sh missing" >&2; exit 2; }
[[ -f "${COLLECTOR}" ]] || { echo "smoke: result-collector.sh missing" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "smoke: jq required" >&2; exit 2; }

source "${LIB}"
# lib 가 set -euo pipefail 을 적용. smoke 는 의도적으로 비 0 return 을 검증하므로 set -e 제거.
set +e

PASS=0
FAIL=0
WHICH="${1:-all}"

_pass() { echo "  PASS: $*"; PASS=$(( PASS + 1 )); }
_fail() { echo "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }
_mktmp() { mktemp -d -t reg-phase2.XXXXXX; }

_register_worker() {
  local pr="$1" sid="$2" worker="$3" runner="$4" rh="$5"
  registry_init "${pr}"
  local wid="wkr-${sid}-${worker}"
  local wt="${pr}/.company-runtime/sessions/${sid}/workers/${worker}"
  mkdir -p "${wt}"
  local payload
  payload="$(jq -S -c -n --arg rh "${rh}" --arg wt "${wt}" --arg topic "${worker}" --arg role "primary" --arg sid "${sid}" \
    '{runner_handle:$rh, worktree_path:$wt, branch:null, topic:$topic, worker_role:$role, session_id:$sid}')"
  registry_append_event "${pr}" spawn_started "${wid}" "${runner}" "${payload}" >/dev/null
  registry_append_event "${pr}" spawn_ready "${wid}" "${runner}" \
    "$(jq -S -c -n --arg rh "${rh}" '{runner_handle:$rh}')" >/dev/null
  echo "${wt}"
}

s5_multi_runner_record() {
  echo "=== S5: tmux/manual runner registry 기록 ==="
  local tmp; tmp="$(_mktmp)"
  _register_worker "${tmp}" "s5" "fe" tmux "feature-x:0.0" >/dev/null
  _register_worker "${tmp}" "s5" "be" manual "marker:${tmp}/marker.txt" >/dev/null
  local snap; snap="$(registry_get_snapshot "${tmp}")"
  local state_fe runner_fe state_be runner_be
  state_fe="$(echo "${snap}" | jq -r '.workers["wkr-s5-fe"].state')"
  runner_fe="$(echo "${snap}" | jq -r '.workers["wkr-s5-fe"].runner')"
  state_be="$(echo "${snap}" | jq -r '.workers["wkr-s5-be"].state')"
  runner_be="$(echo "${snap}" | jq -r '.workers["wkr-s5-be"].runner')"
  [[ "${state_fe}" == "running" && "${runner_fe}" == "tmux" ]] && _pass "tmux record" || _fail "tmux state=${state_fe} runner=${runner_fe}"
  [[ "${state_be}" == "running" && "${runner_be}" == "manual" ]] && _pass "manual record" || _fail "manual state=${state_be} runner=${runner_be}"
  rm -rf "${tmp}"
}

s6_cmux_pre_post_failure() {
  echo "=== S6: cmux pre-spawn vs post-spawn failure ==="
  local tmp; tmp="$(_mktmp)"
  registry_init "${tmp}"
  registry_worker_exists "${tmp}" "wkr-s6-pre"; local rc_pre=$?
  [[ "${rc_pre}" -eq 1 ]] && _pass "pre-spawn rc=1" || _fail "pre rc=${rc_pre}"
  local keys; keys="$(registry_get_snapshot "${tmp}" | jq '.workers | keys | length')"
  [[ "${keys}" -eq 0 ]] && _pass "pre-spawn 후 snapshot 변경 0" || _fail "keys=${keys}"
  _register_worker "${tmp}" "s6" "post" cmux "surface:abc" >/dev/null
  registry_worker_exists "${tmp}" "wkr-s6-post"; local rc_post=$?
  [[ "${rc_post}" -eq 0 ]] && _pass "post-spawn rc=0" || _fail "post rc=${rc_post}"
  registry_append_event "${tmp}" crash_detected "wkr-s6-post" cmux \
    "$(jq -S -c -n --arg er "post-spawn-fail" '{exit_reason:$er}')" >/dev/null
  local state er
  state="$(registry_get_snapshot "${tmp}" | jq -r '.workers["wkr-s6-post"].state')"
  er="$(registry_get_snapshot "${tmp}" | jq -r '.workers["wkr-s6-post"].exit_reason')"
  [[ "${state}" == "failed" && "${er}" == "crash:post-spawn-fail" ]] && _pass "crash → failed" || _fail "state=${state} er=${er}"
  rm -rf "${tmp}"
}

s7_idempotent_spawn_ready() {
  echo "=== S7: spawn_ready idempotent retry ==="
  local tmp; tmp="$(_mktmp)"
  _register_worker "${tmp}" "s7" "w" tmux "feature-y:0.0" >/dev/null
  registry_append_event "${tmp}" spawn_ready "wkr-s7-w" tmux \
    "$(jq -S -c -n --arg rh "feature-y:0.0" '{runner_handle:$rh}')" >/dev/null 2>&1
  local lines; lines="$(wc -l < "${tmp}/.company-runtime/harness/workers.jsonl")"
  [[ "${lines}" -eq 2 ]] && _pass "lines=2 (idempotent no-op)" || _fail "lines=${lines}"
  rm -rf "${tmp}"
}

s8_watcher_plan_emitted() {
  echo "=== S8: watcher → plan_emitted 합성 ==="
  local tmp; tmp="$(_mktmp)"
  local sid="s8" worker="w"
  local wt; wt="$(_register_worker "${tmp}" "${sid}" "${worker}" sequential "inline:${sid}")"
  printf '# plan\n\nbody text padded to at least 50 bytes for watcher threshold.\n' > "${wt}/compact-plan.md"
  bash "${COLLECTOR}" "${sid}" "${tmp}" --oneshot 2>/dev/null || true
  local state sr
  state="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"wkr-${sid}-${worker}\"].state")"
  sr="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"wkr-${sid}-${worker}\"].state_reason")"
  [[ "${state}" == "waiting_approval" ]] && _pass "state=waiting_approval" || _fail "state=${state}"
  [[ "${sr}" == *"compact-plan.md" ]] && _pass "state_reason 에 plan_path 보존" || _fail "sr=${sr}"
  bash "${COLLECTOR}" "${sid}" "${tmp}" --oneshot 2>/dev/null || true
  local lines; lines="$(wc -l < "${tmp}/.company-runtime/harness/workers.jsonl")"
  [[ "${lines}" -eq 3 ]] && _pass "dedup: lines=3" || _fail "dedup lines=${lines}"
  rm -rf "${tmp}"
}

s9_watcher_result_emitted() {
  echo "=== S9: watcher → result_emitted 합성 ==="
  local tmp; tmp="$(_mktmp)"
  local sid="s9" worker="w"
  local wt; wt="$(_register_worker "${tmp}" "${sid}" "${worker}" sequential "inline:${sid}")"
  # result-collector 는 200B 미만 파일을 template 으로 간주해 skip. 충분히 패딩.
  cat > "${wt}/compact-result.md" <<EOF
status: ok
worker: ${worker}
summary: |
  actual result content padded to exceed the 200-byte threshold imposed by
  result-collector.sh so that the watcher emits result_emitted instead of
  treating the file as a template placeholder. additional padding line one.
  additional padding line two. additional padding line three follows here.
EOF
  bash "${COLLECTOR}" "${sid}" "${tmp}" --oneshot 2>/dev/null || true
  local state er
  state="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"wkr-${sid}-${worker}\"].state")"
  er="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"wkr-${sid}-${worker}\"].exit_reason")"
  [[ "${state}" == "completed" ]] && _pass "state=completed" || _fail "state=${state}"
  [[ "${er}" == "result" ]] && _pass "exit_reason=result" || _fail "er=${er}"
  rm -rf "${tmp}"
}

case "${WHICH}" in
  all) s5_multi_runner_record; s6_cmux_pre_post_failure; s7_idempotent_spawn_ready; s8_watcher_plan_emitted; s9_watcher_result_emitted ;;
  s5)  s5_multi_runner_record ;;
  s6)  s6_cmux_pre_post_failure ;;
  s7)  s7_idempotent_spawn_ready ;;
  s8)  s8_watcher_plan_emitted ;;
  s9)  s9_watcher_result_emitted ;;
  *)   echo "usage: $0 [all|s5|s6|s7|s8|s9]" >&2; exit 2 ;;
esac

echo
echo "─────────────────────────"
echo "smoke worker-registry phase2: ${PASS} PASS, ${FAIL} FAIL"
[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0
