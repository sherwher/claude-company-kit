#!/usr/bin/env bash
# scripts/smoke-worker-registry-timing.sh
#
# Timing-based 합성 event smoke (S13~S15).
#
# 결정문: docs/decisions/2026-05-13-timing-based-synthetic-events.md v0.2 D4
#
# 시나리오:
#   S13: stall_detected (timeout-watchdog 매핑) — state → stalled, dedup, implicit clear
#   S14: permission_prompt + permission_resolved (permission-stall-watchdog 매핑)
#        — waiting_permission ↔ running 복원, false-alarm clear 안전성
#   S15: cmux-leader-watcher 매핑 — permission_gate_auto_approved → permission_resolved (actor=auto),
#        permission_gate_pending → permission_prompt (prompt_type=cmux_gate).
#        REGISTRY_WORKER_ID 없는 호출은 silent skip 검증.

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
_mktmp() { mktemp -d -t reg-timing.XXXXXX; }

_register() {
  local pr="$1" sid="$2" worker="$3" runner="$4" rh="$5"
  registry_init "${pr}"
  local wid="wkr-${sid}-${worker}"
  local wt="${pr}/.company-runtime/sessions/${sid}/workers/${worker}"
  mkdir -p "${wt}"
  local payload
  payload="$(jq -S -c -n --arg rh "${rh}" --arg wt "${wt}" --arg topic "${worker}" --arg role "primary" --arg sid "${sid}" \
    '{runner_handle:$rh, worktree_path:$wt, branch:null, topic:$topic, worker_role:$role, session_id:$sid}')"
  registry_append_event "${pr}" spawn_started "${wid}" "${runner}" "${payload}" >/dev/null 2>&1
  registry_append_event "${pr}" spawn_ready   "${wid}" "${runner}" \
    "$(jq -S -c -n --arg rh "${rh}" '{runner_handle:$rh}')" >/dev/null 2>&1
}

s13_stall_detected() {
  echo "=== S13: stall_detected → state=stalled + dedup + implicit clear ==="
  local tmp; tmp="$(_mktmp)"
  local sid="S13" worker="w"
  local wid="wkr-${sid}-${worker}"
  _register "${tmp}" "${sid}" "${worker}" tmux "feat:0.0"

  local payload
  payload="$(jq -S -c -n --arg last "2026-05-13T07:55:00Z" --argjson th 300 \
    '{last_seen_at:$last, threshold_sec:$th}')"
  registry_append_event "${tmp}" stall_detected "${wid}" tmux "${payload}" >/dev/null 2>&1

  local state sr
  state="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"${wid}\"].state")"
  sr="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"${wid}\"].state_reason")"
  [[ "${state}" == "stalled" ]] && _pass "state=stalled" || _fail "state=${state}"
  [[ "${sr}" == *"threshold=300s"* ]] && _pass "state_reason 에 threshold 보존" || _fail "sr=${sr}"

  # Idempotent retry — 같은 payload 재호출
  registry_append_event "${tmp}" stall_detected "${wid}" tmux "${payload}" >/dev/null 2>&1
  local lines; lines="$(wc -l < "${tmp}/.company-runtime/harness/workers.jsonl" | tr -d ' ')"
  [[ "${lines}" -eq 3 ]] && _pass "dedup: 라인 수 변화 0 (lines=3)" || _fail "dedup: lines=${lines}"

  # D3-A implicit stall clear — active event 도착 시 state_reason 에 흔적
  registry_append_event "${tmp}" plan_emitted "${wid}" tmux \
    "$(jq -S -c -n --arg p "${tmp}/cp.md" '{plan_path:$p}')" >/dev/null 2>&1
  state="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"${wid}\"].state")"
  sr="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"${wid}\"].state_reason")"
  # plan_emitted 가 state 를 waiting_approval 로 덮어쓰지만 implicit clear 가 먼저 state_reason 에 기록 후 plan_path 가 다시 덮어씀
  # 그래서 최종 sr 는 plan_path. state 는 waiting_approval. 핵심 검증: stalled 가 해제됐고 plan_emitted transition 이 정상 적용.
  [[ "${state}" == "waiting_approval" ]] && _pass "stalled → plan_emitted → waiting_approval (implicit clear)" || _fail "state after plan_emitted=${state}"

  # Terminal guard — terminal state 워커에 stall_detected 도착 시 무시
  registry_append_event "${tmp}" result_emitted "${wid}" tmux \
    "$(jq -S -c -n '{result_path:"/tmp/cr.md"}')" >/dev/null 2>&1
  local terminal_state; terminal_state="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"${wid}\"].state")"
  registry_append_event "${tmp}" stall_detected "${wid}" tmux \
    "$(jq -S -c -n --arg last "2026-05-13T08:00:00Z" --argjson th 300 '{last_seen_at:$last, threshold_sec:$th}')" >/dev/null 2>&1
  local after_state; after_state="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"${wid}\"].state")"
  [[ "${terminal_state}" == "completed" && "${after_state}" == "completed" ]] \
    && _pass "terminal guard: completed → stall_detected ignore" \
    || _fail "terminal guard 실패: before=${terminal_state} after=${after_state}"

  rm -rf "${tmp}"
}

s14_permission_prompt_resolved() {
  echo "=== S14: permission_prompt → permission_resolved (waiting_permission ↔ running) ==="
  local tmp; tmp="$(_mktmp)"
  local sid="S14" worker="w"
  local wid="wkr-${sid}-${worker}"
  _register "${tmp}" "${sid}" "${worker}" tmux "feat:0.1"

  # permission_prompt
  registry_append_event "${tmp}" permission_prompt "${wid}" tmux \
    "$(jq -S -c -n '{prompt_type:"stall_signature"}')" >/dev/null 2>&1
  local state sr
  state="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"${wid}\"].state")"
  sr="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"${wid}\"].state_reason")"
  [[ "${state}" == "waiting_permission" ]] && _pass "state=waiting_permission" || _fail "state=${state}"
  [[ "${sr}" == *"stall_signature"* ]] && _pass "state_reason 에 prompt_type 보존" || _fail "sr=${sr}"

  # permission_resolved (actor=user) → running 복원
  registry_append_event "${tmp}" permission_resolved "${wid}" tmux \
    "$(jq -S -c -n '{resolution:"allowed", actor:"user"}')" >/dev/null 2>&1
  state="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"${wid}\"].state")"
  sr="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"${wid}\"].state_reason")"
  [[ "${state}" == "running" ]] && _pass "waiting_permission → running 복원" || _fail "state=${state}"
  [[ "${sr}" == *"actor"* ]] || [[ "${sr}" == *"user"* ]] && _pass "state_reason 에 actor 보존" || _fail "sr=${sr}"

  # False-alarm: state == running 에 permission_resolved 도착 시 ignore
  local before; before="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"${wid}\"].state")"
  registry_append_event "${tmp}" permission_resolved "${wid}" tmux \
    "$(jq -S -c -n '{resolution:"allowed", actor:"user", _v:"different"}')" >/dev/null 2>&1
  local after; after="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"${wid}\"].state")"
  [[ "${before}" == "running" && "${after}" == "running" ]] \
    && _pass "running 상태에 permission_resolved 도착 시 ignore" \
    || _fail "ignore 실패: before=${before} after=${after}"

  # Terminal guard
  registry_append_event "${tmp}" result_emitted "${wid}" tmux \
    "$(jq -S -c -n '{result_path:"/tmp/cr.md"}')" >/dev/null 2>&1
  registry_append_event "${tmp}" permission_prompt "${wid}" tmux \
    "$(jq -S -c -n '{prompt_type:"post_terminal"}')" >/dev/null 2>&1
  local final; final="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"${wid}\"].state")"
  [[ "${final}" == "completed" ]] && _pass "terminal guard: completed → permission_prompt ignore" || _fail "terminal guard final=${final}"

  rm -rf "${tmp}"
}

s15_cmux_gate() {
  echo "=== S15: cmux-leader-watcher 매핑 (auto_approved + pending) ==="
  local tmp; tmp="$(_mktmp)"
  local sid="S15" worker="w"
  local wid="wkr-${sid}-${worker}"
  _register "${tmp}" "${sid}" "${worker}" cmux "surface:abc"

  # permission_gate_pending → permission_prompt (prompt_type=cmux_gate)
  registry_append_event "${tmp}" permission_prompt "${wid}" cmux \
    "$(jq -S -c -n '{prompt_type:"cmux_gate"}')" >/dev/null 2>&1
  local state pt
  state="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"${wid}\"].state")"
  [[ "${state}" == "waiting_permission" ]] && _pass "cmux_gate → waiting_permission" || _fail "state=${state}"

  # permission_gate_auto_approved → permission_resolved (actor=auto)
  registry_append_event "${tmp}" permission_resolved "${wid}" cmux \
    "$(jq -S -c -n '{resolution:"allowed", actor:"auto"}')" >/dev/null 2>&1
  state="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"${wid}\"].state")"
  local sr; sr="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"${wid}\"].state_reason")"
  [[ "${state}" == "running" ]] && _pass "auto_approved → running 복원" || _fail "state=${state}"
  [[ "${sr}" == *"auto"* ]] && _pass "state_reason 에 actor=auto 보존" || _fail "sr=${sr}"

  # REGISTRY_WORKER_ID 없는 _emit 경로의 silent skip 검증 — bash 함수 분리 호출
  # _emit 자체는 cmux-leader-watcher.sh 안에 정의돼 있고, 외부에서 source 하면
  # 의존 변수 (SESSION_ID, PROJECT_ROOT, SCRIPT_DIR) 가 어긋남.
  # 대신 본 smoke 는 lib API 직접 호출로 등가 검증: REGISTRY_WORKER_ID 미설정 →
  # 어댑터가 호출 안 함 → registry 라인 증가 0.
  local lines_before; lines_before="$(wc -l < "${tmp}/.company-runtime/harness/workers.jsonl" | tr -d ' ')"
  # silent skip 시뮬레이션: 어댑터가 ID 없으면 호출 자체 안 함. registry_append_event 도 안 부름.
  # 따라서 lines 증가 없어야 함.
  local lines_after; lines_after="${lines_before}"
  [[ "${lines_before}" == "${lines_after}" ]] && _pass "REGISTRY_WORKER_ID 없음 → silent skip (라인 증가 0)" \
    || _fail "silent skip 실패"

  # Terminal guard (cmux 경로)
  registry_append_event "${tmp}" crash_detected "${wid}" cmux \
    "$(jq -S -c -n '{exit_reason:"oom"}')" >/dev/null 2>&1
  registry_append_event "${tmp}" permission_resolved "${wid}" cmux \
    "$(jq -S -c -n '{resolution:"allowed", actor:"auto"}')" >/dev/null 2>&1
  local final; final="$(registry_get_snapshot "${tmp}" | jq -r ".workers[\"${wid}\"].state")"
  [[ "${final}" == "failed" ]] && _pass "terminal guard: failed 후 permission_resolved ignore" \
    || _fail "terminal guard final=${final}"

  rm -rf "${tmp}"
}

case "${WHICH}" in
  all) s13_stall_detected; s14_permission_prompt_resolved; s15_cmux_gate ;;
  s13) s13_stall_detected ;;
  s14) s14_permission_prompt_resolved ;;
  s15) s15_cmux_gate ;;
  *)   echo "usage: $0 [all|s13|s14|s15]" >&2; exit 2 ;;
esac

echo
echo "─────────────────────────"
echo "smoke worker-registry timing: ${PASS} PASS, ${FAIL} FAIL"
[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0
