#!/usr/bin/env bash
# generate-slack-routes-json.sh — config/integrations.yaml → slack-routes.json 렌더
# R23 Phase 4 / 축 2: bash/awk 좁은 파서. Node deps 0, full YAML parser 0.
#
# 입력: config/integrations.yaml (R22 고정 포맷)
#   indentation: slack: 0-space, routes: 2-space, <event>: 4-space, lanes/severity: 6-space
#
# 출력: .company-runtime/harness/slack-routes.json
#   event-flush.mjs L615 normalizeRoutes 가 수용하는 형식:
#   { "routes": { "<event>": { "lanes": [...], "severity": "P?" } } }
#
# 의존성: awk (POSIX), jq (미설치 시 silent skip — company-emit.sh L29 정책 통일)
#
# 사용:
#   bash scripts/generate-slack-routes-json.sh [project_root]
#
# 출력 경로 override:
#   SLACK_ROUTES_OUTPUT=/path/to/slack-routes.json bash scripts/generate-slack-routes-json.sh

set -euo pipefail

PROJECT_ROOT="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# config 파일 탐색 (harness 소스 레포 우선, target 프로젝트 fallback)
CFG=""
for _candidate in \
  "${KIT_DIR}/config/integrations.yaml" \
  "${PROJECT_ROOT}/.company-kit/config/integrations.yaml" \
  "${PROJECT_ROOT}/config/integrations.yaml"; do
  if [[ -f "${_candidate}" ]]; then
    CFG="${_candidate}"
    break
  fi
done

if [[ -z "${CFG}" ]]; then
  echo "WARN: config/integrations.yaml 없음 — slack-routes.json 생성 skip" >&2
  exit 0
fi

# jq 미설치 시 silent skip (company-emit.sh L29 정책 통일)
if ! command -v jq >/dev/null 2>&1; then
  echo "WARN: jq 미설치 — slack-routes.json 생성 skip" >&2
  exit 0
fi

# 출력 경로 결정
OUTPUT_DIR="${PROJECT_ROOT}/.company-runtime/harness"
OUTPUT="${SLACK_ROUTES_OUTPUT:-${OUTPUT_DIR}/slack-routes.json}"
mkdir -p "$(dirname "${OUTPUT}")"

# ── awk 파서: config/integrations.yaml 의 slack.routes 블록 파싱 ──────────────
# state machine:
#   in_slack   : "slack:" 진입 후
#   in_routes  : "  routes:" 진입 후 (2-space indent)
#   cur_event  : 현재 이벤트 이름 (4-space indent "    <name>:")
#   cur_lanes  : lanes 배열 문자열
#   cur_sev    : severity 값
#
# lanes 포맷: "[session-thread]" 또는 "[audit, session-thread]"
# → 대괄호 제거 후 쉼표 split → JSON 배열 직조
#
# 출력: 11 이벤트 × { "lanes": [...], "severity": "P?" } JSON 라인 목록
# 최종 JSON 조합은 jq 로 수행 (이중 따옴표 이스케이핑 회피)

ROUTES_JSON="$(awk '
BEGIN {
  in_slack  = 0
  in_routes = 0
  cur_event = ""
  cur_lanes = ""
  cur_sev   = ""
  first     = 1
}

# slack: 블록 진입 (0-space)
/^slack:/ {
  in_slack = 1
  next
}

# slack 블록 종료: 다른 최상위 키 등장 (0-space 알파벳)
in_slack && /^[a-z]/ {
  if (cur_event != "") emit()
  in_slack  = 0
  in_routes = 0
  next
}

# routes: 블록 진입 (2-space)
in_slack && /^  routes:/ {
  in_routes = 1
  next
}

# routes 블록 종료: 2-space 다른 키 등장
in_slack && in_routes && /^  [a-z]/ && !/^  routes:/ {
  if (cur_event != "") emit()
  cur_event = ""
  cur_lanes = ""
  cur_sev   = ""
  in_routes = 0
  next
}

# 4-space 이벤트 이름 (    <name>:)
in_slack && in_routes && /^    [a-z_]+:/ {
  if (cur_event != "") emit()
  # "    spawn_prepared:" → "spawn_prepared"
  ev = $0
  sub(/^    /, "", ev)
  sub(/:.*$/, "", ev)
  cur_event = ev
  cur_lanes = ""
  cur_sev   = ""
  next
}

# 6-space lanes 값 (      lanes: [session-thread] or [audit, session-thread])
in_slack && in_routes && /^      lanes:/ {
  raw = $0
  sub(/^      lanes:[[:space:]]*/, "", raw)
  # 주석 제거
  sub(/#.*$/, "", raw)
  # 대괄호 제거
  gsub(/[\[\]]/, "", raw)
  # 앞뒤 공백 제거
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", raw)
  cur_lanes = raw
  next
}

# 6-space severity (      severity: P3   # 주석)
in_slack && in_routes && /^      severity:/ {
  raw = $2
  sub(/#.*$/, "", raw)
  gsub(/[[:space:]]/, "", raw)
  cur_sev = raw
  next
}

END {
  if (cur_event != "") emit()
}

function emit() {
  # lanes 쉼표 split → JSON 배열
  n = split(cur_lanes, parts, /,[[:space:]]*/);
  lanes_json = "["
  for (i = 1; i <= n; i++) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[i])
    if (i > 1) lanes_json = lanes_json ","
    lanes_json = lanes_json "\"" parts[i] "\""
  }
  lanes_json = lanes_json "]"

  # severity 기본값 P3 (파싱 실패 방어)
  sev = (cur_sev ~ /^P[123]$/) ? cur_sev : "P3"

  if (!first) printf ","
  printf "\n  \"%s\": {\"lanes\": %s, \"severity\": \"%s\"}", cur_event, lanes_json, sev
  first = 0
}
' "${CFG}")"

# JSON 전체 조합 (jq 로 유효성 검증 + pretty print)
printf '{"routes": {%s\n}}\n' "${ROUTES_JSON}" | jq '.' > "${OUTPUT}"

EVENT_COUNT="$(jq '.routes | length' "${OUTPUT}")"
echo "slack-routes.json 생성 완료 — ${EVENT_COUNT} routes → ${OUTPUT}"
