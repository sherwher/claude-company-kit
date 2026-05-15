#!/usr/bin/env bash
# reset.sh — 패닉 버튼: 모든 세션/worktree 클린업
# 사용:
#   bash .company-kit/scripts/reset.sh [--hard]
#   bash .company-kit/scripts/reset.sh --cmux-stale --dry-run
#   bash .company-kit/scripts/reset.sh --cmux-stale --confirm <YYYYMMDD-cmux-stale>
set -euo pipefail

HARD=""
CMUX_STALE=""
DRY_RUN=""
CONFIRM_TOKEN=""
PROJECT_ROOT="$(pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hard)
      HARD="1"
      shift
      ;;
    --cmux-stale)
      CMUX_STALE="1"
      shift
      ;;
    --dry-run)
      DRY_RUN="1"
      shift
      ;;
    --confirm)
      [[ $# -ge 2 ]] || { echo "reset: --confirm requires a token" >&2; exit 2; }
      CONFIRM_TOKEN="$2"
      shift 2
      ;;
    *)
      echo "reset: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

_today_token="$(date +%Y%m%d)-cmux-stale"

_is_suspicious_cmux_slug() {
  local slug="$1"
  case "${slug}" in
    \#*|--*|help) return 0 ;;
    *) return 1 ;;
  esac
}

_print_stale_candidates() {
  local found=0
  local sessions_dir="${PROJECT_ROOT}/.company-runtime/sessions"
  echo "[cmux-stale] 후보 목록"
  echo "  confirm token: ${_today_token}"

  if [[ -d "${sessions_dir}" ]]; then
    while IFS= read -r dir; do
      [[ -n "${dir}" && -d "${dir}" ]] || continue
      slug="$(basename "${dir}")"
      if _is_suspicious_cmux_slug "${slug}"; then
        found=1
        mtime="$(date -r "${dir}" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || printf 'unknown')"
        echo "  session  ${dir}  reason=suspicious-slug(${slug}) mtime=${mtime}"
      fi
    done < <(find "${sessions_dir}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  fi

  if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    main_root="$(git rev-parse --show-toplevel)"
    current_wt=""
    while IFS= read -r line; do
      case "${line}" in
        worktree\ *)
          current_wt="${line#worktree }"
          ;;
        "")
          if [[ -n "${current_wt}" && "${current_wt}" != "${main_root}" ]]; then
            if git -C "${current_wt}" status --porcelain 2>/dev/null | grep -q .; then
              :
            else
              found=1
              echo "  worktree ${current_wt}  reason=clean-linked-worktree"
            fi
          fi
          current_wt=""
          ;;
      esac
    done < <(git worktree list --porcelain 2>/dev/null; printf '\n')
  fi

  if (( found == 0 )); then
    echo "  (none)"
  fi
}

_delete_stale_candidates() {
  local sessions_dir="${PROJECT_ROOT}/.company-runtime/sessions"

  if [[ "${CONFIRM_TOKEN}" != "${_today_token}" ]]; then
    echo "reset: --confirm token mismatch" >&2
    echo "       expected: ${_today_token}" >&2
    exit 2
  fi

  if [[ -d "${sessions_dir}" ]]; then
    while IFS= read -r dir; do
      [[ -n "${dir}" && -d "${dir}" ]] || continue
      slug="$(basename "${dir}")"
      if _is_suspicious_cmux_slug "${slug}"; then
        rm -rf "${dir}"
        echo "  removed session: ${dir}"
      fi
    done < <(find "${sessions_dir}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  fi

  if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    main_root="$(git rev-parse --show-toplevel)"
    current_wt=""
    while IFS= read -r line; do
      case "${line}" in
        worktree\ *)
          current_wt="${line#worktree }"
          ;;
        "")
          if [[ -n "${current_wt}" && "${current_wt}" != "${main_root}" ]]; then
            if git -C "${current_wt}" status --porcelain 2>/dev/null | grep -q .; then
              echo "  skip dirty worktree: ${current_wt}"
            else
              git worktree remove "${current_wt}" 2>/dev/null \
                && echo "  removed worktree: ${current_wt}" \
                || echo "  failed worktree remove: ${current_wt}"
            fi
          fi
          current_wt=""
          ;;
      esac
    done < <(git worktree list --porcelain 2>/dev/null; printf '\n')
  fi
}

echo "=== company reset ==="
echo "Project: ${PROJECT_ROOT}"
echo ""

if [[ -n "${CMUX_STALE}" ]]; then
  if [[ -n "${DRY_RUN}" || -z "${CONFIRM_TOKEN}" ]]; then
    _print_stale_candidates
    echo ""
    echo "삭제하려면: bash .company-kit/scripts/reset.sh --cmux-stale --confirm ${_today_token}"
    exit 0
  fi
  echo "[cmux-stale] confirm token verified"
  _delete_stale_candidates
  exit 0
fi

# 1. attached 러너 세션 정리 (tmux 만 — cmux 는 workspace kill API 가 별도 흐름이므로 자동 정리하지 않음)
if command -v tmux &>/dev/null; then
  SESSIONS=$(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^company-" || true)
  if [[ -n "${SESSIONS}" ]]; then
    echo "[tmux] 세션 종료 중..."
    echo "${SESSIONS}" | xargs -I{} tmux kill-session -t {} 2>/dev/null || true
    echo "[tmux] 완료: ${SESSIONS}"
  else
    echo "[tmux] 정리할 company- 세션 없음"
  fi
fi
if [[ -n "${CMUX_PANEL_ID:-}${CMUX_WORKSPACE_ID:-}" ]]; then
  echo "[cmux] cmux workspace 자동 종료는 지원하지 않습니다. cmux UI 에서 직접 닫아 주세요."
fi

# 2. git worktree 정리
if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  WORKTREES=$(git worktree list --porcelain 2>/dev/null | grep "^worktree " | awk '{print $2}' | grep -v "^$(git rev-parse --show-toplevel)$" || true)
  if [[ -n "${WORKTREES}" ]]; then
    echo "[worktree] 워크트리 제거 중..."
    while IFS= read -r wt; do
      git worktree remove --force "${wt}" 2>/dev/null && echo "  제거: ${wt}" || echo "  실패(수동 확인): ${wt}"
    done <<< "${WORKTREES}"
  else
    echo "[worktree] 정리할 추가 워크트리 없음"
  fi
fi

# 3. runtime 초기화 (--hard 옵션 시)
if [[ -n "${HARD}" ]]; then
  echo "[hard] .company-runtime/ 초기화..."
  if [[ -d ".company-runtime" ]]; then
    rm -rf ".company-runtime/sessions" && mkdir -p ".company-runtime/sessions"
    echo "[hard] sessions 디렉토리 초기화 완료"
  fi
  echo ""
  echo "⚠️  --hard 모드: session 기록이 삭제됐습니다."
fi

echo ""
# 동적 라벨: 현재 환경에서 우선 시도할 러너 이름을 노출.
_reset_label="tmux"
if [[ -z "${TMUX:-}" && -n "${CMUX_PANEL_ID:-}${CMUX_WORKSPACE_ID:-}" ]]; then
  _reset_label="cmux"
fi
echo "✓ 리셋 완료. attached 러너 (${_reset_label}) 세션에서 Claude를 다시 실행한 뒤 /rw <topic> 으로 시작하세요."
