#!/usr/bin/env bash
set -euo pipefail

# cmux-start-worker.sh
#
# Start a prepared worker in a new cmux split and record its target marker.
# This covers the mechanical part that is easy to get wrong by hand:
# split pane -> parse surface id -> write cmux-target -> launch Claude -> emit
# spawn markers. Submit the first prompt with cmux-submit-worker-message.sh
# after Claude is visibly ready for input.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./git-worktree-lib.sh
source "${SCRIPT_DIR}/git-worktree-lib.sh"
# shellcheck source=./runner-lib.sh
source "${SCRIPT_DIR}/runner-lib.sh"
# shellcheck source=./cmux-lib.sh
source "${SCRIPT_DIR}/cmux-lib.sh"

SESSION_ID="${1:-}"
WORKER_NAME="${2:-}"
PROJECT_ROOT_ARG="${3:-.}"
DIRECTION="${4:-right}"
PERMISSION_MODE="${COMPANY_WORKER_PERMISSION_MODE:-acceptEdits}"

if [[ -z "${SESSION_ID}" || -z "${WORKER_NAME}" ]]; then
  echo "Usage: $0 <session_id> <worker_name> [project_root] [right|left|up|down]" >&2
  echo "  COMPANY_WORKER_PERMISSION_MODE=<mode>  permission mode (default: acceptEdits)" >&2
  echo "                                          allowed: acceptEdits | default | plan" >&2
  echo "                                          forbidden: bypassPermissions (see docs/design/permission-modes.md)" >&2
  exit 1
fi
case "${DIRECTION}" in
  right|left|up|down) ;;
  *) echo "cmux-start-worker: invalid direction: ${DIRECTION}" >&2; exit 1 ;;
esac

# v1.5.6: bypassPermissions 거부 — 워커는 plan-required 게이트와 정합해야 함.
# 자세한 사유는 docs/design/permission-modes.md 참고.
case "${PERMISSION_MODE}" in
  acceptEdits|default|plan) ;;
  bypassPermissions)
    cat >&2 <<'EOF'
[ERROR] bypassPermissions 는 워커 권한 모드로 허용되지 않습니다.
        사유: plan-required 게이트 우회 + Claude Code auto mode classifier 자동 차단.

💡 대안:
  - acceptEdits (기본) 유지 + 자주 쓰는 명령은 .claude/settings.json 의 permissions.allow 추가
  - 권한 게이트 답답하면 cmux-leader-watcher 의 자동 알림 활용
  - 자세한 정책: docs/design/permission-modes.md
EOF
    exit 8
    ;;
  *)
    echo "cmux-start-worker: unknown permission mode: ${PERMISSION_MODE}" >&2
    echo "  허용: acceptEdits | default | plan" >&2
    exit 9
    ;;
esac

command -v cmux >/dev/null 2>&1 || { echo "cmux-start-worker: cmux not found" >&2; exit 2; }
[[ -n "${CMUX_PANEL_ID:-}" || -n "${CMUX_WORKSPACE_ID:-}" ]] || {
  echo "cmux-start-worker: not inside a cmux workspace" >&2
  exit 3
}

PROJECT_ROOT="$(resolve_shared_project_root "${PROJECT_ROOT_ARG}")"

# v1.5.6: git repo precheck — cmux runner 는 worktree 기반이므로 git 필수.
# 미충족 시 silent fail 대신 명확한 메시지 + 복구 가이드.
runner_load cmux 2>/dev/null || true
if declare -f runner_cmux_precheck_git_repo >/dev/null 2>&1; then
  runner_cmux_precheck_git_repo "${PROJECT_ROOT}" || exit 7
fi
SESSION_DIR="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}"
WORKER_DIR="${SESSION_DIR}/workers/${WORKER_NAME}"
TARGET_FILE="${WORKER_DIR}/cmux-target"
PROMPT_FILE="${WORKER_DIR}/worker-system-prompt.assembled.md"

if [[ ! -d "${WORKER_DIR}" ]]; then
  echo "cmux-start-worker: worker not prepared: ${WORKER_DIR}" >&2
  echo "Run: bash .company-kit/scripts/prepare-worker.sh ${SESSION_ID} ${WORKER_NAME} ${PROJECT_ROOT}" >&2
  exit 4
fi
if [[ ! -f "${PROMPT_FILE}" ]]; then
  echo "cmux-start-worker: assembled prompt missing: ${PROMPT_FILE}" >&2
  exit 5
fi

WORK_ROOT="${PROJECT_ROOT}"
if [[ -f "${SESSION_DIR}/session.env" ]]; then
  # shellcheck disable=SC1090
  source "${SESSION_DIR}/session.env"
  if [[ "${WORKTREE_ENABLED:-0}" == "1" && -n "${WORKTREE_ROOT:-}" && -d "${WORKTREE_ROOT}" ]]; then
    WORK_ROOT="${WORKTREE_ROOT}"
  fi
fi

SURFACE="$(cmux_new_split_surface "${DIRECTION}")" || exit 6
printf '%s\n' "${SURFACE}" > "${TARGET_FILE}"

LAUNCH_CMD="cd ${WORK_ROOT} && claude --model sonnet --permission-mode ${PERMISSION_MODE} --add-dir ${PROJECT_ROOT} --append-system-prompt-file ${PROMPT_FILE}"
cmux_submit_text "${SURFACE}" "${LAUNCH_CMD}"

runner_load cmux 2>/dev/null || true
if declare -f runner_cmux_spawn_worker >/dev/null 2>&1; then
  runner_cmux_spawn_worker "${SESSION_ID}" "${WORKER_NAME}" "${PROJECT_ROOT}" >/dev/null 2>&1 || true
fi
bash "${SCRIPT_DIR}/verify-worker-spawn.sh" "${SESSION_ID}" "${WORKER_NAME}" "${PROJECT_ROOT}" >/dev/null 2>&1 || true

# v1.5.6: Claude Code ready polling — launch 후 prompt 박스가 활성화될 때까지
# 최대 30초 대기. 너무 빠른 submit 으로 인한 paste swallow 방지.
# 환경변수 COMPANY_SKIP_READY_POLLING=1 로 우회 가능.
if [[ -z "${COMPANY_SKIP_READY_POLLING:-}" ]]; then
  ready_attempts=0
  ready_max=60
  while (( ready_attempts < ready_max )); do
    capture="$(cmux capture-pane --surface "${SURFACE#surface:}" 2>/dev/null || true)"
    if printf '%s' "${capture}" | grep -qE 'What would you like|esc to interrupt|accept edits|bypass|^[[:space:]]*>[[:space:]]*$' 2>/dev/null; then
      break
    fi
    ready_attempts=$((ready_attempts + 1))
    sleep 0.5
  done
  if (( ready_attempts >= ready_max )); then
    echo "[WARN] Claude Code ready 감지 실패 (${ready_max}*0.5s 경과). 그래도 submit 하면 paste 가 swallow 될 수 있습니다." >&2
  fi
fi

echo "Started ${WORKER_NAME} on ${SURFACE} (permission-mode=${PERMISSION_MODE})."
echo "Ready check: $((ready_attempts * 5 / 10))s waited."
echo "When Claude is ready, submit the request with:"
echo "  bash .company-kit/scripts/cmux-submit-worker-message.sh ${SESSION_ID} ${WORKER_NAME} ${PROJECT_ROOT}"
