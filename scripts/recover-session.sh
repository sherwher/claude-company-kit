#!/usr/bin/env bash
set -euo pipefail

# recover-session.sh (v1.3.6)
#
# 목적: timeout-watchdog 이 stuck 으로 탐지했거나, 리더가 세션 상태를
#       잃어버린 경우 수동 복구를 돕는다. `company approve` 처럼 한 번의
#       의사결정으로 "이 세션을 끝낸다 / 워커를 다시 확인한다 / 중단한다"
#       를 고르게 한다.
#
# 사용:
#   bash recover-session.sh <session_id> [project_root]
#     -> TTY 대화형: pending 워커 출력 + 3지선다 프롬프트
#   bash recover-session.sh <session_id> [project_root] --list
#     -> pending 워커만 표시하고 종료 (프롬프트 없음, CI 친화)
#   bash recover-session.sh <session_id> [project_root] --force-close
#     -> session_closed + manual_recovery emit 후 종료
#   bash recover-session.sh <session_id> [project_root] --verify-now
#     -> pending 워커에 대해 verify-worker-spawn 을 일괄 호출
#
# 이벤트:
#   manual_recovery session_id=<sid> action=<force-close|verify-now|abort> by=<user>
#   (기존 canonical 이벤트 목록 연장 — close-session 이 emit 하는 session_closed 와 분리)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./git-worktree-lib.sh
source "${SCRIPT_DIR}/git-worktree-lib.sh"

SESSION_ID=""
ROOT="."
MODE="interactive"

for _arg in "$@"; do
  case "${_arg}" in
    --list)        MODE="list" ;;
    --force-close) MODE="force-close" ;;
    --verify-now)  MODE="verify-now" ;;
    --abort)       MODE="abort" ;;
    --help|-h)
      sed -n '4,22p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    -*)
      echo "Unknown option: ${_arg}" >&2
      exit 1
      ;;
    *)
      if [[ -z "${SESSION_ID}" ]]; then
        SESSION_ID="${_arg}"
      else
        ROOT="${_arg}"
      fi
      ;;
  esac
done

if [[ -z "${SESSION_ID}" ]]; then
  echo "Usage: $0 <session_id> [project_root] [--list|--force-close|--verify-now|--abort]" >&2
  exit 1
fi

PROJECT_ROOT="$(resolve_shared_project_root "${ROOT}")"
SESSION_DIR="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}"
EVENTS_FILE="${PROJECT_ROOT}/.company-runtime/harness/events.jsonl"
RECOVERY_LOG="${SESSION_DIR}/recovery.log"

if [[ ! -d "${SESSION_DIR}" ]]; then
  echo "✗ 세션이 존재하지 않습니다: ${SESSION_ID}" >&2
  echo "👉 NEXT: 'ls .company-runtime/sessions/' 로 정확한 session_id 를 확인하세요." >&2
  exit 2
fi

mkdir -p "$(dirname "${RECOVERY_LOG}")"

# ── pending 워커 수집 (bash 3.2 호환) ─────────────────────────────────────
# 기준: spawn_attempt/spawn_prepared 는 있으나 spawn_success/spawn_succeeded 가
#       아직 안 찍힌 워커. events.jsonl 이 없으면 디스크 상태로 추정.
collect_pending() {
  local _pending=""
  if [[ -f "${EVENTS_FILE}" ]] && command -v jq >/dev/null 2>&1; then
    # attempted/prepared 이벤트의 워커 목록에서 success/succeeded 이벤트의 워커를 뺀다
    local _attempted
    _attempted="$(jq -r --arg s "${SESSION_ID}" '
      select(.session_id == $s and (.event == "spawn_attempt" or .event == "spawn_prepared")) |
      (.worker // empty)
    ' "${EVENTS_FILE}" 2>/dev/null | sort -u)"
    local _succeeded
    _succeeded="$(jq -r --arg s "${SESSION_ID}" '
      select(.session_id == $s and (.event == "spawn_success" or .event == "spawn_succeeded")) |
      (.worker // empty)
    ' "${EVENTS_FILE}" 2>/dev/null | sort -u)"
    while IFS= read -r _w; do
      [[ -z "${_w}" ]] && continue
      if ! printf '%s\n' "${_succeeded}" | grep -Fxq "${_w}"; then
        _pending="${_pending}${_w} "
      fi
    done <<< "${_attempted}"
  else
    # events.jsonl 부재 fallback: workers/ 디렉토리 중 spawn_succeeded 마커 없는 것
    local _wdir
    for _wdir in "${SESSION_DIR}/workers/"*; do
      [[ -d "${_wdir}" ]] || continue
      if [[ ! -f "${_wdir}/spawn_succeeded" ]]; then
        _pending="${_pending}$(basename "${_wdir}") "
      fi
    done
  fi
  printf '%s' "${_pending% }"
}

PENDING="$(collect_pending)"

print_status() {
  echo "세션: ${SESSION_ID}"
  echo "경로: ${SESSION_DIR}"
  if [[ -z "${PENDING}" ]]; then
    echo "Pending 워커: 없음"
    return 0
  fi
  echo "Pending 워커 (pane 확인 미완료):"
  for _w in ${PENDING}; do
    echo "  - ${_w}"
  done
}

log_recovery() {
  local _action="$1"
  local _note="${2:-}"
  {
    printf '%s\n' "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] action=${_action} user=${USER:-leader} pending='${PENDING:-}'"
    [[ -n "${_note}" ]] && printf '  note=%s\n' "${_note}"
  } >> "${RECOVERY_LOG}"
  bash "${SCRIPT_DIR}/company-emit.sh" "manual_recovery" "${SESSION_ID}" "${PROJECT_ROOT}" \
    "action=${_action}" "pending_count=$(wc -w <<< "${PENDING:-}" | tr -d ' ')" \
    "by=${USER:-leader}" >/dev/null 2>&1 || true
}

case "${MODE}" in
  list)
    print_status
    exit 0
    ;;
  verify-now)
    print_status
    echo ""
    if [[ -z "${PENDING}" ]]; then
      echo "✓ 검증할 pending 워커가 없습니다."
      log_recovery "verify-now" "no-pending"
      exit 0
    fi
    # 각 pending 워커에 verify-worker-spawn 호출 (10s 타임아웃)
    _any_fail=0
    for _w in ${PENDING}; do
      echo ""
      echo "── verify: ${_w} ────────────────────────"
      if ! bash "${SCRIPT_DIR}/verify-worker-spawn.sh" "${SESSION_ID}" "${_w}" "${PROJECT_ROOT}" 10 2; then
        _any_fail=1
      fi
    done
    log_recovery "verify-now" "result_fail=${_any_fail}"
    if (( _any_fail )); then
      echo ""
      echo "⚠️ 일부 워커 검증 실패. '--force-close' 로 세션을 강제 종료하거나 워커 pane 을 수동 확인하세요."
      exit 2
    fi
    echo ""
    echo "✓ 모든 pending 워커 검증 통과."
    exit 0
    ;;
  force-close)
    print_status
    log_recovery "force-close"
    # session_closed 는 close-session.sh 가 emit 하는 영역이지만, 여기서는 복구 흔적
    # 과 함께 manual_recovery 가 이미 찍혔으므로 close-session 에 위임.
    if [[ -x "${SCRIPT_DIR}/close-session.sh" ]]; then
      echo ""
      echo "── close-session 위임 ────────────────────"
      bash "${SCRIPT_DIR}/close-session.sh" "${SESSION_ID}" "${PROJECT_ROOT}" || true
    fi
    echo ""
    echo "✓ 세션 강제 종료: ${SESSION_ID}"
    exit 0
    ;;
  abort)
    log_recovery "abort" "no-action"
    echo "세션 상태 유지 (abort). 로그: ${RECOVERY_LOG}"
    exit 0
    ;;
  interactive)
    print_status
    if [[ -z "${PENDING}" ]]; then
      echo ""
      echo "✓ stuck 워커가 없습니다. 세션을 종료하려면 'company close ${SESSION_ID}' 를 쓰세요."
      exit 0
    fi
    echo ""
    echo "복구 선택지:"
    echo "  1) 워커 pane 을 이미 띄웠다 → verify-worker-spawn 을 일괄 호출 (--verify-now)"
    echo "  2) 세션 포기 → force-close 로 마무리 (--force-close)"
    echo "  3) 나중에 결정 → abort (--abort)"
    printf "선택 [1/2/3]: "
    if [[ ! -t 0 ]]; then
      echo ""
      echo "⚠️ 비대화형 입력 — 플래그를 명시해 주세요 (--verify-now | --force-close | --abort)."
      exit 3
    fi
    read -r _choice
    case "${_choice}" in
      1) exec "$0" "${SESSION_ID}" "${PROJECT_ROOT}" --verify-now ;;
      2) exec "$0" "${SESSION_ID}" "${PROJECT_ROOT}" --force-close ;;
      3) exec "$0" "${SESSION_ID}" "${PROJECT_ROOT}" --abort ;;
      *) echo "알 수 없는 선택: ${_choice}" >&2; exit 1 ;;
    esac
    ;;
esac
