#!/usr/bin/env bash
set -euo pipefail

SESSION_ID="${1:-}"
WORKER_NAME="${2:-}"
ROOT="${3:-.}"
RESULT="${4:-attempt}"
DETAIL="${5:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${SESSION_ID}" || -z "${WORKER_NAME}" ]]; then
  echo "Usage: $0 <session-id> <worker-name> [project-root] [result] [detail]"
  exit 1
fi

# shellcheck source=./git-worktree-lib.sh
source "${SCRIPT_DIR}/git-worktree-lib.sh"

PROJECT_ROOT="$(resolve_shared_project_root "${ROOT}")"
TELEMETRY_DIR="${PROJECT_ROOT}/.company-runtime/telemetry"
TELEMETRY_FILE="${TELEMETRY_DIR}/spawn-telemetry.tsv"

mkdir -p "${TELEMETRY_DIR}"

session_name="no-tmux"
window_name="no-window"
pane_count="0"
if command -v tmux >/dev/null 2>&1 && [[ -n "${TMUX:-}" ]]; then
  session_name="$(tmux display-message -p '#S' 2>/dev/null || printf 'unknown')"
  window_name="$(tmux display-message -p '#W' 2>/dev/null || printf 'unknown')"
  pane_count="$(tmux list-panes -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' ')"
fi

timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z' | sed 's/\(..\)$/:\1/')"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "${timestamp}" \
  "${SESSION_ID}" \
  "${WORKER_NAME}" \
  "${session_name}" \
  "${window_name}" \
  "${pane_count}" \
  "${RESULT}" \
  "${DETAIL}" >> "${TELEMETRY_FILE}"

echo "Logged spawn telemetry: ${RESULT} (${WORKER_NAME})"
