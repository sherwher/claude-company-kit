#!/usr/bin/env bash
# validate-integrations-config.sh — config/integrations.yaml scaffold 유효성 검증
# R22 Phase 4 / 축 2: dry-run 구조 검증. 실제 webhook 호출 없음.
#
# 검증 항목:
#   1. config/integrations.yaml 존재
#   2. version: 1 선언
#   3. slack: 블록 존재
#   4. slack.enabled: false (R22 baseline)
#   5. slack.bot_name: 필드 존재 + 비어있지 않음
#   6. 11 canonical event 키가 routes: 블록 아래 전수 존재
#   7. 각 route 의 severity 값이 P1|P2|P3 중 하나
#   8. event_aliases 의 value 가 11 canonical 집합 부분집합
#   9. Telegram 블록 미포함 (R24 범위 경계)
#  10. 비밀값 literal 미포함 (xoxb- / /services/T 패턴)
#
# exit 0: 전항목 통과
# exit 1: 하나라도 실패
#
# YAML 파싱: bash/awk/grep 좁은 키 읽기. full YAML parser 금지.
# indentation 고정: slack 블록 2-space, routes 하위 4-space, aliases 하위 4-space.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CFG="${KIT_DIR}/config/integrations.yaml"

PASS=0
FAIL=0
ERRORS=()

pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("$1"); }

# ── 1. 파일 존재 ──────────────────────────────────────────────────────────────
if [[ ! -f "${CFG}" ]]; then
  echo "FAIL: config/integrations.yaml 없음 — R22 scaffold 미설치" >&2
  exit 1
fi
pass

# ── 2. version: 1 ─────────────────────────────────────────────────────────────
if grep -qE '^version: 1$' "${CFG}"; then
  pass
else
  fail "version: 1 선언 없음"
fi

# ── 3. slack: 블록 ────────────────────────────────────────────────────────────
if grep -qE '^slack:$' "${CFG}"; then
  pass
else
  fail "slack: 최상위 블록 없음"
fi

# ── 4. slack.enabled: false (R22 baseline) ───────────────────────────────────
# 좁은 파서: slack: 블록 진입 후 2-space indent 의 enabled: 값만 읽음
ENABLED="$(awk '/^slack:/{f=1;next} f && /^[a-z]/{exit} f && /^  enabled:/{print $2; exit}' "${CFG}")"
if [[ "${ENABLED}" == "false" ]]; then
  pass
else
  fail "slack.enabled 값 이상 — 기대: false, 실제: '${ENABLED}' (R22 baseline 위반)"
fi

# ── 5. bot_name: 필드 존재 + 비어있지 않음 ───────────────────────────────────
BOT_NAME="$(awk '/^slack:/{f=1;next} f && /^[a-z]/{exit} f && /^  bot_name:/{gsub(/^  bot_name:[[:space:]]*/,""); gsub(/"/,""); print; exit}' "${CFG}")"
if [[ -n "${BOT_NAME}" ]]; then
  pass
else
  fail "slack.bot_name 필드 없거나 비어있음 (Bot Name SSOT 누락)"
fi

# ── 6. 11 canonical 이벤트 routes 아래 전수 존재 ─────────────────────────────
# indentation 규칙: routes 하위 이벤트는 "    <event_name>:" (4-space)
CANONICAL_EVENTS=(
  spawn_prepared
  spawn_success
  spawn_failure
  approval_required
  plan_validated
  approved
  rejected
  compact_result_ready
  export_promoted
  sentinel_detected
  worker_timeout
)

for ev in "${CANONICAL_EVENTS[@]}"; do
  if grep -qE "^    ${ev}:" "${CFG}"; then
    pass
  else
    fail "routes.${ev} 선언 없음 (11 canonical 이벤트 미충족)"
  fi
done

# ── 7. 각 route severity 값이 P1|P2|P3 ───────────────────────────────────────
# routes 블록 내 severity: 값 추출 (4~6 space indent)
BAD_SEVERITY=()
while IFS= read -r line; do
  sev="$(printf '%s' "${line}" | sed 's/.*severity:[[:space:]]*//')"
  sev="${sev%%[[:space:]]*}"
  if [[ ! "${sev}" =~ ^P[123]$ ]]; then
    BAD_SEVERITY+=("${sev}")
  fi
done < <(grep -E '^[[:space:]]+severity:' "${CFG}")

if [[ ${#BAD_SEVERITY[@]} -eq 0 ]]; then
  pass
else
  fail "severity 값 이상: ${BAD_SEVERITY[*]} — P1|P2|P3 중 하나여야 함"
fi

# ── 8. event_aliases value 가 11 canonical 집합 부분집합 ──────────────────────
# event_aliases 블록 (4-space indent) 의 "value" 파트만 추출
# 형식: "    key: value" — value 가 canonical 11 집합에 속해야 함
ALIASES_BAD=()
IN_ALIASES=0

while IFS= read -r line; do
  # event_aliases: 진입
  if [[ "${line}" =~ ^[[:space:]]{2}event_aliases: ]]; then
    IN_ALIASES=1
    continue
  fi
  # 다른 2-space 블록 진입 시 탈출
  if [[ ${IN_ALIASES} -eq 1 ]] && [[ "${line}" =~ ^[[:space:]]{2}[a-z] ]]; then
    IN_ALIASES=0
    continue
  fi
  # 주석 줄 스킵
  [[ "${line}" =~ ^[[:space:]]*# ]] && continue

  if [[ ${IN_ALIASES} -eq 1 ]] && [[ "${line}" =~ ^[[:space:]]{4}[a-z_]+:[[:space:]] ]]; then
    val="$(printf '%s' "${line}" | sed 's/.*:[[:space:]]*//')"
    val="${val%%[[:space:]]*}"
    # canonical 집합 포함 여부 확인
    found=0
    for ev in "${CANONICAL_EVENTS[@]}"; do
      if [[ "${val}" == "${ev}" ]]; then
        found=1
        break
      fi
    done
    if [[ ${found} -eq 0 ]]; then
      ALIASES_BAD+=("${val}")
    fi
  fi
done < "${CFG}"

if [[ ${#ALIASES_BAD[@]} -eq 0 ]]; then
  pass
else
  fail "event_aliases value 가 canonical 집합 밖: ${ALIASES_BAD[*]}"
fi

# ── 9. Telegram 블록 미포함 (R24 범위 경계) ──────────────────────────────────
if grep -qE '^telegram:' "${CFG}"; then
  fail "telegram: 블록 발견 — R24 범위. R22 에서는 포함 금지"
else
  pass
fi

# ── 10. 비밀값 literal 미포함 ─────────────────────────────────────────────────
# Slack bot token prefix (xoxb-) 또는 실제 webhook path (/services/T 로 시작)
if grep -qE '(xoxb-|/services/T[A-Z0-9]+/)' "${CFG}"; then
  fail "비밀값 literal 감지됨 (xoxb- 또는 /services/T...) — env key 이름만 선언 필요"
else
  pass
fi

# ── 결과 출력 ──────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))

if [[ ${FAIL} -eq 0 ]]; then
  echo "integrations.yaml scaffold valid — ${PASS}/${TOTAL} 항목 통과 (11 routes, enabled=false, severity enum OK, alias subset OK)"
  exit 0
else
  echo "integrations.yaml scaffold FAIL — ${FAIL}/${TOTAL} 항목 실패:" >&2
  for err in "${ERRORS[@]}"; do
    echo "  ✗ ${err}" >&2
  done
  exit 1
fi
