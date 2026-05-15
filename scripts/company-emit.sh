#!/usr/bin/env bash
set -euo pipefail

# company-emit.sh — bash + jq 기반 최소 이벤트 로거.
# v1.1.0 (C3): HARNESS_V0 §4.2 구현.
#
# 사용:
#   bash company-emit.sh <event_name> <session_id> [project_root] [k=v ...]
#
# 예:
#   bash company-emit.sh spawn_attempt feature-x . worker=frontend-engineer
#   bash company-emit.sh approved feature-x . approver=leader
#
# 동시 쓰기 안전성: mkdir lockdir 패턴 (macOS/Linux 공통, flock 불필요).
# JSON 한 줄 생성은 락 밖에서 jq로 끝낸 후, append 한 번만 락으로 보호.
# 최대 5워커 동시 환경 기준 20-50ms backoff면 충분.

EVENT="${1:-}"
SESSION_ID="${2:-}"
PROJECT_ROOT="${3:-.}"
shift 3 2>/dev/null || true

if [[ -z "${EVENT}" || -z "${SESSION_ID}" ]]; then
  echo "Usage: $0 <event> <session_id> [project_root] [k=v ...]" >&2
  exit 1
fi

# jq가 없으면 silent skip — Phase 1에서는 hard fail 하지 않는다 (HARNESS_V0 §4.2)
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

EVENTS_DIR="${PROJECT_ROOT}/.company-runtime/harness"
EVENTS_FILE="${EVENTS_DIR}/events.jsonl"
LOCK_DIR="${EVENTS_DIR}/events.lock"

mkdir -p "${EVENTS_DIR}"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 추가 k=v 인자를 jq 객체로 누적 (락 밖에서 처리)
EXTRA_JSON='{}'
for arg in "$@"; do
  if [[ "${arg}" == *=* ]]; then
    k="${arg%%=*}"
    v="${arg#*=}"
    EXTRA_JSON="$(printf '%s' "${EXTRA_JSON}" | jq --arg k "${k}" --arg v "${v}" '. + {($k): $v}')"
  fi
done

LINE="$(jq -nc \
  --arg ts "${TS}" \
  --arg event "${EVENT}" \
  --arg sid "${SESSION_ID}" \
  --argjson extra "${EXTRA_JSON}" \
  '{ts: $ts, event: $event, session_id: $sid} + $extra')"

# mkdir lockdir 락 (최대 ~2초 대기, 100회 backoff)
attempts=0
max_attempts=100
until mkdir "${LOCK_DIR}" 2>/dev/null; do
  attempts=$((attempts + 1))
  if [[ "${attempts}" -ge "${max_attempts}" ]]; then
    # stale lock 감지: 30초 초과면 강제 회수
    if [[ -d "${LOCK_DIR}" ]]; then
      lock_age=$(( $(date +%s) - $(stat -f %m "${LOCK_DIR}" 2>/dev/null || stat -c %Y "${LOCK_DIR}" 2>/dev/null || echo 0) ))
      if [[ "${lock_age}" -gt 30 ]]; then
        rmdir "${LOCK_DIR}" 2>/dev/null || true
        continue
      fi
    fi
    echo "WARN: company-emit lock timeout for ${EVENT}/${SESSION_ID}" >&2
    exit 0
  fi
  sleep 0.02
done
trap 'rmdir "${LOCK_DIR}" 2>/dev/null || true' EXIT

printf '%s\n' "${LINE}" >> "${EVENTS_FILE}"

rmdir "${LOCK_DIR}" 2>/dev/null || true
trap - EXIT

# ── R23 (축 2): Slack outbound one-shot flush hook ────────────────────────────
# opt-in OFF 회귀 0 원칙: 모든 실패 경로는 silent skip (exit 0 유지).
# 체크 순서: 1) config 미존재 → skip  2) slack.enabled != true → skip
#            3) node 미설치 → skip    4) event-flush.mjs 사이드카 미존재 → skip
# 실제 Slack workspace 호출 0 건 — SLACK_WEBHOOK_URL 이 localhost 이면 mock 대상.
_R23_slack_one_shot_flush() {
  # config/integrations.yaml 탐색 (harness 소스 레포 / target 프로젝트 fallback)
  local _script_dir
  _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local _kit_dir
  _kit_dir="$(cd "${_script_dir}/.." && pwd)"

  local _cfg=""
  for _c in \
    "${_kit_dir}/config/integrations.yaml" \
    "${PROJECT_ROOT}/.company-kit/config/integrations.yaml" \
    "${PROJECT_ROOT}/config/integrations.yaml"; do
    if [[ -f "${_c}" ]]; then _cfg="${_c}"; break; fi
  done
  [[ -n "${_cfg}" ]] || return 0

  # slack.enabled 좁은 파서 (doctor.sh L350 과 동일 패턴)
  local _enabled
  _enabled="$(awk '/^slack:/{f=1;next} f && /^[a-z]/{exit} f && /^  enabled:/{print $2; exit}' "${_cfg}" 2>/dev/null)"
  [[ "${_enabled}" == "true" ]] || return 0

  # node 미설치 → skip
  command -v node >/dev/null 2>&1 || return 0

  # event-flush.mjs 사이드카 탐색
  local _flush=""
  for _f in \
    "${_script_dir}/integrations/slack/event-flush.mjs" \
    "${PROJECT_ROOT}/.company-kit/scripts/integrations/slack/event-flush.mjs"; do
    if [[ -f "${_f}" ]]; then _flush="${_f}"; break; fi
  done
  [[ -n "${_flush}" ]] || return 0

  # routes.json 지연 렌더 (부재 시 generate 스크립트 호출)
  local _routes="${EVENTS_DIR}/slack-routes.json"
  if [[ ! -f "${_routes}" ]]; then
    local _gen=""
    for _g in \
      "${_script_dir}/generate-slack-routes-json.sh" \
      "${PROJECT_ROOT}/.company-kit/scripts/generate-slack-routes-json.sh"; do
      if [[ -f "${_g}" ]]; then _gen="${_g}"; break; fi
    done
    [[ -n "${_gen}" ]] && bash "${_gen}" "${PROJECT_ROOT}" >/dev/null 2>&1 || return 0
  fi

  # one-shot flush — 실패해도 emit 자체는 완료이므로 exit 0 유지
  SLACK_ROUTES_PATH="${_routes}" \
  COMPANY_RUNTIME_ROOT="${PROJECT_ROOT}/.company-runtime" \
  COMPANY_EVENTS_PATH="${EVENTS_FILE}" \
    node "${_flush}" --once >/dev/null 2>&1 || return 0
}
_R23_slack_one_shot_flush || true
