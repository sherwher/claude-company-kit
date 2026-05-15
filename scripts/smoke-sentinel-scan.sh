#!/usr/bin/env bash
# smoke-sentinel-scan.sh — R26 Phase 4b 신규
#
# 목적: sentinel-scan.sh 의 2 경로 (CLEAN / DETECTED) 를 mock fixture 로 검증.
#
# 사용: bash scripts/smoke-sentinel-scan.sh
#
# 성공 조건:
#   1. CLEAN 시나리오: 깨끗한 compact-plan.json → "CLEAN" 출력 + exit 0
#   2. DETECTED 시나리오: TODO 포함 compact-plan.json → "DETECTED" 출력 + exit 0 + emit 기록
#   3. 복수 패턴 시나리오: FIXME + XXX + PLACEHOLDER → files=1, patterns>=3
#   4. dry-run: emit 없이 탐지만 (events.jsonl 에 신규 라인 0)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN_SCRIPT="${SCRIPT_DIR}/sentinel-scan.sh"

PASS_COUNT=0
FAIL_COUNT=0

smoke_pass() { echo "  PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
smoke_fail() { echo "  FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo "[smoke-sentinel-scan] R26 Phase 4b 시작"

if [[ ! -f "${SCAN_SCRIPT}" ]]; then
  echo "FAIL: sentinel-scan.sh 없음: ${SCAN_SCRIPT}" >&2
  exit 1
fi

TMPDIR_SMOKE="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_SMOKE}"' EXIT

# ── 시나리오 A: CLEAN (패턴 없음) ────────────────────────────────────────────
echo ""
echo "[A] CLEAN"
SESSION_A="sentinel-clean"
PLAN_DIR_A="${TMPDIR_SMOKE}/.company-artifacts/${SESSION_A}/workers/test-worker"
mkdir -p "${PLAN_DIR_A}"
cat > "${PLAN_DIR_A}/compact-plan.json" <<'EOF'
{"meta":{"schema":"compact-plan.v2"},"worker":"test-worker","mission":"정상 계획서"}
EOF
OUTPUT_A="$(bash "${SCAN_SCRIPT}" "${SESSION_A}" "${TMPDIR_SMOKE}" --dry-run 2>&1)"
if echo "${OUTPUT_A}" | grep -q "CLEAN"; then
  smoke_pass "[A] CLEAN 출력 확인"
else
  smoke_fail "[A] CLEAN 기대 / 실제: ${OUTPUT_A}"
fi

# ── 시나리오 B: DETECTED (TODO 단일 패턴) ────────────────────────────────────
echo ""
echo "[B] DETECTED — TODO"
SESSION_B="sentinel-todo"
PLAN_DIR_B="${TMPDIR_SMOKE}/.company-artifacts/${SESSION_B}/workers/test-worker"
mkdir -p "${PLAN_DIR_B}"
cat > "${PLAN_DIR_B}/compact-plan.json" <<'EOF'
{"meta":{"schema":"compact-plan.v2"},"worker":"test-worker","mission":"TODO: 세부 계획 미완"}
EOF
OUTPUT_B="$(bash "${SCAN_SCRIPT}" "${SESSION_B}" "${TMPDIR_SMOKE}" --dry-run 2>&1)"
if echo "${OUTPUT_B}" | grep -q "DETECTED"; then
  smoke_pass "[B] DETECTED 출력 확인"
else
  smoke_fail "[B] DETECTED 기대 / 실제: ${OUTPUT_B}"
fi
if echo "${OUTPUT_B}" | grep -q "files=1"; then
  smoke_pass "[B] files=1 확인"
else
  smoke_fail "[B] files=1 기대 / 실제: ${OUTPUT_B}"
fi

# ── 시나리오 C: 복수 패턴 (FIXME + XXX + PLACEHOLDER) ─────────────────────────
echo ""
echo "[C] DETECTED — 복수 패턴"
SESSION_C="sentinel-multi"
PLAN_DIR_C="${TMPDIR_SMOKE}/.company-artifacts/${SESSION_C}/workers/test-worker"
mkdir -p "${PLAN_DIR_C}"
cat > "${PLAN_DIR_C}/compact-result.md" <<'EOF'
# Result
- FIXME: validation 미완료
- XXX: 임시 구현
- PLACEHOLDER value
- <TBD> resolution
EOF
OUTPUT_C="$(bash "${SCAN_SCRIPT}" "${SESSION_C}" "${TMPDIR_SMOKE}" --dry-run 2>&1)"
if echo "${OUTPUT_C}" | grep -q "DETECTED"; then
  smoke_pass "[C] DETECTED 출력 확인"
else
  smoke_fail "[C] DETECTED 기대 / 실제: ${OUTPUT_C}"
fi
# 패턴 수 >= 3 (FIXME, XXX, PLACEHOLDER 중 최소 3개 — grep -c 는 라인 단위)
if echo "${OUTPUT_C}" | grep -oE "patterns=[0-9]+" | grep -qE "patterns=[3-9]|patterns=[1-9][0-9]"; then
  smoke_pass "[C] patterns >= 3 확인"
else
  smoke_fail "[C] patterns>=3 기대 / 실제: ${OUTPUT_C}"
fi

# ── 시나리오 D: dry-run → events.jsonl 무변경 ────────────────────────────────
echo ""
echo "[D] dry-run → events.jsonl 무변경"
SESSION_D="sentinel-dry"
PLAN_DIR_D="${TMPDIR_SMOKE}/.company-artifacts/${SESSION_D}/workers/test-worker"
mkdir -p "${PLAN_DIR_D}"
cat > "${PLAN_DIR_D}/compact-plan.json" <<'EOF'
{"mission":"TODO dry-run 검증"}
EOF
EVENTS_FILE_D="${TMPDIR_SMOKE}/.company-runtime/harness/events.jsonl"
mkdir -p "$(dirname "${EVENTS_FILE_D}")"
: > "${EVENTS_FILE_D}"
before_lines=$(wc -l < "${EVENTS_FILE_D}" | tr -d ' ')
bash "${SCAN_SCRIPT}" "${SESSION_D}" "${TMPDIR_SMOKE}" --dry-run >/dev/null 2>&1
after_lines=$(wc -l < "${EVENTS_FILE_D}" | tr -d ' ')
if [[ "${before_lines}" == "${after_lines}" ]]; then
  smoke_pass "[D] dry-run — events.jsonl 라인 수 불변 (${after_lines})"
else
  smoke_fail "[D] dry-run — events.jsonl 변경 (${before_lines} → ${after_lines})"
fi

# ── 시나리오 E: 실제 emit → events.jsonl 에 sentinel_detected 라인 추가 ───────
echo ""
echo "[E] emit → events.jsonl sentinel_detected 추가"
SESSION_E="sentinel-emit"
PLAN_DIR_E="${TMPDIR_SMOKE}/.company-artifacts/${SESSION_E}/workers/test-worker"
mkdir -p "${PLAN_DIR_E}"
cat > "${PLAN_DIR_E}/compact-plan.json" <<'EOF'
{"mission":"TODO: emit 검증용"}
EOF
bash "${SCAN_SCRIPT}" "${SESSION_E}" "${TMPDIR_SMOKE}" >/dev/null 2>&1
if [[ -f "${EVENTS_FILE_D}" ]] && grep -q "sentinel_detected" "${EVENTS_FILE_D}" 2>/dev/null; then
  smoke_pass "[E] events.jsonl 에 sentinel_detected 라인 존재"
else
  smoke_fail "[E] events.jsonl 에 sentinel_detected 없음 (jq 미설치 시 skip)"
fi

# ── 결과 요약 ────────────────────────────────────────────────────────────────
echo ""
if [[ "${FAIL_COUNT}" -eq 0 ]]; then
  echo "PASS: smoke-sentinel-scan — ${PASS_COUNT} 조건 전수 통과 (CLEAN + DETECTED×2 + dry-run + emit)"
  exit 0
else
  echo "FAIL: smoke-sentinel-scan — ${FAIL_COUNT} 조건 실패 / ${PASS_COUNT} 통과" >&2
  exit 1
fi
