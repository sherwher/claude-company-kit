#!/usr/bin/env bash
set -euo pipefail

# resume-worker.sh — 리더가 company-approve.sh 로 승인 마커를 만든 뒤,
# 기존 워커 pane 을 실행 단계(execution)로 재투입하기 위한 resume-request.md 를 생성한다.
#
# 설계 배경: 승인 게이트(templates/worker-system-prompt.md)가 compact-plan.md
# 외 파일 쓰기를 금지하므로, 워커는 plan 작성 직후 turn 을 종료한다. 기존에는
# `approved` 마커 생성 후 워커에게 "이제 실행하라"고 지시하는 경로가 없어
# "20 tool uses 근처에서 조기 종료, 실제 변경 0" 증상이 반복됐다.
#
# 이 스크립트는 그 루프를 닫는다:
#   1) approved 마커 존재 검증
#   2) templates/worker-execution-prompt.md 를 session-local resume-request.md 로 렌더
#   3) 리더가 워커 pane 에 붙여넣을 추천 명령 출력
#   4) (v1.3.6) --auto-inject 플래그 시 워커 pane 에 tmux send-keys 로 자동 주입
#
# v1.3.2: 승인 후 재투입 경로 추가.
# v1.3.6: --auto-inject (또는 COMPANY_RESUME_AUTO_INJECT=1) 로 자동 주입. 기본은 dry-run.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./git-worktree-lib.sh
source "${SCRIPT_DIR}/git-worktree-lib.sh"

usage() {
  cat <<EOF
Usage: $0 <session-id> [worker-name] [project-root] [--auto-inject] [--dry-run]

리더 승인(approved 마커) 이후, 지정한 워커(또는 세션 내 모든 워커)에
대해 resume-request.md 를 생성합니다.

Options:
  (worker-name 생략 시 세션 내 전 워커를 순회)
  --auto-inject      tmux send-keys 로 워커 pane 에 자동 주입 (pane_current_command=claude 만)
  --dry-run          주입 없이 대상 pane 과 명령만 출력 (자동 주입 기본값)

Env:
  COMPANY_RESUME_AUTO_INJECT=1   --auto-inject 와 동일

Example:
  $0 session-0414-1830                                 # 전 워커 resume (dry-run)
  $0 session-0414-1830 service-planner --auto-inject   # 단일 워커 자동 주입
EOF
  exit 1
}

# v1.3.6: 포지셔널 vs 플래그 파싱 — 뒤쪽에 --auto-inject / --dry-run 를 자유롭게 둘 수 있도록
SESSION_ID=""
WORKER_NAME=""
ROOT="."
AUTO_INJECT=0
if [[ "${COMPANY_RESUME_AUTO_INJECT:-0}" == "1" ]]; then AUTO_INJECT=1; fi

_positional_idx=0
for _arg in "$@"; do
  case "${_arg}" in
    --auto-inject) AUTO_INJECT=1 ;;
    --dry-run)     AUTO_INJECT=0 ;;
    --help|-h)     usage ;;
    -*)            echo "Unknown option: ${_arg}" >&2; usage ;;
    *)
      case "${_positional_idx}" in
        0) SESSION_ID="${_arg}" ;;
        1) WORKER_NAME="${_arg}" ;;
        2) ROOT="${_arg}" ;;
        *) echo "Unexpected positional arg: ${_arg}" >&2; usage ;;
      esac
      _positional_idx=$((_positional_idx + 1))
      ;;
  esac
done

[[ -z "${SESSION_ID}" ]] && usage

PROJECT_ROOT="$(resolve_shared_project_root "${ROOT}")"
SESSION_DIR="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}"
APPROVED_MARKER="${SESSION_DIR}/approved"
WORKERS_DIR="${SESSION_DIR}/workers"

if [[ ! -d "${SESSION_DIR}" ]]; then
  echo "Error: 세션이 존재하지 않습니다: ${SESSION_ID}" >&2
  exit 2
fi

if [[ ! -f "${APPROVED_MARKER}" ]]; then
  echo "Error: approved 마커가 없습니다. 먼저 'company approve ${SESSION_ID}' 를 실행하세요." >&2
  echo "       경로: ${APPROVED_MARKER}" >&2
  exit 3
fi

# 실행 프롬프트 템플릿 경로 (source repo vs installed kit 모두 대응)
EXEC_TMPL=""
for _cand in \
  "${SCRIPT_DIR}/../templates/worker-execution-prompt.md" \
  "${PROJECT_ROOT}/.company-kit/templates/worker-execution-prompt.md"; do
  if [[ -f "${_cand}" ]]; then
    EXEC_TMPL="${_cand}"
    break
  fi
done

if [[ -z "${EXEC_TMPL}" ]]; then
  echo "Error: worker-execution-prompt.md 템플릿을 찾지 못했습니다." >&2
  echo "       검색 경로: templates/worker-execution-prompt.md, .company-kit/templates/worker-execution-prompt.md" >&2
  exit 4
fi

render_resume_request() {
  local _worker="$1"
  local _worker_dir="${WORKERS_DIR}/${_worker}"
  if [[ ! -d "${_worker_dir}" ]]; then
    echo "SKIP: ${_worker} — 워커 디렉토리 없음 (${_worker_dir})" >&2
    return 0
  fi
  if [[ ! -f "${_worker_dir}/compact-plan.md" ]]; then
    echo "SKIP: ${_worker} — compact-plan.md 부재" >&2
    return 0
  fi

  local _out="${_worker_dir}/resume-request.md"
  sed \
    -e "s|{{SESSION_ID}}|${SESSION_ID}|g" \
    -e "s|{{WORKER_NAME}}|${_worker}|g" \
    -e "s|{{SHARED_PREFIX}}|${PROJECT_ROOT}|g" \
    -e "s|{{PROJECT_ROOT}}|${PROJECT_ROOT}|g" \
    "${EXEC_TMPL}" > "${_out}"

  local _inject_line="${_worker} 워커: ${_out} 를 읽고 실행 단계로 진행해 주세요."

  echo "Rendered resume-request: ${_out}"

  # v1.3.6: 자동 주입 경로 — tmux send-keys. 안전 게이트:
  #   1. AUTO_INJECT=1 일 때만 시도
  #   2. tmux 실재 + 현재 tmux 안에서 실행 중 (TMUX env 존재)
  #   3. pane_current_command == "claude" 인 pane 만 대상 (#W == _worker 로 1차 필터)
  #   4. 동일 세션/워커에 resume_injected 마커 있으면 skip (멱등)
  local _injected_marker="${_worker_dir}/resume_injected"
  local _inject_status="skipped"
  local _target_pane=""
  if [[ "${AUTO_INJECT}" == "1" ]]; then
    if [[ -f "${_injected_marker}" ]]; then
      _inject_status="already-injected"
    elif [[ -z "${TMUX:-}" ]] || ! command -v tmux >/dev/null 2>&1; then
      _inject_status="no-tmux"
    else
      # window name == worker 또는 pane_current_command == claude 인 pane 탐색
      _target_pane="$(tmux list-panes -a -F '#{pane_id}|#{window_name}|#{pane_current_command}' 2>/dev/null \
        | awk -F'|' -v w="${_worker}" '
            $3 == "claude" && ($2 == w || $2 ~ "^"w"$") {print $1; exit}
          ')"
      if [[ -z "${_target_pane}" ]]; then
        # fallback: pane_current_command == claude 인 첫 pane (window name 무관)
        _target_pane="$(tmux list-panes -a -F '#{pane_id}|#{pane_current_command}' 2>/dev/null \
          | awk -F'|' '$2 == "claude" {print $1; exit}')"
      fi
      if [[ -n "${_target_pane}" ]]; then
        tmux send-keys -t "${_target_pane}" "${_inject_line}" 2>/dev/null || true
        tmux send-keys -t "${_target_pane}" Enter 2>/dev/null || true
        printf 'injected_at: %s\npane_id: %s\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${_target_pane}" > "${_injected_marker}"
        _inject_status="injected@${_target_pane}"
      else
        _inject_status="no-claude-pane"
      fi
    fi
  fi

  echo ""
  if [[ "${AUTO_INJECT}" == "1" && "${_inject_status}" == injected@* ]]; then
    echo "  ✅ 자동 주입 완료 (${_inject_status})"
  else
    echo "  리더: 해당 워커 pane 에 아래 한 줄을 붙여넣어 실행 단계로 재투입하세요."
    echo "  ────────────────────────────────────────────────"
    echo "  ${_inject_line}"
    echo "  ────────────────────────────────────────────────"
    if [[ "${AUTO_INJECT}" == "1" ]]; then
      echo "  (auto-inject 시도 결과: ${_inject_status})"
    fi
  fi
  echo ""

  # 이벤트 로거 — worker_resumed (주입 상태 + runner 메타)
  _resume_runner="${COMPANY_RUNNER:-}"
  if [[ -z "${_resume_runner}" ]]; then
    _resume_pf="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/preflight.json"
    if [[ -f "${_resume_pf}" ]] && command -v jq >/dev/null 2>&1; then
      _resume_runner="$(jq -r '.runner // empty' "${_resume_pf}" 2>/dev/null || printf '')"
    fi
  fi
  bash "${SCRIPT_DIR}/company-emit.sh" "worker_resumed" "${SESSION_ID}" "${PROJECT_ROOT}" \
    "worker=${_worker}" "inject_status=${_inject_status}" "runner=${_resume_runner:-unknown}" >/dev/null 2>&1 || true
}

if [[ -n "${WORKER_NAME}" ]]; then
  render_resume_request "${WORKER_NAME}"
else
  found=0
  while IFS= read -r _wd; do
    [[ -d "${_wd}" ]] || continue
    found=$((found + 1))
    render_resume_request "$(basename "${_wd}")"
  done < <(find "${WORKERS_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  if [[ "${found}" -eq 0 ]]; then
    echo "WARN: 세션에 워커가 없습니다 — prepare-worker.sh 를 먼저 실행하세요." >&2
    exit 5
  fi
fi

echo "✓ Resume 요청 준비 완료: ${SESSION_ID}"
