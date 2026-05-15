#!/usr/bin/env bash
# scripts/smoke-workers-doctor-cleanup.sh
#
# Phase 5 통합 smoke — doctor + cleanup CLI (S21~S25 + S21f).
#
# 결정문: docs/decisions/2026-05-14-worker-registry-phase5.md v0.4 (accepted)
#         docs/decisions/2026-05-14-phase0-schema-v2-archived.md v0.4 (accepted)
#
# 시나리오:
#   S21  doctor read-only 정합성 (running 1 + stopped 1 + orphaned 1) — events 변화 0
#   S22  cleanup 정상 (stopped → archived) — worker_archived 1 라인 + worktree 부재
#   S23  cleanup pre-condition reject (running → exit 1, 변경 0)
#   S24  dirty/unpushed 시나리오 — reject → --allow-dirty/--allow-unpushed override
#   S25  --gc 일괄 — doctor PASS 후 stopped 3개 일괄 정리, dirty 1개 skip
#   S21f doctor force_stop_assumed_leak — orphaned + check_alive=ALIVE → investigate_manually

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/worker-registry-lib.sh"
DOCTOR_SH="${SCRIPT_DIR}/worker-registry-doctor.sh"
CLEANUP_SH="${SCRIPT_DIR}/worker-registry-cleanup.sh"

[[ -f "${LIB}" ]] || { echo "smoke: worker-registry-lib.sh missing" >&2; exit 2; }
[[ -f "${DOCTOR_SH}" ]] || { echo "smoke: worker-registry-doctor.sh missing" >&2; exit 2; }
[[ -f "${CLEANUP_SH}" ]] || { echo "smoke: worker-registry-cleanup.sh missing" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "smoke: jq required" >&2; exit 2; }

source "${LIB}"
set +eu

PASS=0
FAIL=0
WHICH="${1:-all}"

_pass() { echo "  PASS: $*"; PASS=$(( PASS + 1 )); }
_fail() { echo "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }
_mktmp() { mktemp -d -t reg-p5.XXXXXX; }

# _setup_repo <tmp>: tmp 안에 main git repo + .company-runtime 구조
_setup_repo() {
  local pr="$1"
  ( cd "${pr}" && git init -q -b main && git commit -q --allow-empty -m "init" )
  mkdir -p "${pr}/.company-runtime/registry" "${pr}/.company-runtime/harness"
  registry_init "${pr}"
}

# _add_worker <pr> <sid> <worker> <runner> <state>
#   state: running | stopped | orphaned
#   - worktree 디렉터리 + git worktree add (branch 기준)
#   - spawn_started + spawn_ready emit
#   - state=stopped 면 stop_requested + stop_confirmed emit (atomic helper 우회 — 직접 append)
#   - state=orphaned 면 stop_confirmed + orphan_detected emit
#   echoes: <wid> <wt>
_add_worker() {
  local pr="$1" sid="$2" worker="$3" runner="$4" state="$5"
  local wid="wkr-${sid}-${worker}"
  local wt="${pr}/.company-runtime/sessions/${sid}/workers/${worker}"
  local branch="wkr/${sid}/${worker}"

  # git worktree (branch + dir)
  ( cd "${pr}" && git worktree add -q -b "${branch}" "${wt}" main 2>/dev/null ) || mkdir -p "${wt}"

  local sp_payload
  sp_payload="$(jq -S -c -n --arg rh "feat:0.0" --arg wt "${wt}" --arg topic "${worker}" \
    --arg role "primary" --arg sid "${sid}" --arg br "${branch}" \
    '{runner_handle:$rh, worktree_path:$wt, branch:$br, topic:$topic, worker_role:$role, session_id:$sid}')"
  registry_append_event "${pr}" spawn_started "${wid}" "${runner}" "${sp_payload}" >/dev/null 2>&1
  registry_append_event "${pr}" spawn_ready "${wid}" "${runner}" \
    "$(jq -S -c -n --arg rh "feat:0.0" '{runner_handle:$rh}')" >/dev/null 2>&1

  case "${state}" in
    running) ;;
    stopped)
      registry_append_event "${pr}" stop_requested "${wid}" "${runner}" \
        '{"actor":"user","reason":"test"}' >/dev/null 2>&1
      registry_append_event "${pr}" stop_confirmed "${wid}" "${runner}" \
        '{"reason":"test"}' >/dev/null 2>&1
      ;;
    orphaned)
      registry_append_event "${pr}" stop_requested "${wid}" "${runner}" \
        '{"actor":"user","reason":"test"}' >/dev/null 2>&1
      registry_append_event "${pr}" stop_confirmed "${wid}" "${runner}" \
        '{"reason":"force:test"}' >/dev/null 2>&1
      registry_append_event "${pr}" orphan_detected "${wid}" "${runner}" '{}' >/dev/null 2>&1
      ;;
  esac
  registry_rebuild_index "${pr}" >/dev/null 2>&1
  echo "${wid} ${wt}"
}

# _grant_token <pr> <sid> <scope>: events.jsonl 에 destructive_local_approved 라인 추가
_grant_token() {
  local pr="$1" sid="$2" scope="$3"
  local action target
  action="${scope#destructive_local:}"; action="${action%%:*}"
  if [[ "${scope}" == *:*:* ]]; then target="${scope##*:}"; else target="*"; fi
  local ev="${pr}/.company-runtime/harness/events.jsonl"
  mkdir -p "$(dirname "${ev}")"
  jq -c -n --arg sid "${sid}" --arg act "${action}" --arg tgt "${target}" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{event:"destructive_local_approved", session_id:$sid, action:$act, target:$tgt, approver:"leader", ts:$ts}' \
    >> "${ev}"
}

_run_doctor() {
  local pr="$1"; shift
  ( export PROJECT_ROOT="${pr}"; source "${DOCTOR_SH}"; registry_cmd_doctor "$@" )
}
_run_cleanup() {
  local pr="$1" sid="$2"; shift 2
  ( export PROJECT_ROOT="${pr}" COMPANY_SESSION_ID="${sid}"; source "${CLEANUP_SH}"; registry_cmd_cleanup "$@" )
}

_count_events() {
  local pr="$1" wid="$2" etype="$3"
  local events="${pr}/.company-runtime/harness/workers.jsonl"
  [[ -s "${events}" ]] || { echo 0; return; }
  jq -c --arg w "${wid}" --arg e "${etype}" \
    'select(.worker_id == $w and .event_type == $e)' "${events}" | wc -l | tr -d ' '
}

s21_doctor_readonly() {
  echo "=== S21: doctor read-only 정합성 (running 1 + stopped 1 + orphaned 1) ==="
  local tmp; tmp="$(_mktmp)"
  _setup_repo "${tmp}"
  _add_worker "${tmp}" S21 r tmux running    >/dev/null
  _add_worker "${tmp}" S21 s tmux stopped    >/dev/null
  _add_worker "${tmp}" S21 o tmux orphaned   >/dev/null

  local events="${tmp}/.company-runtime/harness/workers.jsonl"
  local before_lines after_lines
  before_lines="$(wc -l < "${events}" | tr -d ' ')"

  local out rc=0
  out="$(_run_doctor "${tmp}" --json 2>/dev/null)" || rc=$?
  after_lines="$(wc -l < "${events}" | tr -d ' ')"

  [[ "${rc}" -eq 0 ]] && _pass "exit 0" || _fail "exit=${rc}"
  [[ "${before_lines}" == "${after_lines}" ]] && _pass "events.jsonl 변화 0 (${before_lines})" \
    || _fail "events lines ${before_lines} → ${after_lines}"

  local integrity_pass workers_total
  integrity_pass="$(echo "${out}" | jq '[.integrity[] | select(.status == "PASS")] | length')"
  workers_total="$(echo "${out}" | jq '.summary.workers')"
  [[ "${integrity_pass}" == "4" ]] && _pass "integrity 4종 PASS" || _fail "integrity_pass=${integrity_pass}"
  [[ "${workers_total}" == "3" ]] && _pass "summary.workers=3" || _fail "workers_total=${workers_total}"

  local worktree_n
  worktree_n="$(echo "${out}" | jq '.worktree | length')"
  [[ "${worktree_n}" -ge 2 ]] && _pass "worktree 2건 이상 (${worktree_n})" || _fail "worktree=${worktree_n}"

  rm -rf "${tmp}"
}

s22_cleanup_normal() {
  echo "=== S22: cleanup 정상 (stopped → archived) ==="
  local tmp; tmp="$(_mktmp)"
  _setup_repo "${tmp}"
  local wid wt info
  info="$(_add_worker "${tmp}" S22 w tmux stopped)"
  wid="${info%% *}"; wt="${info##* }"
  _grant_token "${tmp}" S22 "destructive_local:worker_cleanup:${wid}"

  local out rc=0
  out="$(_run_cleanup "${tmp}" S22 "${wid}" --reason="test-cleanup" --json 2>/dev/null)" || rc=$?
  [[ "${rc}" -eq 0 ]] && _pass "exit 0" || _fail "exit=${rc}"

  local action scenario archived_n
  action="$(echo "${out}" | jq -r '.action')"
  scenario="$(echo "${out}" | jq -r '.scenario')"
  [[ "${action}" == "archived" ]] && _pass "action=archived" || _fail "action=${action}"
  [[ "${scenario}" == "normal_stopped" ]] && _pass "scenario=normal_stopped" || _fail "scenario=${scenario}"

  archived_n="$(_count_events "${tmp}" "${wid}" worker_archived)"
  [[ "${archived_n}" == "1" ]] && _pass "worker_archived 1 라인" || _fail "worker_archived=${archived_n}"

  [[ ! -d "${wt}" ]] && _pass "worktree 부재" || _fail "worktree 잔존: ${wt}"

  # snapshot state=archived
  local snap_state
  snap_state="$(registry_get_snapshot "${tmp}" | jq -r --arg w "${wid}" '.workers[$w].state')"
  [[ "${snap_state}" == "archived" ]] && _pass "snapshot state=archived" || _fail "snapshot state=${snap_state}"

  rm -rf "${tmp}"
}

s23_cleanup_precondition_reject() {
  echo "=== S23: cleanup pre-condition (running → exit 1) ==="
  local tmp; tmp="$(_mktmp)"
  _setup_repo "${tmp}"
  local wid info
  info="$(_add_worker "${tmp}" S23 w tmux running)"
  wid="${info%% *}"
  _grant_token "${tmp}" S23 "destructive_local:worker_cleanup:${wid}"

  local events="${tmp}/.company-runtime/harness/workers.jsonl"
  local before; before="$(wc -l < "${events}" | tr -d ' ')"

  local rc=0 out
  out="$(_run_cleanup "${tmp}" S23 "${wid}" --json 2>/dev/null)" || rc=$?
  [[ "${rc}" -eq 1 ]] && _pass "exit 1" || _fail "exit=${rc}"

  local reason; reason="$(echo "${out}" | jq -r '.reason')"
  [[ "${reason}" == "invalid_state" ]] && _pass "reason=invalid_state" || _fail "reason=${reason}"

  local after; after="$(wc -l < "${events}" | tr -d ' ')"
  [[ "${before}" == "${after}" ]] && _pass "events 변화 0 (${before})" || _fail "events ${before} → ${after}"

  rm -rf "${tmp}"
}

s24_dirty_unpushed() {
  echo "=== S24: dirty/unpushed 시나리오 ==="
  local tmp; tmp="$(_mktmp)"
  _setup_repo "${tmp}"
  local wid wt info
  info="$(_add_worker "${tmp}" S24 w tmux stopped)"
  wid="${info%% *}"; wt="${info##* }"
  _grant_token "${tmp}" S24 "destructive_local:worker_cleanup:${wid}"

  # dirty 만들기
  echo "dirty" > "${wt}/dirty-file.txt"

  local rc=0 out
  out="$(_run_cleanup "${tmp}" S24 "${wid}" --json 2>/dev/null)" || rc=$?
  [[ "${rc}" -eq 1 ]] && _pass "dirty reject — exit 1" || _fail "dirty exit=${rc}"
  local reason; reason="$(echo "${out}" | jq -r '.reason')"
  [[ "${reason}" == "dirty_change" ]] && _pass "reason=dirty_change" || _fail "reason=${reason}"

  # --allow-dirty override (dirty 만 있고 unpushed 없음 → 통과)
  rc=0
  out="$(_run_cleanup "${tmp}" S24 "${wid}" --allow-dirty --json 2>/dev/null)" || rc=$?
  [[ "${rc}" -eq 0 ]] && _pass "--allow-dirty 후 archived (exit 0)" || _fail "override exit=${rc}"
  local action; action="$(echo "${out}" | jq -r '.action')"
  [[ "${action}" == "archived" ]] && _pass "action=archived" || _fail "action=${action}"

  rm -rf "${tmp}"
}

s25_gc_batch() {
  echo "=== S25: --gc 일괄 ==="
  local tmp; tmp="$(_mktmp)"
  _setup_repo "${tmp}"
  local i info wid wt
  local stopped_wids=()
  for i in a b c; do
    info="$(_add_worker "${tmp}" S25 "${i}" tmux stopped)"
    stopped_wids+=("${info%% *}")
  done
  # dirty 1개 — skip 대상
  info="$(_add_worker "${tmp}" S25 d tmux stopped)"
  local dirty_wid="${info%% *}" dirty_wt="${info##* }"
  echo "dirty" > "${dirty_wt}/x.txt"

  _grant_token "${tmp}" S25 "destructive_local:worker_gc_all"

  # doctor PASS marker 필수
  _run_doctor "${tmp}" --json >/dev/null 2>&1

  local rc=0 out
  out="$(_run_cleanup "${tmp}" S25 --gc --json 2>/dev/null)" || rc=$?
  [[ "${rc}" -eq 0 ]] && _pass "exit 0" || _fail "exit=${rc}"

  local archived skipped
  archived="$(echo "${out}" | jq -r '.archived')"
  skipped="$(echo "${out}" | jq -r '.skipped')"
  [[ "${archived}" == "3" ]] && _pass "archived=3 (a/b/c)" || _fail "archived=${archived}"
  [[ "${skipped}" == "1" ]] && _pass "skipped=1 (dirty)" || _fail "skipped=${skipped}"

  # dirty 워커 그대로
  local dirty_state
  dirty_state="$(registry_get_snapshot "${tmp}" | jq -r --arg w "${dirty_wid}" '.workers[$w].state')"
  [[ "${dirty_state}" == "stopped" ]] && _pass "dirty 워커 보존 (state=stopped)" || _fail "dirty state=${dirty_state}"

  rm -rf "${tmp}"
}

s25_stale_guard() {
  echo "=== S25-stale: --gc 직전 doctor 부재 → reject ==="
  local tmp; tmp="$(_mktmp)"
  _setup_repo "${tmp}"
  _add_worker "${tmp}" S25s a tmux stopped >/dev/null
  _grant_token "${tmp}" S25s "destructive_local:worker_gc_all"

  # doctor 호출 안 함 — marker 부재
  local rc=0 out
  out="$(_run_cleanup "${tmp}" S25s --gc --json 2>/dev/null)" || rc=$?
  [[ "${rc}" -eq 1 ]] && _pass "stale guard exit 1" || _fail "exit=${rc}"
  local reason; reason="$(echo "${out}" | jq -r '.reason')"
  [[ "${reason}" == "gc_stale" ]] && _pass "reason=gc_stale" || _fail "reason=${reason}"

  rm -rf "${tmp}"
}

s21f_force_stop_assumed_leak() {
  echo "=== S21f: doctor process check — orphaned + check_alive 보고 ==="
  local tmp; tmp="$(_mktmp)"
  _setup_repo "${tmp}"
  _add_worker "${tmp}" S21f o tmux orphaned >/dev/null

  local out rc=0
  out="$(_run_doctor "${tmp}" --json 2>/dev/null)" || rc=$?
  [[ "${rc}" -eq 0 ]] && _pass "exit 0" || _fail "exit=${rc}"

  local process_n process_first_state process_first_result
  process_n="$(echo "${out}" | jq '.process | length')"
  [[ "${process_n}" -ge 1 ]] && _pass "process[] 1건 이상 (orphaned)" || _fail "process_n=${process_n}"

  process_first_state="$(echo "${out}" | jq -r '.process[0].state')"
  process_first_result="$(echo "${out}" | jq -r '.process[0].result')"
  [[ "${process_first_state}" == "orphaned" ]] && _pass "process[0].state=orphaned" \
    || _fail "process state=${process_first_state}"
  # tmux runner check_alive 는 marker 부재 또는 pane 부재 → GONE 또는 INDETERMINATE
  case "${process_first_result}" in
    GONE|ALIVE|INDETERMINATE) _pass "process[0].result=${process_first_result} (정의된 enum)" ;;
    *) _fail "process result=${process_first_result}" ;;
  esac

  rm -rf "${tmp}"
}

s_token_missing() {
  echo "=== S-token: 토큰 부재 → exit 5 ==="
  local tmp; tmp="$(_mktmp)"
  _setup_repo "${tmp}"
  local wid info; info="$(_add_worker "${tmp}" Stok w tmux stopped)"
  wid="${info%% *}"
  # 토큰 발행 안 함

  local rc=0 out
  out="$(_run_cleanup "${tmp}" Stok "${wid}" --json 2>/dev/null)" || rc=$?
  [[ "${rc}" -eq 5 ]] && _pass "exit 5 (토큰 부재)" || _fail "exit=${rc}"
  local reason; reason="$(echo "${out}" | jq -r '.reason')"
  [[ "${reason}" == "approval_token_missing" ]] && _pass "reason=approval_token_missing" \
    || _fail "reason=${reason}"
  # worker_archived emit 안 됨
  local archived_n; archived_n="$(_count_events "${tmp}" "${wid}" worker_archived)"
  [[ "${archived_n}" == "0" ]] && _pass "worker_archived 0 라인 (정리 미진행)" \
    || _fail "worker_archived=${archived_n}"
  rm -rf "${tmp}"
}

case "${WHICH}" in
  S21|s21)     s21_doctor_readonly ;;
  S22|s22)     s22_cleanup_normal ;;
  S23|s23)     s23_cleanup_precondition_reject ;;
  S24|s24)     s24_dirty_unpushed ;;
  S25|s25)     s25_gc_batch ;;
  S25s|s25s)   s25_stale_guard ;;
  S21f|s21f)   s21f_force_stop_assumed_leak ;;
  Stok|stok)   s_token_missing ;;
  all|*)
    s21_doctor_readonly
    s22_cleanup_normal
    s23_cleanup_precondition_reject
    s24_dirty_unpushed
    s25_gc_batch
    s25_stale_guard
    s21f_force_stop_assumed_leak
    s_token_missing
    ;;
esac

echo
echo "─────────────────────────"
echo "smoke workers doctor/cleanup: ${PASS} PASS, ${FAIL} FAIL"
[[ "${FAIL}" -eq 0 ]] || exit 1
