#!/usr/bin/env bash
# scripts/smoke-workers-stop.sh
#
# Phase 4 stop CLI smoke (S16~S18 + S20).
#
# 결정문: docs/decisions/2026-05-13-worker-registry-phase4.md D5 + D7
#
# 시나리오:
#   S16 : 정상 stop (running → stopped, --json schema 정합)
#   S17 : terminal guard idempotency (S16 후 같은 wid 재호출 → noop)
#   S18 : approval token revoke (issued → revoked, consumed unchanged)
#   S20 : multi-leader race (두 subshell 동시 stop → stop_confirmed 1 라인)
#   S16f: --force 분기 (orphan_detected 자동 emit, --json forced/orphan_emitted)
#   S16e: runner 호출 실패 + --force 미지정 (exit 2, stop_confirmed/revoke 0)
#   S16n: not-found (exit 1)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/worker-registry-lib.sh"
STOP_SH="${SCRIPT_DIR}/worker-registry-stop.sh"

[[ -f "${LIB}" ]] || { echo "smoke: worker-registry-lib.sh missing" >&2; exit 2; }
[[ -f "${STOP_SH}" ]] || { echo "smoke: worker-registry-stop.sh missing" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "smoke: jq required" >&2; exit 2; }

source "${LIB}"
set +eu

PASS=0
FAIL=0
WHICH="${1:-all}"

_pass() { echo "  PASS: $*"; PASS=$(( PASS + 1 )); }
_fail() { echo "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }
_mktmp() { mktemp -d -t reg-stop.XXXXXX; }

# 워커 1개 spawn 시뮬레이션 (registry 상태만, 실 runner 없음)
_register() {
  local pr="$1" sid="$2" worker="$3" runner="$4"
  registry_init "${pr}"
  local wid="wkr-${sid}-${worker}"
  local wt="${pr}/.company-runtime/sessions/${sid}/workers/${worker}"
  mkdir -p "${wt}"
  local payload
  payload="$(jq -S -c -n --arg rh "feat:0.0" --arg wt "${wt}" --arg topic "${worker}" \
    --arg role "primary" --arg sid "${sid}" \
    '{runner_handle:$rh, worktree_path:$wt, branch:null, topic:$topic, worker_role:$role, session_id:$sid}')"
  registry_append_event "${pr}" spawn_started "${wid}" "${runner}" "${payload}" >/dev/null 2>&1
  registry_append_event "${pr}" spawn_ready "${wid}" "${runner}" \
    "$(jq -S -c -n --arg rh "feat:0.0" '{runner_handle:$rh}')" >/dev/null 2>&1
  echo "${wid}"
}

# CLI 호출 헬퍼 — stop CLI 가 exit 호출하므로 subshell 안에서.
_run_stop() {
  local pr="$1"; shift
  ( export PROJECT_ROOT="${pr}"; source "${STOP_SH}"; registry_cmd_stop "$@" )
}

_count_events() {
  local pr="$1" wid="$2" etype="$3"
  local events="${pr}/.company-runtime/harness/workers.jsonl"
  [[ -s "${events}" ]] || { echo 0; return; }
  jq -c --arg w "${wid}" --arg e "${etype}" \
    'select(.worker_id == $w and .event_type == $e)' "${events}" | wc -l | tr -d ' '
}

s16_normal_stop() {
  echo "=== S16: 정상 stop (running → stopped, --json schema) ==="
  local tmp; tmp="$(_mktmp)"
  local wid; wid="$(_register "${tmp}" "S16" "w" tmux)"

  local out; out="$(_run_stop "${tmp}" "${wid}" --reason="test" --json 2>/dev/null)"
  local rc=$?
  [[ "${rc}" -eq 0 ]] && _pass "exit 0" || _fail "exit=${rc}"

  local action from to reason tr
  action="$(echo "${out}" | jq -r '.action')"
  from="$(echo "${out}" | jq -r '.from')"
  to="$(echo "${out}" | jq -r '.to')"
  reason="$(echo "${out}" | jq -r '.reason')"
  tr="$(echo "${out}" | jq -r '.tokens_revoked')"
  [[ "${action}" == "stop" ]] && _pass "json action=stop" || _fail "action=${action}"
  [[ "${from}" == "running" ]] && _pass "json from=running" || _fail "from=${from}"
  [[ "${to}" == "stopped" ]] && _pass "json to=stopped" || _fail "to=${to}"
  [[ "${reason}" == "test" ]] && _pass "json reason=test" || _fail "reason=${reason}"
  [[ "${tr}" == "0" ]] && _pass "json tokens_revoked=0" || _fail "tr=${tr}"

  local sr_n sc_n
  sr_n="$(_count_events "${tmp}" "${wid}" stop_requested)"
  sc_n="$(_count_events "${tmp}" "${wid}" stop_confirmed)"
  [[ "${sr_n}" -eq 1 && "${sc_n}" -eq 1 ]] && _pass "events: stop_requested 1 + stop_confirmed 1" \
    || _fail "sr=${sr_n} sc=${sc_n}"

  local snap_state
  snap_state="$(registry_get_snapshot "${tmp}" | jq -r --arg w "${wid}" '.workers[$w].state')"
  [[ "${snap_state}" == "stopped" ]] && _pass "snapshot state=stopped" || _fail "state=${snap_state}"

  rm -rf "${tmp}"
}

s17_terminal_idempotency() {
  echo "=== S17: terminal guard idempotency (S16 후 재호출) ==="
  local tmp; tmp="$(_mktmp)"
  local wid; wid="$(_register "${tmp}" "S17" "w" tmux)"

  _run_stop "${tmp}" "${wid}" --reason="first" --json >/dev/null 2>&1
  local before_n; before_n="$(_count_events "${tmp}" "${wid}" stop_confirmed)"

  local out; out="$(_run_stop "${tmp}" "${wid}" --reason="second" --json 2>/dev/null)"
  local rc=$?
  [[ "${rc}" -eq 0 ]] && _pass "재호출 exit 0" || _fail "exit=${rc}"

  local action reason
  action="$(echo "${out}" | jq -r '.action')"
  reason="$(echo "${out}" | jq -r '.reason')"
  [[ "${action}" == "noop" ]] && _pass "json action=noop" || _fail "action=${action}"
  [[ "${reason}" == "already_terminal" ]] && _pass "json reason=already_terminal" || _fail "reason=${reason}"

  local after_n; after_n="$(_count_events "${tmp}" "${wid}" stop_confirmed)"
  [[ "${after_n}" -eq "${before_n}" ]] && _pass "stop_confirmed 추가 0" || _fail "before=${before_n} after=${after_n}"

  rm -rf "${tmp}"
}

s18_approval_token_revoke() {
  echo "=== S18: approval token revoke (issued → revoked) ==="
  local tmp; tmp="$(_mktmp)"
  local wid; wid="$(_register "${tmp}" "S18" "w" tmux)"

  # issued 토큰 1건 + consumed 토큰 1건 사전 주입
  registry_append_event "${tmp}" approval_token_issued "${wid}" tmux \
    '{"scope":"shell:bq","actor":"user"}' >/dev/null 2>&1
  registry_append_event "${tmp}" approval_token_issued "${wid}" tmux \
    '{"scope":"shell:gcloud","actor":"user"}' >/dev/null 2>&1
  registry_append_event "${tmp}" approval_token_consumed "${wid}" tmux \
    '{"scope":"shell:gcloud"}' >/dev/null 2>&1

  local out; out="$(_run_stop "${tmp}" "${wid}" --reason="test" --json 2>/dev/null)"
  local rc=$?
  [[ "${rc}" -eq 0 ]] && _pass "exit 0" || _fail "exit=${rc}"

  local revoked_n; revoked_n="$(_count_events "${tmp}" "${wid}" approval_token_revoked)"
  [[ "${revoked_n}" -eq 1 ]] && _pass "approval_token_revoked 1 라인 (issued 1건 만)" \
    || _fail "revoked_n=${revoked_n}"

  local tr; tr="$(echo "${out}" | jq -r '.tokens_revoked')"
  [[ "${tr}" == "1" ]] && _pass "json tokens_revoked=1" || _fail "tr=${tr}"

  rm -rf "${tmp}"
}

s16f_force_orphan() {
  echo "=== S16f: --force orphan_detected 자동 emit ==="
  local tmp; tmp="$(_mktmp)"
  local wid; wid="$(_register "${tmp}" "S16f" "w" tmux)"

  # stalled 상태로 만들기 위해 stall_detected 주입
  registry_append_event "${tmp}" stall_detected "${wid}" tmux \
    '{"last_seen_at":"2026-05-14T00:00:00Z","threshold_sec":300}' >/dev/null 2>&1

  local out; out="$(_run_stop "${tmp}" "${wid}" --force --reason="watchdog" --json 2>/dev/null)"
  local rc=$?
  [[ "${rc}" -eq 0 ]] && _pass "exit 0" || _fail "exit=${rc}"

  local to forced oe reason
  to="$(echo "${out}" | jq -r '.to')"
  forced="$(echo "${out}" | jq -r '.forced')"
  oe="$(echo "${out}" | jq -r '.orphan_emitted')"
  reason="$(echo "${out}" | jq -r '.reason')"
  [[ "${to}" == "orphaned" ]] && _pass "json to=orphaned" || _fail "to=${to}"
  [[ "${forced}" == "true" ]] && _pass "json forced=true" || _fail "forced=${forced}"
  [[ "${oe}" == "true" ]] && _pass "json orphan_emitted=true" || _fail "oe=${oe}"
  [[ "${reason}" == "force:watchdog" ]] && _pass "json reason=force:watchdog" || _fail "reason=${reason}"

  local od_n; od_n="$(_count_events "${tmp}" "${wid}" orphan_detected)"
  [[ "${od_n}" -eq 1 ]] && _pass "orphan_detected 1 라인" || _fail "od_n=${od_n}"

  local snap_state
  snap_state="$(registry_get_snapshot "${tmp}" | jq -r --arg w "${wid}" '.workers[$w].state')"
  [[ "${snap_state}" == "orphaned" ]] && _pass "snapshot state=orphaned" || _fail "state=${snap_state}"

  rm -rf "${tmp}"
}

s16n_not_found() {
  echo "=== S16n: not-found (exit 1) ==="
  local tmp; tmp="$(_mktmp)"
  registry_init "${tmp}"

  local out; out="$(_run_stop "${tmp}" "wkr-nonexistent" --json 2>/dev/null)"
  local rc=$?
  [[ "${rc}" -eq 1 ]] && _pass "exit 1" || _fail "exit=${rc}"

  local action reason
  action="$(echo "${out}" | jq -r '.action')"
  reason="$(echo "${out}" | jq -r '.reason')"
  [[ "${action}" == "error" ]] && _pass "json action=error" || _fail "action=${action}"
  [[ "${reason}" == "not_found" ]] && _pass "json reason=not_found" || _fail "reason=${reason}"

  rm -rf "${tmp}"
}

s20_multi_leader_race() {
  echo "=== S20: multi-leader race (두 subshell 동시 stop) ==="
  local tmp; tmp="$(_mktmp)"
  local wid; wid="$(_register "${tmp}" "S20" "w" tmux)"

  local out_a="${tmp}/.a.out" out_b="${tmp}/.b.out"
  local err_a="${tmp}/.a.err" err_b="${tmp}/.b.err"

  ( _run_stop "${tmp}" "${wid}" --reason="A" --json >"${out_a}" 2>"${err_a}" ) &
  local pid_a=$!
  ( _run_stop "${tmp}" "${wid}" --reason="B" --json >"${out_b}" 2>"${err_b}" ) &
  local pid_b=$!
  wait "${pid_a}"; local rc_a=$?
  wait "${pid_b}"; local rc_b=$?

  [[ "${rc_a}" -eq 0 && "${rc_b}" -eq 0 ]] && _pass "두 호출 모두 exit 0" || _fail "rc_a=${rc_a} rc_b=${rc_b}"

  local sc_n; sc_n="$(_count_events "${tmp}" "${wid}" stop_confirmed)"
  [[ "${sc_n}" -eq 1 ]] && _pass "stop_confirmed 정확히 1 라인" || _fail "sc_n=${sc_n}"

  # stop_requested 는 distinct payload (A vs B) 라 화이트리스트로 2 라인
  local sr_n; sr_n="$(_count_events "${tmp}" "${wid}" stop_requested)"
  [[ "${sr_n}" -eq 2 ]] && _pass "stop_requested 2 라인 (Repeatable Events)" || _fail "sr_n=${sr_n}"

  # 두 호출 중 하나는 action=stop, 다른 하나는 action=noop
  local action_a action_b
  action_a="$(jq -r '.action' "${out_a}" 2>/dev/null)"
  action_b="$(jq -r '.action' "${out_b}" 2>/dev/null)"
  if [[ ( "${action_a}" == "stop" && "${action_b}" == "noop" ) \
     || ( "${action_a}" == "noop" && "${action_b}" == "stop" ) ]]; then
    _pass "한 쪽 stop + 한 쪽 noop"
  else
    _fail "action_a=${action_a} action_b=${action_b}"
  fi

  # 두 호출 중 정확히 한 stderr 에 terminal guard 메시지
  local guard_a guard_b
  grep -q "terminal guard: already" "${err_a}" 2>/dev/null && guard_a=1 || guard_a=0
  grep -q "terminal guard: already" "${err_b}" 2>/dev/null && guard_b=1 || guard_b=0
  [[ $(( guard_a + guard_b )) -eq 1 ]] && _pass "terminal guard stderr 정확히 한 쪽" \
    || _fail "guard_a=${guard_a} guard_b=${guard_b}"

  rm -rf "${tmp}"
}

case "${WHICH}" in
  S16|s16)   s16_normal_stop ;;
  S17|s17)   s17_terminal_idempotency ;;
  S18|s18)   s18_approval_token_revoke ;;
  S16f|s16f) s16f_force_orphan ;;
  S16n|s16n) s16n_not_found ;;
  S20|s20)   s20_multi_leader_race ;;
  all|*)
    s16_normal_stop
    s17_terminal_idempotency
    s18_approval_token_revoke
    s16f_force_orphan
    s16n_not_found
    s20_multi_leader_race
    ;;
esac

echo "─────────────────────────"
echo "smoke workers stop: ${PASS} PASS, ${FAIL} FAIL"
[[ "${FAIL}" -eq 0 ]]
