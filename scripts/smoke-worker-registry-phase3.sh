#!/usr/bin/env bash
# scripts/smoke-worker-registry-phase3.sh
#
# Phase 3 smoke for worker-registry (S10~S12).
#
# 결정문: docs/decisions/2026-05-13-worker-registry-phase3.md v0.2 D7
#
# 시나리오:
#   S10: 4종 runner 워커 1개씩 spawn → company workers list (table + --json + 필터)
#   S11: workers status <wid> (존재/비존재 + recent_events + --json)
#   S12: workers logs <wid> (isolation + --event 필터 + --tail/--all/--json)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/worker-registry-lib.sh"
PRINT="${SCRIPT_DIR}/worker-registry-print.sh"

[[ -f "${LIB}" ]]   || { echo "smoke: worker-registry-lib.sh missing"   >&2; exit 2; }
[[ -f "${PRINT}" ]] || { echo "smoke: worker-registry-print.sh missing" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "smoke: jq required" >&2; exit 2; }

# lib + print 모두 source (print 가 lib 을 idempotent source).
# print 는 PROJECT_ROOT 를 함수 호출 시점에 참조하므로 시나리오마다 override.
source "${LIB}"
# shellcheck disable=SC1090
source "${PRINT}"

set +e  # 비 0 return 검증을 위해 -e 끄기

PASS=0
FAIL=0
WHICH="${1:-all}"

_pass() { echo "  PASS: $*"; PASS=$(( PASS + 1 )); }
_fail() { echo "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }
_mktmp() { mktemp -d -t reg-phase3.XXXXXX; }

_register() {
  local pr="$1" sid="$2" worker="$3" runner="$4" rh="$5"
  registry_init "${pr}"
  local wid="wkr-${sid}-${worker}"
  local wt="${pr}/.company-runtime/sessions/${sid}/workers/${worker}"
  mkdir -p "${wt}"
  local payload
  payload="$(jq -S -c -n --arg rh "${rh}" --arg wt "${wt}" --arg topic "${worker} topic" --arg role "primary" --arg sid "${sid}" \
    '{runner_handle:$rh, worktree_path:$wt, branch:null, topic:$topic, worker_role:$role, session_id:$sid}')"
  registry_append_event "${pr}" spawn_started "${wid}" "${runner}" "${payload}" >/dev/null 2>&1
  registry_append_event "${pr}" spawn_ready   "${wid}" "${runner}" \
    "$(jq -S -c -n --arg rh "${rh}" '{runner_handle:$rh}')" >/dev/null 2>&1
}

s10_list() {
  echo "=== S10: company workers list (4 runner 동시 등록) ==="
  local tmp; tmp="$(_mktmp)"
  _register "${tmp}" "S10seq"  "planner"  sequential "inline:S10seq"
  _register "${tmp}" "S10tmx"  "executor" tmux       "feat-x:0.0"
  _register "${tmp}" "S10cmx"  "reviewer" cmux       "surface:abc123"
  _register "${tmp}" "S10man"  "scribe"   manual     "marker:${tmp}/m.txt"

  export PROJECT_ROOT="${tmp}"

  # table 출력
  local out; out="$(registry_print_list 2>/dev/null)"
  local n_workers
  n_workers="$(echo "${out}" | grep -cE '^wkr-')"
  [[ "${n_workers}" -eq 4 ]] && _pass "table 에 4 워커 출력" || _fail "table 워커 라인=${n_workers}"

  echo "${out}" | grep -q "4 worker(s)" && _pass "summary line 정상" || _fail "summary line 누락"

  # --json
  local arr; arr="$(registry_print_list --json 2>/dev/null)"
  local arr_len
  arr_len="$(echo "${arr}" | jq 'length')"
  [[ "${arr_len}" -eq 4 ]] && _pass "--json array length=4" || _fail "--json length=${arr_len}"

  # --state 필터 (4종 모두 spawn_ready 후 running 상태)
  local running; running="$(registry_print_list --state=running --json 2>/dev/null | jq 'length')"
  [[ "${running}" -eq 4 ]] && _pass "--state=running 필터 매치 4" || _fail "--state=running matched=${running}"

  # --runner 필터
  local cmux_only; cmux_only="$(registry_print_list --runner=cmux --json 2>/dev/null | jq 'length')"
  [[ "${cmux_only}" -eq 1 ]] && _pass "--runner=cmux 필터 매치 1" || _fail "--runner=cmux matched=${cmux_only}"

  # --session 필터 (substring 아님 — 정확 일치)
  local sess1; sess1="$(registry_print_list --session=S10seq --json 2>/dev/null | jq 'length')"
  [[ "${sess1}" -eq 1 ]] && _pass "--session=S10seq 정확 일치 1" || _fail "--session=S10seq matched=${sess1}"

  # 복합 필터 AND
  local combo; combo="$(registry_print_list --state=running --runner=cmux --json 2>/dev/null | jq 'length')"
  [[ "${combo}" -eq 1 ]] && _pass "복합 필터 AND 1" || _fail "복합 AND matched=${combo}"

  # 비매치 — 0건 안내
  local none_out; none_out="$(registry_print_list --runner=nonexistent 2>/dev/null)"
  echo "${none_out}" | grep -q "No workers" && _pass "0건 매치 시 No workers 안내" || _fail "0건 안내 누락"

  # schema 정합 (필드 6종 + record 키 집합)
  local has_keys; has_keys="$(echo "${arr}" | jq -e '.[0] | (has("worker_id") and has("runner") and has("state") and has("session_id") and has("topic") and has("started_at") and has("schema_version"))')"
  [[ "${has_keys}" == "true" ]] && _pass "--json record key 집합 정합" || _fail "--json record key 누락"

  rm -rf "${tmp}"
  unset PROJECT_ROOT
}

s11_status() {
  echo "=== S11: company workers status <wid> ==="
  local tmp; tmp="$(_mktmp)"
  _register "${tmp}" "S11" "primary" cmux "surface:xyz"
  export PROJECT_ROOT="${tmp}"

  # 존재
  local out; out="$(registry_print_status "wkr-S11-primary" 2>/dev/null)"
  echo "${out}" | grep -q "^Worker:        wkr-S11-primary$" && _pass "Worker 라인" || _fail "Worker 라인 누락"
  echo "${out}" | grep -q "^Runner:        cmux$"            && _pass "Runner 라인" || _fail "Runner 라인 누락"
  echo "${out}" | grep -q "^State:         running$"         && _pass "State 라인"  || _fail "State 라인 ${out}"
  echo "${out}" | grep -q "^Recent events" && _pass "Recent events 헤더" || _fail "Recent events 헤더 누락"

  # --json
  local rec; rec="$(registry_print_status "wkr-S11-primary" --json 2>/dev/null)"
  local has; has="$(echo "${rec}" | jq -e 'has("recent_events") and (.recent_events | length) > 0 and has("state")')"
  [[ "${has}" == "true" ]] && _pass "--json 에 recent_events 포함" || _fail "--json recent_events 누락"

  # 비존재
  registry_print_status "wkr-S11-nope" >/dev/null 2>&1
  local rc=$?
  [[ "${rc}" -eq 1 ]] && _pass "비존재 wid → exit 1" || _fail "비존재 exit=${rc}"

  # --json + 비존재 → null
  local null_out; null_out="$(registry_print_status "wkr-S11-nope" --json 2>/dev/null)"
  [[ "${null_out}" == "null" ]] && _pass "비존재 --json → null" || _fail "비존재 --json=${null_out}"

  # --events=2 제한
  local rec2; rec2="$(registry_print_status "wkr-S11-primary" --events=2 --json 2>/dev/null)"
  local re_len; re_len="$(echo "${rec2}" | jq '.recent_events | length')"
  (( re_len <= 2 )) && _pass "--events=2 → 최대 2 라인" || _fail "--events=2 → ${re_len}"

  rm -rf "${tmp}"
  unset PROJECT_ROOT
}

s12_logs() {
  echo "=== S12: company workers logs <wid> (isolation + 필터) ==="
  local tmp; tmp="$(_mktmp)"
  _register "${tmp}" "S12" "alpha" sequential "inline:S12a"
  _register "${tmp}" "S12" "beta"  sequential "inline:S12b"
  # alpha 에만 추가 event
  registry_append_event "${tmp}" plan_emitted "wkr-S12-alpha" sequential \
    "$(jq -S -c -n --arg p "${tmp}/cp.md" '{plan_path:$p}')" >/dev/null 2>&1

  export PROJECT_ROOT="${tmp}"

  # default tail — alpha 만 (isolation)
  local out; out="$(registry_print_logs "wkr-S12-alpha" 2>/dev/null)"
  local n; n="$(echo "${out}" | grep -c "spawn_started\|spawn_ready\|plan_emitted")"
  [[ "${n}" -eq 3 ]] && _pass "alpha event 3 라인 (spawn_started+ready+plan)" || _fail "alpha 라인=${n}"
  echo "${out}" | grep -q "beta" && _fail "isolation 깨짐 — beta 누설" || _pass "isolation: beta 누설 0"

  # --event 필터
  local plan_only; plan_only="$(registry_print_logs "wkr-S12-alpha" --event=plan_emitted 2>/dev/null)"
  local n2; n2="$(echo "${plan_only}" | grep -c "plan_emitted")"
  [[ "${n2}" -eq 1 ]] && _pass "--event=plan_emitted 1 라인" || _fail "--event filter=${n2}"

  # --json array
  local arr; arr="$(registry_print_logs "wkr-S12-alpha" --json 2>/dev/null)"
  local arr_len; arr_len="$(echo "${arr}" | jq 'length')"
  [[ "${arr_len}" -eq 3 ]] && _pass "--json array length=3" || _fail "--json length=${arr_len}"

  # --tail=1 (가장 최근 = plan_emitted)
  local one; one="$(registry_print_logs "wkr-S12-alpha" --tail=1 --json 2>/dev/null | jq -r '.[0].event_type')"
  [[ "${one}" == "plan_emitted" ]] && _pass "--tail=1 = 최신 plan_emitted" || _fail "--tail=1 = ${one}"

  # --all
  local all_lines; all_lines="$(registry_print_logs "wkr-S12-alpha" --all 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${all_lines}" -eq 3 ]] && _pass "--all = 3 라인" || _fail "--all = ${all_lines}"

  # --event 비매치 라인 → 0건 안내 stderr (stdout 빈)
  local nothing; nothing="$(registry_print_logs "wkr-S12-alpha" --event=spawn_failure 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${nothing}" -eq 0 ]] && _pass "--event 비매치 stdout 0 라인" || _fail "비매치 stdout=${nothing}"

  rm -rf "${tmp}"
  unset PROJECT_ROOT
}

case "${WHICH}" in
  all) s10_list; s11_status; s12_logs ;;
  s10) s10_list ;;
  s11) s11_status ;;
  s12) s12_logs ;;
  *)   echo "usage: $0 [all|s10|s11|s12]" >&2; exit 2 ;;
esac

echo
echo "─────────────────────────"
echo "smoke worker-registry phase3: ${PASS} PASS, ${FAIL} FAIL"
[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0
