#!/usr/bin/env bash
# claude-tmux-statusline.sh — 하이브리드 statusline
# OMC HUD가 있으면 위임, 없으면 자체 기본 정보 + 사용량 표시
set -euo pipefail

# ── stdin 캡처 (Claude Code가 JSON을 전달) ──────────────────────
STDIN_DATA=""
if [[ ! -t 0 ]]; then
  STDIN_DATA="$(cat)"
fi

# ── OMC HUD 감지 및 위임 ────────────────────────────────────────
# stdin(Claude Code JSON)이 있을 때만 위임 시도 — 없으면 항상 fallback
OMC_HUD="${HOME}/.claude/hud/omc-hud.mjs"
if [[ -n "${STDIN_DATA}" ]] && [[ -f "${OMC_HUD}" ]] && command -v node >/dev/null 2>&1; then
  OMC_OUTPUT="$(printf '%s' "${STDIN_DATA}" | node "${OMC_HUD}" 2>/dev/null)" || true
  # OMC 출력이 유효한 HUD 내용인지 확인 ([OMC] 에러 메시지가 아닌 경우만 위임)
  if [[ -n "${OMC_OUTPUT}" ]] && [[ "${OMC_OUTPUT}" != *"[OMC]"* ]]; then
    printf '%s\n' "${OMC_OUTPUT}"
    exit 0
  fi
  # OMC HUD 실패/에러 시 아래 fallback으로 계속
fi

# ── Fallback: 자체 기본 표시 ─────────────────────────────────────

find_project_root() {
  local dir="$PWD"
  while [[ "${dir}" != "/" ]]; do
    if [[ -d "${dir}/.company-kit" || -f "${dir}/.company-template.lock" ]]; then
      printf '%s\n' "${dir}"
      return 0
    fi
    dir="$(dirname "${dir}")"
  done
  printf '%s\n' "$PWD"
}

PROJECT_ROOT="$(find_project_root)"
PROJECT_NAME="$(basename "${PROJECT_ROOT}")"

# tmux 정보
if command -v tmux >/dev/null 2>&1 && [[ -n "${TMUX:-}" ]]; then
  SESSION_NAME="$(tmux display-message -p '#S' 2>/dev/null || printf 'no-session')"
  WINDOW_NAME="$(tmux display-message -p '#W' 2>/dev/null || printf 'no-window')"
  PANE_NAME="$(tmux display-message -p '#P' 2>/dev/null || printf '-')"
else
  SESSION_NAME="no-tmux"
  WINDOW_NAME="shell"
  PANE_NAME="-"
fi

ROLE_LABEL="leader"
if [[ "${WINDOW_NAME}" != "leader" && "${WINDOW_NAME}" != "shell" && "${WINDOW_NAME}" != "no-window" ]]; then
  ROLE_LABEL="team:${WINDOW_NAME}"
fi

# ── stdin JSON에서 사용량 추출 ───────────────────────────────────
CTX_LABEL=""
MODEL_LABEL=""

if [[ -n "${STDIN_DATA}" ]]; then
  # jq가 있으면 정확한 파싱, 없으면 경량 grep 추출
  if command -v jq >/dev/null 2>&1; then
    CTX_USED="$(printf '%s' "${STDIN_DATA}" | jq -r '.context_window.used // empty' 2>/dev/null)"
    CTX_TOTAL="$(printf '%s' "${STDIN_DATA}" | jq -r '.context_window.total // empty' 2>/dev/null)"
    MODEL_RAW="$(printf '%s' "${STDIN_DATA}" | jq -r '.model // empty' 2>/dev/null)"
  else
    # jq 없을 때 간이 추출
    CTX_USED="$(printf '%s' "${STDIN_DATA}" | grep -o '"used":[0-9]*' | head -1 | grep -o '[0-9]*')"
    CTX_TOTAL="$(printf '%s' "${STDIN_DATA}" | grep -o '"total":[0-9]*' | head -1 | grep -o '[0-9]*')"
    MODEL_RAW="$(printf '%s' "${STDIN_DATA}" | grep -o '"model":"[^"]*"' | head -1 | sed 's/"model":"//;s/"//')"
  fi

  # context % 계산
  if [[ -n "${CTX_USED}" && -n "${CTX_TOTAL}" && "${CTX_TOTAL}" -gt 0 ]]; then
    CTX_PCT=$(( CTX_USED * 100 / CTX_TOTAL ))
    CTX_LABEL="ctx:${CTX_PCT}%"
  fi

  # 모델명 축약
  if [[ -n "${MODEL_RAW}" ]]; then
    case "${MODEL_RAW}" in
      *opus*)   MODEL_LABEL="opus" ;;
      *sonnet*) MODEL_LABEL="sonnet" ;;
      *haiku*)  MODEL_LABEL="haiku" ;;
      *)        MODEL_LABEL="${MODEL_RAW##*-}" ;;
    esac
  fi
fi

# ── v1.3.6: 워커 상태 요약 (events.jsonl 집계) ──────────────────
# 리더가 stuck 세션을 '보기'만으로 감지할 수 있도록 활성 세션의 워커별
# 최신 상태를 심볼 1글자로 축약한다. events.jsonl 미존재 / jq 미설치 시 skip.
WORKERS_LABEL=""
EVENTS_FILE="${PROJECT_ROOT}/.company-runtime/harness/events.jsonl"
if [[ -f "${EVENTS_FILE}" ]] && command -v jq >/dev/null 2>&1; then
  # 가장 최근 (open + 미-close) 세션 선택 — session-closed 이벤트 없는 세션 중 max ts
  ACTIVE_SID="$(jq -r '
    select(.session_id != null) | .session_id
  ' "${EVENTS_FILE}" 2>/dev/null | sort -u | while IFS= read -r _sid; do
    if ! jq -e --arg s "${_sid}" '
      select(.session_id == $s and (.event == "session_closed" or .event == "close_session"))
    ' "${EVENTS_FILE}" >/dev/null 2>&1; then
      printf '%s\n' "${_sid}"
    fi
  done | tail -1)"

  if [[ -n "${ACTIVE_SID}" ]]; then
    # 워커별 latest event 수집 (bash 3.2 호환 — awk)
    NOW_EPOCH=$(date +%s)
    WORKER_STATUS="$(jq -r --arg s "${ACTIVE_SID}" '
      select(.session_id == $s and .worker != null) |
      [(.worker // "unknown"), .event, .ts] | @tsv
    ' "${EVENTS_FILE}" 2>/dev/null | awk -F'\t' '
      { w=$1; e=$2; t=$3; latest[w]=t; last_event[w]=e }
      END { for (w in latest) printf "%s\t%s\t%s\n", w, last_event[w], latest[w] }
    ')"
    if [[ -n "${WORKER_STATUS}" ]]; then
      PARTS_W=()
      while IFS=$'\t' read -r _w _ev _ts; do
        [[ -z "${_w}" ]] && continue
        # ts → epoch (macOS/Linux)
        _ep="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "${_ts}" +%s 2>/dev/null || date -d "${_ts}" +%s 2>/dev/null || echo 0)"
        _elapsed=$((NOW_EPOCH - _ep))
        # status 매핑: symbol + (선택) elapsed minutes
        case "${_ev}" in
          spawn_prepared|spawn_attempt)
            # 60s 이상 pane 확인 없으면 stuck 의심
            if (( _elapsed > 60 )); then _sym="💀"; else _sym="📜"; fi
            ;;
          spawn_succeeded|spawn_success) _sym="📜" ;;
          plan_validated)                _sym="⚖️" ;;
          approved|worker_resumed)       _sym="⚙️" ;;
          compact_result_ready)          _sym="✅" ;;
          rejected)                      _sym="✗" ;;
          worker_timeout|spawn_failure)  _sym="💀" ;;
          *)                             _sym="·" ;;
        esac
        _mm=$((_elapsed / 60))
        if (( _mm > 0 )); then
          PARTS_W+=("${_w}:${_sym}${_mm}m")
        else
          PARTS_W+=("${_w}:${_sym}")
        fi
      done <<< "${WORKER_STATUS}"
      if (( ${#PARTS_W[@]} > 0 )); then
        # 공백 join — 전역 IFS 오염 피하려고 printf + 후미 trim 사용
        WORKERS_LABEL="$(printf '%s ' "${PARTS_W[@]}")"
        WORKERS_LABEL="${WORKERS_LABEL% }"
      fi
    fi
  fi
fi

# ── v1.5.6: 권한 게이트 대기 / 자동 승인 카운트 ─────────────────
# cmux-leader-watcher 가 emit 한 permission_gate_pending 중 미소비된 건수.
GATE_LABEL=""
if [[ -f "${EVENTS_FILE}" ]] && command -v jq >/dev/null 2>&1; then
  _gate_pending="$(awk '
    /"event":"permission_gate_pending"/ {
      match($0, /"worker":"[^"]*"/); w=(RSTART>0 ? substr($0, RSTART+10, RLENGTH-11) : "?")
      pending[w]=1
    }
    /"event":"permission_gate_auto_approved"/ {
      match($0, /"worker":"[^"]*"/); w=(RSTART>0 ? substr($0, RSTART+10, RLENGTH-11) : "?")
      delete pending[w]
    }
    /"event":"approved"/ { for (k in pending) delete pending[k] }
    /"event":"session_closed"/ { for (k in pending) delete pending[k] }
    END { c=0; for (k in pending) c++; print c }
  ' "${EVENTS_FILE}" 2>/dev/null)"
  _auto_count="$(grep -c '"event":"permission_gate_auto_approved"' "${EVENTS_FILE}" 2>/dev/null || echo 0)"
  if [[ "${_gate_pending:-0}" -gt 0 ]]; then
    GATE_LABEL="🔔gate:${_gate_pending}"
  fi
  if [[ "${_auto_count:-0}" -gt 0 ]]; then
    GATE_LABEL="${GATE_LABEL:+${GATE_LABEL} }auto:${_auto_count}"
  fi
fi

# ── 출력 조합 ────────────────────────────────────────────────────
PARTS=("project:${PROJECT_NAME}" "session:${SESSION_NAME}" "role:${ROLE_LABEL}" "pane:${PANE_NAME}")

[[ -n "${MODEL_LABEL}" ]] && PARTS+=("${MODEL_LABEL}")
[[ -n "${CTX_LABEL}" ]]   && PARTS+=("${CTX_LABEL}")
[[ -n "${WORKERS_LABEL}" ]] && PARTS+=("W[${WORKERS_LABEL}]")
[[ -n "${GATE_LABEL}" ]] && PARTS+=("${GATE_LABEL}")

# 구분자 ' | ' 로 join — 전역 IFS 오염 피하려고 printf + sed 사용
printf '%s | ' "${PARTS[@]}" | sed 's/ | $//'
printf '\n'
