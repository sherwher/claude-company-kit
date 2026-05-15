#!/usr/bin/env bash
# scripts/smoke-worker-registry.sh
#
# Phase 1 smoke for worker-registry-lib.sh (S1~S4).
#
# 결정문: docs/decisions/2026-05-12-worker-registry-phase1.md v0.3 D5/D6
# 실측 시점: 2026-05-12
#
# 시나리오:
#   S1: sequential spawn → registry 에 spawn_started + spawn_ready 기록
#   S2: idempotent ignore + conflicting hard fail + replay idempotency
#   S3: 5건 동시 emit (mkdir lockdir 경합) — 누락 0건, 평균 <100ms, 최대 <500ms
#   S4: stale lock recovery (STALE_LOCK_SEC=2 override)
#
# 사용:
#   bash scripts/smoke-worker-registry.sh           # 전체 실행
#   bash scripts/smoke-worker-registry.sh s3        # 단일 시나리오만

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/worker-registry-lib.sh"

if [[ ! -f "${LIB}" ]]; then
  echo "smoke: worker-registry-lib.sh not found at ${LIB}" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "smoke: jq required (Phase 1 hard dependency)" >&2
  exit 2
fi

# shellcheck source=./worker-registry-lib.sh
source "${LIB}"

PASS=0
FAIL=0
WHICH="${1:-all}"

_pass() { echo "  PASS: $*"; PASS=$(( PASS + 1 )); }
_fail() { echo "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }

_mktmp() {
  local d
  d="$(mktemp -d -t reg-smoke.XXXXXX)"
  echo "${d}"
}

# ─────────────────────────────────────────────────────────────────────────────
# S1: spawn 기록
# ─────────────────────────────────────────────────────────────────────────────
s1_spawn_record() {
  echo "=== S1: spawn_started + spawn_ready 기록 ==="
  local tmp; tmp="$(_mktmp)"
  registry_init "${tmp}"

  registry_append_event "${tmp}" spawn_started "wkr-s1-fe" sequential \
    "$(jq -c -n --arg rh "inline:s1" --arg wt "${tmp}" --arg topic "t" --arg role "primary" --arg sid "s1" \
       '{runner_handle:$rh,worktree_path:$wt,branch:null,topic:$topic,worker_role:$role,session_id:$sid}')" >/dev/null

  registry_append_event "${tmp}" spawn_ready "wkr-s1-fe" sequential \
    "$(jq -c -n --arg rh "inline:s1" '{runner_handle:$rh}')" >/dev/null

  local lines state
  lines="$(wc -l < "${tmp}/.company-runtime/harness/workers.jsonl")"
  state="$(registry_get_snapshot "${tmp}" | jq -r '.workers["wkr-s1-fe"].state')"

  [[ "${lines}" -eq 2 ]] && _pass "events.jsonl 2 라인 기록" || _fail "events.jsonl ${lines} 라인 (expect 2)"
  [[ "${state}" == "running" ]] && _pass "snapshot state=running" || _fail "snapshot state=${state} (expect running)"

  rm -rf "${tmp}"
}

# ─────────────────────────────────────────────────────────────────────────────
# S2: idempotent + conflicting + replay idempotency
# ─────────────────────────────────────────────────────────────────────────────
s2_idempotency() {
  echo "=== S2: idempotent ignore + conflicting hard fail + replay idempotency ==="
  local tmp; tmp="$(_mktmp)"
  registry_init "${tmp}"

  local payload
  payload="$(jq -c -n --arg rh "inline:s2" --arg wt "${tmp}" --arg topic "t" --arg role "primary" --arg sid "s2" \
       '{runner_handle:$rh,worktree_path:$wt,branch:null,topic:$topic,worker_role:$role,session_id:$sid}')"

  registry_append_event "${tmp}" spawn_started "wkr-s2-be" sequential "${payload}" >/dev/null

  # idempotent retry — 같은 payload
  if registry_append_event "${tmp}" spawn_started "wkr-s2-be" sequential "${payload}" 2>/dev/null; then
    local lines; lines="$(wc -l < "${tmp}/.company-runtime/harness/workers.jsonl")"
    [[ "${lines}" -eq 1 ]] && _pass "idempotent retry no-op (lines=1)" || _fail "idempotent retry duplicated (lines=${lines})"
  else
    _fail "idempotent retry returned non-zero"
  fi

  # conflicting — worktree_path 다름
  local conflicting
  conflicting="$(jq -c -n --arg rh "inline:s2" --arg wt "/tmp/DIFFERENT" --arg topic "t" --arg role "primary" --arg sid "s2" \
       '{runner_handle:$rh,worktree_path:$wt,branch:null,topic:$topic,worker_role:$role,session_id:$sid}')"
  if registry_append_event "${tmp}" spawn_started "wkr-s2-be" sequential "${conflicting}" 2>/dev/null; then
    _fail "conflicting payload accepted (expected hard fail)"
  else
    _pass "conflicting payload hard fail"
  fi

  # replay idempotency
  local h1 h2
  h1="$(registry_get_snapshot "${tmp}" | shasum | awk '{print $1}')"
  rm -f "${tmp}/.company-runtime/harness/workers.idx.json"
  h2="$(registry_get_snapshot "${tmp}" | shasum | awk '{print $1}')"
  [[ "${h1}" == "${h2}" ]] && _pass "replay idempotent (hash 동일)" || _fail "replay hash drift (${h1} vs ${h2})"

  rm -rf "${tmp}"
}

# ─────────────────────────────────────────────────────────────────────────────
# S3: 5건 동시 emit
# ─────────────────────────────────────────────────────────────────────────────
s3_lock_contention() {
  echo "=== S3: 5건 동시 emit (mkdir lockdir 경합) ==="
  local tmp; tmp="$(_mktmp)"
  registry_init "${tmp}"

  local start_ns end_ns elapsed_ms avg_ms
  if start_ns="$(date +%s%N 2>/dev/null)" && [[ "${start_ns}" != *N ]]; then :; else
    start_ns="$(python3 -c 'import time;print(int(time.time()*1e9))' 2>/dev/null || echo 0)"
  fi

  local i
  for i in 1 2 3 4 5; do
    (
      registry_append_event "${tmp}" spawn_started "wkr-s3-w${i}" sequential \
        "$(jq -c -n --arg rh "inline:s${i}" --arg wt "/tmp/${i}" --arg topic "t" --arg role "primary" --arg sid "s${i}" \
           '{runner_handle:$rh,worktree_path:$wt,branch:null,topic:$topic,worker_role:$role,session_id:$sid}')" >/dev/null 2>&1
    ) &
  done
  wait

  if end_ns="$(date +%s%N 2>/dev/null)" && [[ "${end_ns}" != *N ]]; then :; else
    end_ns="$(python3 -c 'import time;print(int(time.time()*1e9))' 2>/dev/null || echo 0)"
  fi

  elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
  avg_ms=$(( elapsed_ms / 5 ))

  local lines; lines="$(wc -l < "${tmp}/.company-runtime/harness/workers.jsonl")"
  [[ "${lines}" -eq 5 ]] && _pass "5건 모두 기록 (누락 0건)" || _fail "기록 ${lines} 라인 (expect 5)"

  if [[ "${avg_ms}" -lt 100 ]]; then
    _pass "평균 lock <100ms (실측: ${avg_ms}ms)"
  else
    _fail "평균 lock ${avg_ms}ms >= 100ms"
  fi

  if [[ "${elapsed_ms}" -lt 500 ]]; then
    _pass "최대 lock <500ms (총 elapsed: ${elapsed_ms}ms)"
  else
    _fail "총 elapsed ${elapsed_ms}ms >= 500ms"
  fi

  rm -rf "${tmp}"
}

# ─────────────────────────────────────────────────────────────────────────────
# S4: stale lock recovery
# ─────────────────────────────────────────────────────────────────────────────
s4_stale_recovery() {
  echo "=== S4: stale lock recovery (STALE_LOCK_SEC=2 override) ==="
  local tmp; tmp="$(_mktmp)"
  registry_init "${tmp}"

  # 인위적 stale lock — 디렉터리만 만들어두고 buffer
  mkdir "${tmp}/.company-runtime/harness/workers.lock"

  # mtime 을 충분히 과거로 (5초 전)
  sleep 3

  local t0 t1 elapsed
  t0="$(date +%s)"
  STALE_LOCK_SEC=2 registry_append_event "${tmp}" spawn_started "wkr-s4-x" sequential \
    "$(jq -c -n --arg rh "inline:s4" --arg wt "${tmp}" --arg topic "t" --arg role "primary" --arg sid "s4" \
       '{runner_handle:$rh,worktree_path:$wt,branch:null,topic:$topic,worker_role:$role,session_id:$sid}')" >/dev/null 2>&1 || true
  t1="$(date +%s)"
  elapsed=$(( t1 - t0 ))

  local lines; lines="$(wc -l < "${tmp}/.company-runtime/harness/workers.jsonl")"
  [[ "${lines}" -eq 1 ]] && _pass "stale recovery 후 append 성공" || _fail "append 실패 (lines=${lines})"

  if [[ "${elapsed}" -le 4 ]]; then
    _pass "recovery 시간 ${elapsed}s <= STALE_LOCK_SEC+2s"
  else
    _fail "recovery 시간 ${elapsed}s > 4s (느림)"
  fi

  rm -rf "${tmp}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
case "${WHICH}" in
  all) s1_spawn_record; s2_idempotency; s3_lock_contention; s4_stale_recovery ;;
  s1)  s1_spawn_record ;;
  s2)  s2_idempotency ;;
  s3)  s3_lock_contention ;;
  s4)  s4_stale_recovery ;;
  *)   echo "usage: $0 [all|s1|s2|s3|s4]" >&2; exit 2 ;;
esac

echo
echo "─────────────────────────"
echo "smoke worker-registry: ${PASS} PASS, ${FAIL} FAIL"
if [[ "${FAIL}" -gt 0 ]]; then exit 1; fi
exit 0
