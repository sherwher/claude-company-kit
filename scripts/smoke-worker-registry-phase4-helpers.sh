#!/usr/bin/env bash
# scripts/smoke-worker-registry-phase4-helpers.sh
#
# Phase 4 D6-A lib helper 단위 smoke (C1 검증 — caller 부재 dead-code window 회귀 차단).
#
# 결정문: docs/decisions/2026-05-13-worker-registry-phase4.md D6-A + D7
#
# 시나리오:
#   T1  : _registry_replay_state_for_worker transition coverage 4 case
#         (result_emitted/crash_detected/stop_confirmed/orphan_detected)
#   T2  : terminal pre-existing 4 case (helper 가 4 terminal 진입 event 사전 주입 후 terminal 반환)
#   T3  : terminal-after-active 28 case (4 terminal × 7 active event — terminal 유지 검증)
#   T4  : terminal-after-token-event (4 terminal × {revoked, consumed} — terminal 유지)
#   T5  : registry_append_event_with_terminal_check 5계약
#         (a) lock 획득, (b) terminal 판단, (c) terminal no-op, (d) non-terminal append, (e) rebuild trigger

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/worker-registry-lib.sh"

[[ -f "${LIB}" ]] || { echo "smoke: worker-registry-lib.sh missing" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "smoke: jq required" >&2; exit 2; }

source "${LIB}"
set +eu

PASS=0
FAIL=0
WHICH="${1:-all}"

_pass() { echo "  PASS: $*"; PASS=$(( PASS + 1 )); }
_fail() { echo "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }
_mktmp() { mktemp -d -t reg-p4h.XXXXXX; }

# 직접 events.jsonl 에 한 라인 주입 (transition coverage 단위 test 용)
_inject_event() {
  local pr="$1" etype="$2" wid="$3" runner="$4" payload="$5"
  registry_init "${pr}"
  local events="${pr}/.company-runtime/harness/workers.jsonl"
  local ts; ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local line
  line="$(jq -c -n --arg ts "${ts}" --argjson sv "${REGISTRY_SCHEMA_VERSION}" \
    --arg etype "${etype}" --arg wid "${wid}" --arg runner "${runner}" --argjson p "${payload}" \
    '{ts:$ts, schema_version:$sv, event_type:$etype, worker_id:$wid, runner:$runner, payload:$p}')"
  printf '%s\n' "${line}" >> "${events}"
}

t1_transition_coverage() {
  echo "=== T1: _registry_replay_state_for_worker transition coverage 4 case ==="
  local tmp; tmp="$(_mktmp)"
  local events="${tmp}/.company-runtime/harness/workers.jsonl"

  # case 1: result_emitted → completed
  local wid="wkr-T1-completed"
  _inject_event "${tmp}" spawn_started "${wid}" tmux \
    '{"runner_handle":"x","worktree_path":"/tmp/x","topic":"x","worker_role":"primary","session_id":"s"}'
  _inject_event "${tmp}" spawn_ready "${wid}" tmux '{"runner_handle":"x"}'
  _inject_event "${tmp}" result_emitted "${wid}" tmux '{}'
  local st; st="$(_registry_replay_state_for_worker "${events}" "${wid}")"
  [[ "${st}" == "completed" ]] && _pass "result_emitted → completed" || _fail "got=${st}"

  # case 2: crash_detected → failed
  wid="wkr-T1-failed"
  _inject_event "${tmp}" spawn_started "${wid}" tmux \
    '{"runner_handle":"x","worktree_path":"/tmp/x","topic":"x","worker_role":"primary","session_id":"s"}'
  _inject_event "${tmp}" spawn_ready "${wid}" tmux '{"runner_handle":"x"}'
  _inject_event "${tmp}" crash_detected "${wid}" tmux '{"exit_reason":"sigsegv"}'
  st="$(_registry_replay_state_for_worker "${events}" "${wid}")"
  [[ "${st}" == "failed" ]] && _pass "crash_detected → failed" || _fail "got=${st}"

  # case 3: stop_confirmed → stopped
  wid="wkr-T1-stopped"
  _inject_event "${tmp}" spawn_started "${wid}" tmux \
    '{"runner_handle":"x","worktree_path":"/tmp/x","topic":"x","worker_role":"primary","session_id":"s"}'
  _inject_event "${tmp}" spawn_ready "${wid}" tmux '{"runner_handle":"x"}'
  _inject_event "${tmp}" stop_confirmed "${wid}" tmux '{"reason":"user"}'
  st="$(_registry_replay_state_for_worker "${events}" "${wid}")"
  [[ "${st}" == "stopped" ]] && _pass "stop_confirmed → stopped" || _fail "got=${st}"

  # case 4: orphan_detected → orphaned (after stop_confirmed)
  wid="wkr-T1-orphaned"
  _inject_event "${tmp}" spawn_started "${wid}" tmux \
    '{"runner_handle":"x","worktree_path":"/tmp/x","topic":"x","worker_role":"primary","session_id":"s"}'
  _inject_event "${tmp}" spawn_ready "${wid}" tmux '{"runner_handle":"x"}'
  _inject_event "${tmp}" stop_confirmed "${wid}" tmux '{"reason":"force:stalled"}'
  _inject_event "${tmp}" orphan_detected "${wid}" tmux '{}'
  st="$(_registry_replay_state_for_worker "${events}" "${wid}")"
  [[ "${st}" == "orphaned" ]] && _pass "orphan_detected → orphaned" || _fail "got=${st}"

  rm -rf "${tmp}"
}

t2_terminal_pre_existing() {
  echo "=== T2: terminal pre-existing 4 case (helper 반환 = terminal 그대로) ==="
  local tmp; tmp="$(_mktmp)"
  local events="${tmp}/.company-runtime/harness/workers.jsonl"

  local cases=("completed:result_emitted:{}"
               "failed:crash_detected:{\"exit_reason\":\"x\"}"
               "stopped:stop_confirmed:{\"reason\":\"user\"}"
               "orphaned:orphan_detected:{}")
  local i=0
  for spec in "${cases[@]}"; do
    local terminal="${spec%%:*}"
    local rest="${spec#*:}"
    local etype="${rest%%:*}"
    local payload="${rest#*:}"
    local wid="wkr-T2-${terminal}"
    _inject_event "${tmp}" spawn_started "${wid}" tmux \
      '{"runner_handle":"x","worktree_path":"/tmp/x","topic":"x","worker_role":"primary","session_id":"s"}'
    _inject_event "${tmp}" spawn_ready "${wid}" tmux '{"runner_handle":"x"}'
    # orphaned 는 stop_confirmed 가 prerequisite
    if [[ "${terminal}" == "orphaned" ]]; then
      _inject_event "${tmp}" stop_confirmed "${wid}" tmux '{"reason":"force:x"}'
    fi
    _inject_event "${tmp}" "${etype}" "${wid}" tmux "${payload}"
    local st; st="$(_registry_replay_state_for_worker "${events}" "${wid}")"
    [[ "${st}" == "${terminal}" ]] && _pass "${terminal} pre-existing 인식" || _fail "${terminal}: got=${st}"
    i=$(( i + 1 ))
  done

  rm -rf "${tmp}"
}

t3_terminal_after_active() {
  echo "=== T3: terminal-after-active 28 case (terminal 유지) ==="
  local tmp; tmp="$(_mktmp)"
  local events="${tmp}/.company-runtime/harness/workers.jsonl"

  local terminals=("completed:result_emitted:{}"
                   "failed:crash_detected:{\"exit_reason\":\"x\"}"
                   "stopped:stop_confirmed:{\"reason\":\"user\"}"
                   "orphaned:orphan_detected:{}")
  local actives=("spawn_ready:{\"runner_handle\":\"x\"}"
                 "plan_emitted:{\"plan_path\":\"p.md\"}"
                 "plan_approved:{}"
                 "permission_prompt:{\"prompt_type\":\"cmux_gate\"}"
                 "permission_resolved:{\"actor\":\"user\"}"
                 "stall_detected:{\"last_seen_at\":\"2026-05-14T00:00:00Z\",\"threshold_sec\":300}"
                 "stall_cleared:{}")
  local total=0 pass=0
  for tspec in "${terminals[@]}"; do
    local terminal="${tspec%%:*}"
    local trest="${tspec#*:}"
    local tetype="${trest%%:*}"
    local tpayload="${trest#*:}"
    for aspec in "${actives[@]}"; do
      local aetype="${aspec%%:*}"
      local apayload="${aspec#*:}"
      local wid="wkr-T3-${terminal}-${aetype}"
      _inject_event "${tmp}" spawn_started "${wid}" tmux \
        '{"runner_handle":"x","worktree_path":"/tmp/x","topic":"x","worker_role":"primary","session_id":"s"}'
      _inject_event "${tmp}" spawn_ready "${wid}" tmux '{"runner_handle":"x"}'
      if [[ "${terminal}" == "orphaned" ]]; then
        _inject_event "${tmp}" stop_confirmed "${wid}" tmux '{"reason":"force:x"}'
      fi
      _inject_event "${tmp}" "${tetype}" "${wid}" tmux "${tpayload}"
      _inject_event "${tmp}" "${aetype}" "${wid}" tmux "${apayload}"
      local st; st="$(_registry_replay_state_for_worker "${events}" "${wid}")"
      total=$(( total + 1 ))
      if [[ "${st}" == "${terminal}" ]]; then
        pass=$(( pass + 1 ))
      else
        _fail "${terminal} → ${aetype} = ${st} (기대 ${terminal})"
      fi
    done
  done
  [[ "${pass}" -eq 28 && "${total}" -eq 28 ]] && _pass "28 case 전수 PASS (${pass}/${total})" || _fail "${pass}/${total}"

  rm -rf "${tmp}"
}

t4_terminal_after_token_event() {
  echo "=== T4: terminal-after-token-event (terminal 유지) ==="
  local tmp; tmp="$(_mktmp)"
  local events="${tmp}/.company-runtime/harness/workers.jsonl"

  local terminals=("completed:result_emitted:{}"
                   "failed:crash_detected:{\"exit_reason\":\"x\"}"
                   "stopped:stop_confirmed:{\"reason\":\"user\"}"
                   "orphaned:orphan_detected:{}")
  local token_events=("approval_token_revoked:{\"scope\":\"x\",\"actor\":\"system\"}"
                      "approval_token_consumed:{\"scope\":\"x\"}")
  local total=0 pass=0
  for tspec in "${terminals[@]}"; do
    local terminal="${tspec%%:*}"
    local trest="${tspec#*:}"
    local tetype="${trest%%:*}"
    local tpayload="${trest#*:}"
    for kspec in "${token_events[@]}"; do
      local ketype="${kspec%%:*}"
      local kpayload="${kspec#*:}"
      local wid="wkr-T4-${terminal}-${ketype}"
      _inject_event "${tmp}" spawn_started "${wid}" tmux \
        '{"runner_handle":"x","worktree_path":"/tmp/x","topic":"x","worker_role":"primary","session_id":"s"}'
      _inject_event "${tmp}" spawn_ready "${wid}" tmux '{"runner_handle":"x"}'
      if [[ "${terminal}" == "orphaned" ]]; then
        _inject_event "${tmp}" stop_confirmed "${wid}" tmux '{"reason":"force:x"}'
      fi
      _inject_event "${tmp}" "${tetype}" "${wid}" tmux "${tpayload}"
      _inject_event "${tmp}" "${ketype}" "${wid}" tmux "${kpayload}"
      local st; st="$(_registry_replay_state_for_worker "${events}" "${wid}")"
      total=$(( total + 1 ))
      if [[ "${st}" == "${terminal}" ]]; then
        pass=$(( pass + 1 ))
      else
        _fail "${terminal} → ${ketype} = ${st}"
      fi
    done
  done
  [[ "${pass}" -eq 8 && "${total}" -eq 8 ]] && _pass "8 case 전수 PASS (${pass}/${total})" || _fail "${pass}/${total}"

  rm -rf "${tmp}"
}

t5_atomic_helper_contracts() {
  echo "=== T5: registry_append_event_with_terminal_check 5계약 ==="
  local tmp; tmp="$(_mktmp)"
  local events="${tmp}/.company-runtime/harness/workers.jsonl"
  local terminal_csv="completed,failed,stopped,orphaned"

  # 계약 (b)/(d): non-terminal 이면 정상 append
  local wid="wkr-T5-active"
  _inject_event "${tmp}" spawn_started "${wid}" tmux \
    '{"runner_handle":"x","worktree_path":"/tmp/x","topic":"x","worker_role":"primary","session_id":"s"}'
  _inject_event "${tmp}" spawn_ready "${wid}" tmux '{"runner_handle":"x"}'

  registry_append_event_with_terminal_check "${tmp}" stop_confirmed "${wid}" tmux \
    '{"reason":"user"}' "${terminal_csv}"
  local rc=$?
  [[ "${rc}" -eq 0 ]] && _pass "non-terminal append rc=0" || _fail "rc=${rc}"

  local n
  n="$(jq -c --arg w "${wid}" 'select(.worker_id == $w and .event_type == "stop_confirmed")' "${events}" | wc -l | tr -d ' ')"
  [[ "${n}" -eq 1 ]] && _pass "stop_confirmed 1 라인 append" || _fail "라인=${n}"

  # 계약 (c): terminal no-op
  local stderr_log="${tmp}/.stderr.log"
  registry_append_event_with_terminal_check "${tmp}" stop_confirmed "${wid}" tmux \
    '{"reason":"user"}' "${terminal_csv}" 2>"${stderr_log}"
  rc=$?
  [[ "${rc}" -eq 0 ]] && _pass "terminal guard rc=0 (no-op)" || _fail "rc=${rc}"

  n="$(jq -c --arg w "${wid}" 'select(.worker_id == $w and .event_type == "stop_confirmed")' "${events}" | wc -l | tr -d ' ')"
  [[ "${n}" -eq 1 ]] && _pass "라인 누적 0 (terminal no-op)" || _fail "라인=${n}"

  if grep -q "terminal guard: already stopped" "${stderr_log}"; then
    _pass "stderr 에 terminal guard 메시지"
  else
    _fail "terminal guard 메시지 없음"
  fi

  # 계약 (a)/(e): 다음 호출 즉시 성공 (락 누수 0)
  local wid2="wkr-T5-other"
  _inject_event "${tmp}" spawn_started "${wid2}" tmux \
    '{"runner_handle":"x","worktree_path":"/tmp/x","topic":"x","worker_role":"primary","session_id":"s"}'
  _inject_event "${tmp}" spawn_ready "${wid2}" tmux '{"runner_handle":"x"}'
  registry_append_event_with_terminal_check "${tmp}" stop_confirmed "${wid2}" tmux \
    '{"reason":"user"}' "${terminal_csv}"
  rc=$?
  [[ "${rc}" -eq 0 ]] && _pass "다른 wid append (락 누수 0)" || _fail "rc=${rc}"

  # 계약 (e): rebuild trigger — idx 가 stop_confirmed 반영해 stopped 로 표시
  local idx_state
  idx_state="$(registry_get_snapshot "${tmp}" | jq -r --arg w "${wid}" '.workers[$w].state // "missing"')"
  [[ "${idx_state}" == "stopped" ]] && _pass "rebuild trigger 발효 (idx state=stopped)" || _fail "idx state=${idx_state}"

  rm -rf "${tmp}"
}

case "${WHICH}" in
  T1|t1) t1_transition_coverage ;;
  T2|t2) t2_terminal_pre_existing ;;
  T3|t3) t3_terminal_after_active ;;
  T4|t4) t4_terminal_after_token_event ;;
  T5|t5) t5_atomic_helper_contracts ;;
  all|*)
    t1_transition_coverage
    t2_terminal_pre_existing
    t3_terminal_after_active
    t4_terminal_after_token_event
    t5_atomic_helper_contracts
    ;;
esac

echo "─────────────────────────"
echo "smoke worker-registry phase4 helpers: ${PASS} PASS, ${FAIL} FAIL"
[[ "${FAIL}" -eq 0 ]]
