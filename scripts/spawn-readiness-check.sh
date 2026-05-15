#!/usr/bin/env bash
set -euo pipefail

# spawn-readiness-check.sh (v1.3.7)
#
# 역할: 리더 또는 워커 준비 직전에 "지금 이 환경에서 워커를 스폰해도 되는가" 를
# 최소 정보로 답한다. v1.3.7 부터 runner-lib 를 통해 러너별로 판정한다.
#
# 모드:
#   leader           : 리더 세션 기본 검사 (기본값)
#   worker-required  : 워커 pane 이 이미 있어야 한다고 선언 (tmux 러너 한정 의미)
#
# 종료 코드:
#   0 ready / 2 not-ready / 3 wrong-session

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./runner-lib.sh
source "${SCRIPT_DIR}/runner-lib.sh"

MODE="${1:-leader}"
EXPECTED_SESSION="${2:-}"

# runner 결정 (preflight → env → auto)
_RUNNER=""
if [[ -n "${EXPECTED_SESSION}" ]]; then
  _pf="./.company-runtime/sessions/${EXPECTED_SESSION}/preflight.json"
  if [[ -f "${_pf}" ]] && command -v jq >/dev/null 2>&1; then
    _RUNNER="$(jq -r '.runner // empty' "${_pf}" 2>/dev/null || printf '')"
  fi
fi
if [[ -z "${_RUNNER}" ]]; then
  _RUNNER="${COMPANY_RUNNER:-}"
fi
if [[ -z "${_RUNNER}" ]]; then
  # TMUX 안 → tmux. CMUX_PANEL_ID/CMUX_WORKSPACE_ID 안 → cmux. 그 외 → sequential.
  if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then
    _RUNNER="tmux"
  elif [[ ( -n "${CMUX_PANEL_ID:-}" || -n "${CMUX_WORKSPACE_ID:-}" ) ]] && command -v cmux >/dev/null 2>&1; then
    _RUNNER="cmux"
  else
    _RUNNER="sequential"
  fi
fi

echo "Runner: ${_RUNNER}"

case "${_RUNNER}" in
  sequential|manual)
    # pane 개념이 없으므로 항상 soft ready.
    echo "Ready: soft"
    echo "Reason Code: ${_RUNNER}-mode"
    echo "Hint: 병렬 pane 은 사용되지 않습니다. 현재 터미널에서 순차 진행하세요."
    exit 0
    ;;
  tmux|cmux)
    # tmux/cmux 어댑터는 검증 절차가 동형이지만 CLI surface 가 다르다.
    # tmux: $TMUX env, display-message -p '#S'/'#W', list-panes -F.
    # cmux: $CMUX_PANEL_ID/$CMUX_WORKSPACE_ID env, current-workspace, list-panes (--workspace).
    case "${_RUNNER}" in
      tmux) _CLI="tmux"; _ENV_FLAG="${TMUX:-}" ;;
      cmux) _CLI="cmux"; _ENV_FLAG="${CMUX_PANEL_ID:-${CMUX_WORKSPACE_ID:-}}" ;;
    esac

    if ! command -v "${_CLI}" >/dev/null 2>&1 || [[ -z "${_ENV_FLAG}" ]]; then
      echo "Ready: soft"
      echo "Reason Code: ${_CLI}-not-inside"
      echo "Hint: ${_CLI} 러너이지만 현재 ${_CLI} 클라이언트 밖입니다. sequential 로 폴백하거나 ${_CLI} 세션에 붙으세요."
      exit 0
    fi

    if [[ "${_RUNNER}" == "cmux" ]]; then
      # cmux 0.63.x: display-message -p '#S' 는 literal 출력 → 사용 금지.
      # session 식별은 current-workspace 또는 CMUX_WORKSPACE_ID, window 는 CMUX_TAB_ID 사용.
      session_name="$(cmux current-workspace 2>/dev/null | head -n1 | tr -d '\r' || printf '')"
      [[ -n "${session_name}" ]] || session_name="${CMUX_WORKSPACE_ID:-unknown}"
      window_name="${CMUX_TAB_ID:-unknown}"
      # list-panes 는 --workspace 컨텍스트 필요. -F format 미지원.
      pane_count="$(cmux list-panes --workspace "${CMUX_WORKSPACE_ID:-current}" 2>/dev/null | grep -cE '^.+' | tr -d ' ')"
      [[ -n "${pane_count}" ]] || pane_count="0"
    else
      session_name="$(tmux display-message -p '#S' 2>/dev/null || printf 'unknown')"
      window_name="$(tmux display-message -p '#W' 2>/dev/null || printf 'unknown')"
      pane_count="$(tmux list-panes -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' ')"
    fi

    echo "Ready: yes"
    echo "Session: ${session_name}"
    echo "Window: ${window_name}"
    echo "Pane Count: ${pane_count}"

    # v1.5.6: workspace/session 이름 일치 강제 완화.
    # 사용자가 임의 이름의 cmux workspace 또는 tmux 세션 안에서 작업할 수 있으므로
    # 회사 도구가 그 이름을 강제하지 않는다. 본질은 "현재 멀티플렉서 안에서
    # 새 pane/surface 를 띄울 수 있는가" 이지 이름 매칭이 아니다.
    # COMPANY_STRICT_SESSION_MATCH=1 으로 옛 동작 옵트인 가능 (CI 등 격리 환경용).
    if [[ -n "${EXPECTED_SESSION}" && "${session_name}" != "${EXPECTED_SESSION}" ]]; then
      if [[ "${COMPANY_STRICT_SESSION_MATCH:-0}" == "1" ]]; then
        echo "Ready: no"
        echo "Reason: current ${_CLI} session '${session_name}' does not match expected '${EXPECTED_SESSION}' (strict mode)"
        echo "Reason Code: wrong-session"
        exit 3
      fi
      echo "Note: session name '${session_name}' differs from expected '${EXPECTED_SESSION}' — proceeding anyway (set COMPANY_STRICT_SESSION_MATCH=1 to enforce)"
    fi

    if [[ "${MODE}" == "worker-required" ]]; then
      if [[ "${pane_count}" =~ ^[0-9]+$ ]] && (( pane_count >= 2 )); then
        echo "Worker Pane Present: yes"
        echo "Reason Code: worker-pane-detected"
        exit 0
      fi
      echo "Worker Pane Present: no"
      echo "Reason Code: no-pane-added"
      exit 2
    fi

    echo "Reason Code: leader-ready"
    exit 0
    ;;
  *)
    # 미구현 어댑터 (codex-native 등 slot 러너)
    echo "Ready: soft"
    echo "Reason Code: adapter-slot"
    echo "Hint: runner=${_RUNNER} 어댑터는 현재 구현되지 않아 sequential-like 동작으로 간주합니다."
    exit 0
    ;;
esac
