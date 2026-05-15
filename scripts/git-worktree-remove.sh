#!/usr/bin/env bash
set -euo pipefail

SESSION_ID="${1:-}"
ROOT="${2:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${SESSION_ID}" ]]; then
  echo "Usage: $0 <session-id> [project-root]"
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git is required"
  exit 1
fi

# shellcheck source=./git-worktree-lib.sh
source "${SCRIPT_DIR}/git-worktree-lib.sh"

PROJECT_ROOT="$(resolve_shared_project_root "${ROOT}")"

if ! load_session_metadata "${PROJECT_ROOT}" "${SESSION_ID}"; then
  echo "No session metadata found for: ${SESSION_ID}"
  exit 1
fi

if [[ "${WORKTREE_ENABLED:-0}" != "1" ]]; then
  echo "Session does not use a git worktree: ${SESSION_ID}"
  exit 0
fi

if [[ ! -d "${WORKTREE_ROOT}" ]]; then
  echo "Worktree already removed: ${WORKTREE_ROOT}"
  exit 0
fi

if [[ -n "$(git -C "${WORKTREE_ROOT}" status --porcelain --untracked-files=no)" ]]; then
  echo "Worktree has tracked changes. Commit or stash before cleanup: ${WORKTREE_ROOT}"
  exit 1
fi

git -C "${PROJECT_ROOT}" worktree remove --force "${WORKTREE_ROOT}" >/dev/null
git -C "${PROJECT_ROOT}" worktree prune >/dev/null

write_session_metadata "${PROJECT_ROOT}" "${SESSION_ID}" "0" "${PROJECT_ROOT}" "${WORKTREE_BRANCH:-}" "${WORKTREE_BASE_REF:-}"

echo "Removed worktree: ${WORKTREE_ROOT}"
