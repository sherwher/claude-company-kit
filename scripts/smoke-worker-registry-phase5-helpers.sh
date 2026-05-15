#!/usr/bin/env bash
# scripts/smoke-worker-registry-phase5-helpers.sh
#
# Phase 5 C1 lib helper + 4 runner check_alive 단위 smoke (dead-code 회피).
#
# 결정문:
#   docs/decisions/2026-05-14-worker-registry-phase5.md D4-B
#   docs/decisions/2026-05-14-phase0-schema-v2-archived.md D2 + D5
#
# 시나리오:
#   T1: worker_archived event → state=archived (replay reducer)
#   T2: worker_archived → state=archived (worker-단위 helper)
#   T3: archived 가 terminal_csv 에 포함 (atomic helper 가 archived 인식)
#   T4: REGISTRY_SCHEMA_VERSION = 2 (lib 상수 bump)
#   T5: is_terminal 5종 갱신 (replay 가 archived 워커에 active event 도착 시 ignore)
#   T6: runner_<r>_check_alive 4종 (sequential/manual/tmux/cmux/codex-native)

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
_mktmp() { mktemp -d -t reg-p5h.XXXXXX; }

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

t1_worker_archived_transition() {
  echo "=== T1: worker_archived → state=archived (replay reducer) ==="
  local tmp; tmp="$(_mktmp)"
  local wid="wkr-T1-archived"
  _inject_event "${tmp}" spawn_started "${wid}" tmux \
    '{"runner_handle":"x","worktree_path":"/tmp/x","topic":"x","worker_role":"primary","session_id":"s"}'
  _inject_event "${tmp}" spawn_ready "${wid}" tmux '{"runner_handle":"x"}'
  _inject_event "${tmp}" stop_confirmed "${wid}" tmux '{"reason":"user"}'
  _inject_event "${tmp}" worker_archived "${wid}" tmux \
    '{"actor":"user","reason":"test","scenario":"normal_stopped"}'

  registry_rebuild_index "${tmp}" >/dev/null
  local snap; snap="$(registry_get_snapshot "${tmp}")"
  local state; state="$(echo "${snap}" | jq -r --arg w "${wid}" '.workers[$w].state')"
  [[ "${state}" == "archived" ]] && _pass "state=archived" || _fail "state=${state}"

  local sr; sr="$(echo "${snap}" | jq -r --arg w "${wid}" '.workers[$w].state_reason')"
  [[ "${sr}" == "archived: normal_stopped" ]] && _pass "state_reason 보존" || _fail "sr=${sr}"

  rm -rf "${tmp}"
}

t2_worker_archived_helper() {
  echo "=== T2: worker_archived → state=archived (worker-단위 helper) ==="
  local tmp; tmp="$(_mktmp)"
  local events="${tmp}/.company-runtime/harness/workers.jsonl"
  local wid="wkr-T2-archived"
  _inject_event "${tmp}" spawn_started "${wid}" tmux \
    '{"runner_handle":"x","worktree_path":"/tmp/x","topic":"x","worker_role":"primary","session_id":"s"}'
  _inject_event "${tmp}" spawn_ready "${wid}" tmux '{"runner_handle":"x"}'
  _inject_event "${tmp}" stop_confirmed "${wid}" tmux '{"reason":"user"}'
  _inject_event "${tmp}" worker_archived "${wid}" tmux \
    '{"actor":"user","reason":"test","scenario":"normal_stopped"}'

  local st; st="$(_registry_replay_state_for_worker "${events}" "${wid}")"
  [[ "${st}" == "archived" ]] && _pass "helper 가 archived 반환" || _fail "got=${st}"

  rm -rf "${tmp}"
}

t3_atomic_helper_archived_terminal() {
  echo "=== T3: atomic helper 가 archived 를 terminal 로 인식 ==="
  local tmp; tmp="$(_mktmp)"
  local events="${tmp}/.company-runtime/harness/workers.jsonl"
  local wid="wkr-T3-archived"
  _inject_event "${tmp}" spawn_started "${wid}" tmux \
    '{"runner_handle":"x","worktree_path":"/tmp/x","topic":"x","worker_role":"primary","session_id":"s"}'
  _inject_event "${tmp}" spawn_ready "${wid}" tmux '{"runner_handle":"x"}'
  _inject_event "${tmp}" stop_confirmed "${wid}" tmux '{"reason":"user"}'
  _inject_event "${tmp}" worker_archived "${wid}" tmux \
    '{"actor":"user","reason":"first","scenario":"normal_stopped"}'

  # 다시 worker_archived 호출 (multi-leader cleanup race 시뮬레이션)
  local stderr_log="${tmp}/.stderr.log"
  registry_append_event_with_terminal_check "${tmp}" worker_archived "${wid}" tmux \
    '{"actor":"user","reason":"second","scenario":"normal_stopped"}' \
    "completed,failed,stopped,orphaned,archived" 2>"${stderr_log}"
  local rc=$?
  [[ "${rc}" -eq 0 ]] && _pass "rc=0 (terminal no-op)" || _fail "rc=${rc}"

  local n; n="$(jq -c --arg w "${wid}" 'select(.worker_id == $w and .event_type == "worker_archived")' "${events}" | wc -l | tr -d ' ')"
  [[ "${n}" -eq 1 ]] && _pass "worker_archived 1 라인 (race 차단)" || _fail "라인=${n}"

  if grep -q "terminal guard: already archived" "${stderr_log}"; then
    _pass "stderr 에 terminal guard: already archived"
  else
    _fail "terminal guard 메시지 없음"
  fi

  rm -rf "${tmp}"
}

t4_schema_version_bump() {
  echo "=== T4: REGISTRY_SCHEMA_VERSION = 2 ==="
  [[ "${REGISTRY_SCHEMA_VERSION}" == "2" ]] && _pass "lib 상수 v2" || _fail "version=${REGISTRY_SCHEMA_VERSION}"
}

t5_is_terminal_5종() {
  echo "=== T5: is_terminal 5종 — archived 워커에 active event 도착 시 ignore ==="
  local tmp; tmp="$(_mktmp)"
  local wid="wkr-T5-archived"
  _inject_event "${tmp}" spawn_started "${wid}" tmux \
    '{"runner_handle":"x","worktree_path":"/tmp/x","topic":"x","worker_role":"primary","session_id":"s"}'
  _inject_event "${tmp}" spawn_ready "${wid}" tmux '{"runner_handle":"x"}'
  _inject_event "${tmp}" stop_confirmed "${wid}" tmux '{"reason":"user"}'
  _inject_event "${tmp}" worker_archived "${wid}" tmux \
    '{"actor":"user","reason":"test","scenario":"normal_stopped"}'
  # archived 후 active event 가 도착 (out-of-order / duplicate)
  _inject_event "${tmp}" spawn_ready "${wid}" tmux '{"runner_handle":"x"}'
  _inject_event "${tmp}" plan_emitted "${wid}" tmux '{"plan_path":"p.md"}'

  registry_rebuild_index "${tmp}" >/dev/null
  local state; state="$(registry_get_snapshot "${tmp}" | jq -r --arg w "${wid}" '.workers[$w].state')"
  [[ "${state}" == "archived" ]] && _pass "active event ignore (archived 유지)" || _fail "state=${state}"

  rm -rf "${tmp}"
}

t6_runner_check_alive() {
  echo "=== T6: runner_<r>_check_alive 5종 ==="
  local tmp; tmp="$(_mktmp)"

  # 4 runner adapter source
  local rdir="${SCRIPT_DIR}/runners"
  source "${rdir}/sequential.sh"
  source "${rdir}/manual.sh"
  source "${rdir}/tmux.sh"
  source "${rdir}/cmux.sh"
  source "${rdir}/codex-native.sh"

  # T6.1: sequential — marker 부재 → GONE
  runner_sequential_check_alive "S6" "w" "${tmp}"
  [[ $? -eq 1 ]] && _pass "sequential GONE (marker 부재)" || _fail "sequential rc=$?"

  # T6.2: sequential — marker 존재 → ALIVE
  local wd="${tmp}/.company-runtime/sessions/S6/workers/w"
  mkdir -p "${wd}"
  : > "${wd}/spawn.started"
  runner_sequential_check_alive "S6" "w" "${tmp}"
  [[ $? -eq 0 ]] && _pass "sequential ALIVE (marker 존재)" || _fail "sequential rc=$?"

  # T6.3: manual — marker 존재 → ALIVE
  runner_manual_check_alive "S6" "w" "${tmp}"
  [[ $? -eq 0 ]] && _pass "manual ALIVE" || _fail "manual rc=$?"

  # T6.4: codex-native — INDETERMINATE
  runner_codex_native_check_alive "S6" "w" "${tmp}"
  [[ $? -eq 2 ]] && _pass "codex-native INDETERMINATE" || _fail "codex-native rc=$?"

  # T6.5: tmux — marker 부재 + spawn.started 존재 → ALIVE (fallback)
  runner_tmux_check_alive "S6" "w" "${tmp}"
  [[ $? -eq 0 ]] && _pass "tmux ALIVE (fallback marker)" || _fail "tmux rc=$?"

  # T6.6: cmux — cmux-target 부재 → GONE
  runner_cmux_check_alive "S6" "w" "${tmp}"
  [[ $? -eq 1 ]] && _pass "cmux GONE (cmux-target 부재)" || _fail "cmux rc=$?"

  rm -rf "${tmp}"
}

case "${WHICH}" in
  T1|t1) t1_worker_archived_transition ;;
  T2|t2) t2_worker_archived_helper ;;
  T3|t3) t3_atomic_helper_archived_terminal ;;
  T4|t4) t4_schema_version_bump ;;
  T5|t5) t5_is_terminal_5종 ;;
  T6|t6) t6_runner_check_alive ;;
  all|*)
    t1_worker_archived_transition
    t2_worker_archived_helper
    t3_atomic_helper_archived_terminal
    t4_schema_version_bump
    t5_is_terminal_5종
    t6_runner_check_alive
    ;;
esac

echo "─────────────────────────"
echo "smoke worker-registry phase5 helpers: ${PASS} PASS, ${FAIL} FAIL"
[[ "${FAIL}" -eq 0 ]]
