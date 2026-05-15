#!/usr/bin/env bash
# scripts/smoke-worker-registry-repeatable.sh
#
# Repeatable event 화이트리스트 smoke (S19 + sub-cases).
#
# 결정문: docs/decisions/2026-05-13-registry-repeatable-events.md D6
#
# 시나리오:
#   S19  : stop_requested distinct payload (reason="A" → reason="B")
#          → 2 라인 모두 append, snapshot state 변경 0, hard fail 0건.
#   S19a : exact retry idempotent — 같은 payload 2회 → 1 라인 + idempotent ignore stderr.
#   S19b : A/B/A 시퀀스 — 세 번째 A 가 직전 B 와 distinct → 3 라인 모두 append.
#   S19c : helper fault injection — _REGISTRY_TEST_FAIL_APPEND=1 → return 1 + 락 누수 0.
#   S19d : 비 repeatable refactor 회귀 — spawn_started 정상 append + duplicate guard 정합.

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
_mktmp() { mktemp -d -t reg-rep.XXXXXX; }

_register() {
  local pr="$1" sid="$2" worker="$3" runner="$4"
  registry_init "${pr}"
  local wid="wkr-${sid}-${worker}"
  local wt="${pr}/.company-runtime/sessions/${sid}/workers/${worker}"
  mkdir -p "${wt}"
  local payload
  payload="$(jq -S -c -n --arg rh "feat:0.0" --arg wt "${wt}" --arg topic "${worker}" --arg role "primary" --arg sid "${sid}" \
    '{runner_handle:$rh, worktree_path:$wt, branch:null, topic:$topic, worker_role:$role, session_id:$sid}')"
  registry_append_event "${pr}" spawn_started "${wid}" "${runner}" "${payload}" >/dev/null 2>&1
  registry_append_event "${pr}" spawn_ready   "${wid}" "${runner}" \
    "$(jq -S -c -n --arg rh "feat:0.0" '{runner_handle:$rh}')" >/dev/null 2>&1
}

_count_events() {
  local pr="$1" wid="$2" etype="$3"
  local events="${pr}/.company-runtime/harness/workers.jsonl"
  [[ -s "${events}" ]] || { echo 0; return; }
  jq -c --arg w "${wid}" --arg e "${etype}" \
    'select(.worker_id == $w and .event_type == $e)' "${events}" | wc -l | tr -d ' '
}

_state_of() {
  local pr="$1" wid="$2"
  registry_replay "${pr}" 2>/dev/null | jq -r --arg w "${wid}" '.workers[$w].state // "missing"'
}

s19_distinct_payload() {
  echo "=== S19: stop_requested distinct payload (A → B, 2 라인 append) ==="
  local tmp; tmp="$(_mktmp)"
  local sid="S19" worker="w"
  local wid="wkr-${sid}-${worker}"
  _register "${tmp}" "${sid}" "${worker}" tmux

  local stderr_log="${tmp}/.stderr.log"
  registry_append_event "${tmp}" stop_requested "${wid}" tmux \
    '{"actor":"user","reason":"A"}' 2>"${stderr_log}"
  local rc1=$?
  registry_append_event "${tmp}" stop_requested "${wid}" tmux \
    '{"actor":"user","reason":"B"}' 2>>"${stderr_log}"
  local rc2=$?

  [[ "${rc1}" -eq 0 ]] && _pass "1차 stop_requested(A) rc=0" || _fail "1차 rc=${rc1}"
  [[ "${rc2}" -eq 0 ]] && _pass "2차 stop_requested(B) rc=0 (hard fail 안 함)" || _fail "2차 rc=${rc2}"

  local n; n="$(_count_events "${tmp}" "${wid}" stop_requested)"
  [[ "${n}" -eq 2 ]] && _pass "events.jsonl stop_requested 2 라인" || _fail "라인 수=${n} (기대 2)"

  local events="${tmp}/.company-runtime/harness/workers.jsonl"
  local r1 r2
  r1="$(jq -c --arg w "${wid}" 'select(.worker_id == $w and .event_type == "stop_requested") | .payload.reason' "${events}" | sed -n 1p)"
  r2="$(jq -c --arg w "${wid}" 'select(.worker_id == $w and .event_type == "stop_requested") | .payload.reason' "${events}" | sed -n 2p)"
  [[ "${r1}" == '"A"' && "${r2}" == '"B"' ]] && _pass "audit reason 보존 (A,B)" || _fail "reason=${r1},${r2}"

  local st; st="$(_state_of "${tmp}" "${wid}")"
  [[ "${st}" == "running" ]] && _pass "snapshot state 변경 0 (running 유지)" || _fail "state=${st}"

  if grep -q "conflicting payload" "${stderr_log}"; then
    _fail "stderr 에 conflicting payload (hard fail 발생)"
  else
    _pass "hard fail 메시지 0건"
  fi

  rm -rf "${tmp}"
}

s19a_exact_retry() {
  echo "=== S19a: exact retry idempotent (같은 payload 2회) ==="
  local tmp; tmp="$(_mktmp)"
  local sid="S19a" worker="w"
  local wid="wkr-${sid}-${worker}"
  _register "${tmp}" "${sid}" "${worker}" tmux

  local stderr_log="${tmp}/.stderr.log"
  registry_append_event "${tmp}" stop_requested "${wid}" tmux \
    '{"actor":"user","reason":"A"}' 2>"${stderr_log}"
  registry_append_event "${tmp}" stop_requested "${wid}" tmux \
    '{"actor":"user","reason":"A"}' 2>>"${stderr_log}"
  local rc=$?

  [[ "${rc}" -eq 0 ]] && _pass "2차 호출 rc=0 (idempotent)" || _fail "2차 rc=${rc}"

  local n; n="$(_count_events "${tmp}" "${wid}" stop_requested)"
  [[ "${n}" -eq 1 ]] && _pass "events.jsonl 1 라인만 (audit 누적 차단)" || _fail "라인 수=${n} (기대 1)"

  if grep -q "idempotent ignore (repeatable" "${stderr_log}"; then
    _pass "stderr 에 idempotent ignore (repeatable, ...) 메시지"
  else
    _fail "idempotent ignore (repeatable) 메시지 없음"
  fi

  rm -rf "${tmp}"
}

s19b_aba_sequence() {
  echo "=== S19b: A/B/A 시퀀스 — 세 번째 A 정상 append (most recent 기준) ==="
  local tmp; tmp="$(_mktmp)"
  local sid="S19b" worker="w"
  local wid="wkr-${sid}-${worker}"
  _register "${tmp}" "${sid}" "${worker}" tmux

  registry_append_event "${tmp}" stop_requested "${wid}" tmux '{"actor":"user","reason":"A"}' 2>/dev/null
  registry_append_event "${tmp}" stop_requested "${wid}" tmux '{"actor":"user","reason":"B"}' 2>/dev/null
  registry_append_event "${tmp}" stop_requested "${wid}" tmux '{"actor":"user","reason":"A"}' 2>/dev/null

  local n; n="$(_count_events "${tmp}" "${wid}" stop_requested)"
  [[ "${n}" -eq 3 ]] && _pass "events.jsonl 3 라인 (A,B,A)" || _fail "라인 수=${n} (기대 3)"

  local events="${tmp}/.company-runtime/harness/workers.jsonl"
  local r3
  r3="$(jq -c --arg w "${wid}" 'select(.worker_id == $w and .event_type == "stop_requested") | .payload.reason' "${events}" | sed -n 3p)"
  [[ "${r3}" == '"A"' ]] && _pass "세 번째 reason=A 정상 append" || _fail "세 번째 reason=${r3}"

  rm -rf "${tmp}"
}

s19c_fault_injection() {
  echo "=== S19c: helper fault injection (_REGISTRY_TEST_FAIL_APPEND=1) ==="
  local tmp; tmp="$(_mktmp)"
  local sid="S19c" worker="w"
  local wid="wkr-${sid}-${worker}"
  _register "${tmp}" "${sid}" "${worker}" tmux

  local before; before="$(_count_events "${tmp}" "${wid}" stop_requested)"

  _REGISTRY_TEST_FAIL_APPEND=1 registry_append_event "${tmp}" stop_requested "${wid}" tmux \
    '{"actor":"user","reason":"A"}' 2>/dev/null
  local rc=$?

  [[ "${rc}" -ne 0 ]] && _pass "fault injection rc!=0 (return 1)" || _fail "rc=${rc} (기대 비 0)"

  local after; after="$(_count_events "${tmp}" "${wid}" stop_requested)"
  [[ "${after}" -eq "${before}" ]] && _pass "events.jsonl 변경 0" || _fail "before=${before} after=${after}"

  # 락 누수 확인 — 다음 호출이 즉시 성공해야 함
  registry_append_event "${tmp}" stop_requested "${wid}" tmux \
    '{"actor":"user","reason":"A"}' 2>/dev/null
  local rc2=$?
  [[ "${rc2}" -eq 0 ]] && _pass "후속 호출 즉시 성공 (락 누수 0)" || _fail "후속 호출 rc=${rc2}"

  rm -rf "${tmp}"
}

s19d_non_repeatable_regression() {
  echo "=== S19d: 비 repeatable event refactor 회귀 ==="
  local tmp; tmp="$(_mktmp)"
  local sid="S19d" worker="w"
  local wid="wkr-${sid}-${worker}"
  registry_init "${tmp}"

  local wt="${tmp}/.company-runtime/sessions/${sid}/workers/${worker}"
  mkdir -p "${wt}"
  local payload
  payload="$(jq -S -c -n --arg rh "feat:0.0" --arg wt "${wt}" --arg topic "${worker}" --arg role "primary" --arg sid "${sid}" \
    '{runner_handle:$rh, worktree_path:$wt, branch:null, topic:$topic, worker_role:$role, session_id:$sid}')"

  # 1) 정상 append
  registry_append_event "${tmp}" spawn_started "${wid}" tmux "${payload}" 2>/dev/null
  local rc1=$?
  [[ "${rc1}" -eq 0 ]] && _pass "비 repeatable spawn_started 정상 append" || _fail "rc=${rc1}"

  local n; n="$(_count_events "${tmp}" "${wid}" spawn_started)"
  [[ "${n}" -eq 1 ]] && _pass "spawn_started 1 라인" || _fail "라인 수=${n}"

  # 2) 같은 payload retry → idempotent ignore
  local stderr_log="${tmp}/.stderr.log"
  registry_append_event "${tmp}" spawn_started "${wid}" tmux "${payload}" 2>"${stderr_log}"
  local rc2=$?
  [[ "${rc2}" -eq 0 ]] && _pass "same payload retry rc=0 (idempotent)" || _fail "rc=${rc2}"

  n="$(_count_events "${tmp}" "${wid}" spawn_started)"
  [[ "${n}" -eq 1 ]] && _pass "라인 누적 0 (1 라인 유지)" || _fail "라인 수=${n}"

  if grep -q "idempotent ignore" "${stderr_log}" && ! grep -q "repeatable" "${stderr_log}"; then
    _pass "비 repeatable idempotent ignore 메시지 (repeatable 표기 없음)"
  else
    _fail "idempotent ignore 메시지 회귀"
  fi

  # 3) distinct payload → hard fail (P1-12 정책 그대로)
  local distinct
  distinct="$(jq -S -c -n --arg rh "feat:1.0" --arg wt "${wt}" --arg topic "${worker}" --arg role "primary" --arg sid "${sid}" \
    '{runner_handle:$rh, worktree_path:$wt, branch:null, topic:$topic, worker_role:$role, session_id:$sid}')"
  registry_append_event "${tmp}" spawn_started "${wid}" tmux "${distinct}" 2>"${stderr_log}"
  local rc3=$?
  [[ "${rc3}" -ne 0 ]] && _pass "distinct payload hard fail (rc!=0)" || _fail "rc=${rc3} (기대 비 0)"

  if grep -q "conflicting payload" "${stderr_log}"; then
    _pass "stderr 에 conflicting payload 메시지"
  else
    _fail "conflicting payload 메시지 없음"
  fi

  n="$(_count_events "${tmp}" "${wid}" spawn_started)"
  [[ "${n}" -eq 1 ]] && _pass "라인 누적 0 (hard fail 시 append 안 함)" || _fail "라인 수=${n}"

  rm -rf "${tmp}"
}

case "${WHICH}" in
  S19|s19)    s19_distinct_payload ;;
  S19a|s19a)  s19a_exact_retry ;;
  S19b|s19b)  s19b_aba_sequence ;;
  S19c|s19c)  s19c_fault_injection ;;
  S19d|s19d)  s19d_non_repeatable_regression ;;
  all|*)
    s19_distinct_payload
    s19a_exact_retry
    s19b_aba_sequence
    s19c_fault_injection
    s19d_non_repeatable_regression
    ;;
esac

echo "─────────────────────────"
echo "smoke worker-registry repeatable: ${PASS} PASS, ${FAIL} FAIL"
[[ "${FAIL}" -eq 0 ]]
