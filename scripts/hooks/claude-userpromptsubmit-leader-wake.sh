#!/usr/bin/env bash
# scripts/hooks/claude-userpromptsubmit-leader-wake.sh (v1.4.5 신규)
#
# 목적: Claude Code 의 UserPromptSubmit hook 으로 등록되어, 사용자가 다음 turn
#       을 시작할 때 leader-wake-watchdog 가 모은 pending wake 마커를
#       <system-reminder> 로 transcript 에 주입한다. 메인(Claude) 이 워커 결과
#       도착 사실을 다음 reasoning context 안에서 직접 인지하도록 만든다.
#
# 등록 (.claude/settings.json 발췌):
#   {
#     "hooks": {
#       "UserPromptSubmit": [
#         { "type": "command", "command": "bash scripts/hooks/claude-userpromptsubmit-leader-wake.sh" }
#       ]
#     }
#   }
#
# 정책:
#   - 사용자 입력 자체를 변형하지 않는다 (가로채기 금지). stdout 으로
#     <system-reminder>...</system-reminder> 만 추가 출력.
#   - 마커가 없으면 stdout 무출력 → Claude 컨텍스트에 잡음 추가 안 함.
#   - 한 번 주입한 마커는 consumed/ 로 이동 → 같은 사실을 매 turn 마다
#     반복 주입하지 않는다 (banner 점멸 anti-pattern 방지).
#   - 실패는 silent. hook 이 깨져도 사용자 흐름을 막지 않는다.
#
# 세션 id 탐지 우선순위:
#   1. $COMPANY_SESSION_ID 환경변수
#   2. 가장 최근 mtime 의 .company-runtime/sessions/<sid>/ 디렉토리

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="${COMPANY_PROJECT_ROOT:-$(pwd)}"

# Claude Code 가 stdin 으로 JSON payload 를 보낼 수 있으나 우리는 사용하지 않음.
# 무한 대기 방지: stdin 비어 있으면 즉시 진행.
if [[ -t 0 ]]; then
  : # tty — 입력 없음
else
  # non-blocking drain (있으면 버리고 없으면 즉시 종료)
  cat >/dev/null 2>&1 &
  _drain_pid=$!
  ( sleep 0.2; kill "${_drain_pid}" 2>/dev/null || true ) &
  wait "${_drain_pid}" 2>/dev/null || true
fi

resolve_session_id() {
  if [[ -n "${COMPANY_SESSION_ID:-}" ]]; then
    printf '%s\n' "${COMPANY_SESSION_ID}"
    return 0
  fi
  local _sessions_dir="${PROJECT_ROOT}/.company-runtime/sessions"
  [[ -d "${_sessions_dir}" ]] || return 1
  # 가장 최근 mtime 디렉토리 1개
  find "${_sessions_dir}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
    | xargs -I{} stat -f '%m %N' {} 2>/dev/null \
    | sort -nr | head -n1 | awk '{print $2}' | xargs -n1 basename 2>/dev/null
}

SESSION_ID="$(resolve_session_id 2>/dev/null || true)"
if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

WAKE_DIR="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/leader-wake"
PENDING_DIR="${WAKE_DIR}/pending"
CONSUMED_DIR="${WAKE_DIR}/consumed"

# 새 wake 가 있을 수 있으니 watchdog one-shot 한 번 (quiet, dry-run 아님).
if [[ -x "${SCRIPTS_DIR}/leader-wake-watchdog.sh" ]]; then
  bash "${SCRIPTS_DIR}/leader-wake-watchdog.sh" "${SESSION_ID}" "${PROJECT_ROOT}" --quiet >/dev/null 2>&1 || true
fi

[[ -d "${PENDING_DIR}" ]] || exit 0

# pending 마커가 없으면 조용히 종료 (컨텍스트 오염 방지)
shopt -s nullglob
_files=( "${PENDING_DIR}"/*.txt )
shopt -u nullglob
if [[ "${#_files[@]}" -eq 0 ]]; then
  exit 0
fi

mkdir -p "${CONSUMED_DIR}"

# 한 turn 에서 너무 많은 마커가 쏟아지면 잡음이 되므로 최대 10개로 제한.
# 나머지는 consumed 로 옮기지 않고 다음 turn 에서 자연 소비된다.
MAX_INJECT=10
_count=0
_lines=()

for _f in "${_files[@]}"; do
  if (( _count >= MAX_INJECT )); then
    break
  fi
  # 형식: key=value 라인. 안전하게 source 하지 않고 grep 으로 파싱.
  source_type="$(grep -m1 '^source_type=' "${_f}" 2>/dev/null | cut -d= -f2-)"
  source_id="$(grep -m1 '^source_id=' "${_f}" 2>/dev/null | cut -d= -f2-)"
  artifact="$(grep -m1 '^artifact=' "${_f}" 2>/dev/null | cut -d= -f2-)"
  emitted_at="$(grep -m1 '^emitted_at=' "${_f}" 2>/dev/null | cut -d= -f2-)"
  key="$(grep -m1 '^key=' "${_f}" 2>/dev/null | cut -d= -f2-)"

  case "${source_type}" in
    worker)
      _lines+=("- worker '${source_id}' wrote ${artifact}.md (${emitted_at})")
      ;;
    inbox)
      _lines+=("- leader-inbox message: ${source_id} (${emitted_at})")
      ;;
    *)
      _lines+=("- wake event: ${source_type}/${source_id} (${emitted_at})")
      ;;
  esac

  # consumed 로 이동 + 이벤트 emit
  _name="$(basename "${_f}")"
  mv "${_f}" "${CONSUMED_DIR}/${_name}" 2>/dev/null || rm -f "${_f}" 2>/dev/null || true

  if [[ -x "${SCRIPTS_DIR}/company-emit.sh" && -n "${key}" ]]; then
    bash "${SCRIPTS_DIR}/company-emit.sh" "leader_wake_consumed" "${SESSION_ID}" "${PROJECT_ROOT}" \
      "source_type=${source_type}" \
      "source_id=${source_id}" \
      "idempotency_key=${key}" \
      >/dev/null 2>&1 || true
  fi
  _count=$((_count + 1))
done

# system-reminder 페이로드 출력 (Claude Code 가 stdout 을 다음 turn 컨텍스트에 첨부).
# 톤: v1.4.3 banner hint 와 동일 — 명령형, 짧은 한국어.
{
  printf '<system-reminder>\n'
  printf 'leader-wake: 새 워커 산출물 %d건 도착. 다음 turn 에서 결과를 점검하고 사용자에게 요약하세요.\n' "${_count}"
  printf '\n'
  for _l in "${_lines[@]}"; do
    printf '%s\n' "${_l}"
  done
  printf '\n'
  printf '확인 명령 예: bash scripts/runtime-insights.sh — 또는 워커 디렉토리의 compact-result.md 직접 read.\n'
  printf '</system-reminder>\n'
}

exit 0
