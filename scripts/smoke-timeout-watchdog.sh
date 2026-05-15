#!/usr/bin/env bash
# smoke-timeout-watchdog.sh — R26 Phase 4b 신규
#
# 목적: timeout-watchdog.sh 의 탐지 로직을 mock events.jsonl 로 검증.
#
# 사용: bash scripts/smoke-timeout-watchdog.sh
#
# 시나리오:
#   A. events.jsonl 없음 → 정상 무동작
#   B. spawn_attempt 만 있고 spawn_success 없음 / 임계 초과 → TIMEOUT 탐지
#   C. spawn_attempt 후 spawn_success 도 기록 → CLEAN
#   D. 임계 미초과 (최근 ts) → CLEAN
#   E. 실제 emit → events.jsonl 에 worker_timeout 라인 추가
#   F. dry-run → events.jsonl 무변경

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG_SCRIPT="${SCRIPT_DIR}/timeout-watchdog.sh"

PASS_COUNT=0
FAIL_COUNT=0

smoke_pass() { echo "  PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
smoke_fail() { echo "  FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo "[smoke-timeout-watchdog] R26 Phase 4b 시작"

if [[ ! -f "${WATCHDOG_SCRIPT}" ]]; then
  echo "FAIL: timeout-watchdog.sh 없음: ${WATCHDOG_SCRIPT}" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq 미설치 — smoke 건너뜀 (timeout-watchdog 정책과 동일)" >&2
  exit 0
fi

TMPDIR_SMOKE="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_SMOKE}"' EXIT

EVENTS_DIR="${TMPDIR_SMOKE}/.company-runtime/harness"
EVENTS_FILE="${EVENTS_DIR}/events.jsonl"
mkdir -p "${EVENTS_DIR}"

# old_ts: 임계 초과 — 1시간 전
# new_ts: 임계 미초과 — 현재 시각
old_ts="$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
new_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── 시나리오 A: events.jsonl 없음 ───────────────────────────────────────────
echo ""
echo "[A] events.jsonl 없음"
TMP_A="$(mktemp -d)"
OUTPUT_A="$(bash "${WATCHDOG_SCRIPT}" "session-a" "${TMP_A}" 60 --dry-run 2>&1)"
if echo "${OUTPUT_A}" | grep -q "events.jsonl 없음"; then
  smoke_pass "[A] events.jsonl 없음 — 정상 무동작"
else
  smoke_fail "[A] 기대: 'events.jsonl 없음' / 실제: ${OUTPUT_A}"
fi
rm -rf "${TMP_A}"

# ── 시나리오 B: spawn_attempt 만 있고 임계 초과 → TIMEOUT ────────────────────
echo ""
echo "[B] TIMEOUT 탐지"
cat > "${EVENTS_FILE}" <<EOF
{"ts":"${old_ts}","event":"spawn_attempt","session_id":"session-b","worker":"worker-1"}
EOF
OUTPUT_B="$(bash "${WATCHDOG_SCRIPT}" "session-b" "${TMPDIR_SMOKE}" 60 --dry-run 2>&1)"
if echo "${OUTPUT_B}" | grep -q "TIMEOUT"; then
  smoke_pass "[B] TIMEOUT 출력 확인"
else
  smoke_fail "[B] TIMEOUT 기대 / 실제: ${OUTPUT_B}"
fi
if echo "${OUTPUT_B}" | grep -q "worker-1"; then
  smoke_pass "[B] worker-1 리스팅 확인"
else
  smoke_fail "[B] worker-1 기대 / 실제: ${OUTPUT_B}"
fi

# ── 시나리오 C: spawn_attempt + spawn_success → CLEAN ────────────────────────
echo ""
echo "[C] CLEAN — spawn_success 존재"
cat > "${EVENTS_FILE}" <<EOF
{"ts":"${old_ts}","event":"spawn_attempt","session_id":"session-c","worker":"worker-2"}
{"ts":"${old_ts}","event":"spawn_success","session_id":"session-c","worker":"worker-2"}
EOF
OUTPUT_C="$(bash "${WATCHDOG_SCRIPT}" "session-c" "${TMPDIR_SMOKE}" 60 --dry-run 2>&1)"
if echo "${OUTPUT_C}" | grep -q "CLEAN"; then
  smoke_pass "[C] CLEAN 출력 확인"
else
  smoke_fail "[C] CLEAN 기대 / 실제: ${OUTPUT_C}"
fi

# ── 시나리오 C2 (v1.3.6): spawn_attempt + spawn_succeeded → CLEAN ────────────
echo ""
echo "[C2] CLEAN — spawn_succeeded (pane 확인) 수용"
cat > "${EVENTS_FILE}" <<EOF
{"ts":"${old_ts}","event":"spawn_attempt","session_id":"session-c2","worker":"worker-2b"}
{"ts":"${old_ts}","event":"spawn_succeeded","session_id":"session-c2","worker":"worker-2b"}
EOF
OUTPUT_C2="$(bash "${WATCHDOG_SCRIPT}" "session-c2" "${TMPDIR_SMOKE}" 60 --dry-run 2>&1)"
if echo "${OUTPUT_C2}" | grep -q "CLEAN"; then
  smoke_pass "[C2] CLEAN 출력 확인 (spawn_succeeded 수용)"
else
  smoke_fail "[C2] CLEAN 기대 / 실제: ${OUTPUT_C2}"
fi

# ── 시나리오 D: 최근 ts (임계 미초과) → CLEAN ─────────────────────────────────
echo ""
echo "[D] CLEAN — 임계 미초과"
cat > "${EVENTS_FILE}" <<EOF
{"ts":"${new_ts}","event":"spawn_attempt","session_id":"session-d","worker":"worker-3"}
EOF
# 임계 3600 (1시간). new_ts 는 현재 → 임계 미초과 확정
OUTPUT_D="$(bash "${WATCHDOG_SCRIPT}" "session-d" "${TMPDIR_SMOKE}" 3600 --dry-run 2>&1)"
if echo "${OUTPUT_D}" | grep -q "CLEAN"; then
  smoke_pass "[D] CLEAN 출력 확인"
else
  smoke_fail "[D] CLEAN 기대 / 실제: ${OUTPUT_D}"
fi

# ── 시나리오 E: 실제 emit → events.jsonl 에 worker_timeout 라인 추가 ─────────
echo ""
echo "[E] emit → worker_timeout 라인 추가"
cat > "${EVENTS_FILE}" <<EOF
{"ts":"${old_ts}","event":"spawn_attempt","session_id":"session-e","worker":"worker-4"}
EOF
before_lines=$(wc -l < "${EVENTS_FILE}" | tr -d ' ')
bash "${WATCHDOG_SCRIPT}" "session-e" "${TMPDIR_SMOKE}" 60 >/dev/null 2>&1
after_lines=$(wc -l < "${EVENTS_FILE}" | tr -d ' ')
if grep -q "worker_timeout" "${EVENTS_FILE}" 2>/dev/null; then
  smoke_pass "[E] worker_timeout 라인 존재 (${before_lines} → ${after_lines})"
else
  smoke_fail "[E] worker_timeout 없음"
fi

# ── 시나리오 F: dry-run → events.jsonl 무변경 ────────────────────────────────
echo ""
echo "[F] dry-run → 무변경"
cat > "${EVENTS_FILE}" <<EOF
{"ts":"${old_ts}","event":"spawn_attempt","session_id":"session-f","worker":"worker-5"}
EOF
before_lines=$(wc -l < "${EVENTS_FILE}" | tr -d ' ')
bash "${WATCHDOG_SCRIPT}" "session-f" "${TMPDIR_SMOKE}" 60 --dry-run >/dev/null 2>&1
after_lines=$(wc -l < "${EVENTS_FILE}" | tr -d ' ')
if [[ "${before_lines}" == "${after_lines}" ]]; then
  smoke_pass "[F] dry-run — 라인 수 불변 (${after_lines})"
else
  smoke_fail "[F] dry-run — 라인 수 변경 (${before_lines} → ${after_lines})"
fi

# ── 결과 요약 ────────────────────────────────────────────────────────────────
echo ""
if [[ "${FAIL_COUNT}" -eq 0 ]]; then
  echo "PASS: smoke-timeout-watchdog — ${PASS_COUNT} 조건 전수 통과"
  exit 0
else
  echo "FAIL: smoke-timeout-watchdog — ${FAIL_COUNT} 실패 / ${PASS_COUNT} 통과" >&2
  exit 1
fi
