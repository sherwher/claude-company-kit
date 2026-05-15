#!/usr/bin/env bash
set -euo pipefail

SESSION_ID="${1:-}"
ROOT="${2:-.}"
BASE_REF="${3:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${SESSION_ID}" ]]; then
  echo "Usage: $0 <session-id> [project-root] [base-ref]"
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git is required"
  exit 1
fi

# shellcheck source=./git-worktree-lib.sh
source "${SCRIPT_DIR}/git-worktree-lib.sh"

PROJECT_ROOT="$(resolve_shared_project_root "${ROOT}")"

if ! is_git_repo "${PROJECT_ROOT}"; then
  echo "Project root is not a git repository: ${PROJECT_ROOT}"
  exit 1
fi

BRANCH_NAME="$(session_branch_name "${SESSION_ID}")"
WORKTREE_ROOT="$(session_worktree_path "${PROJECT_ROOT}" "${SESSION_ID}")"
BASE_REF="${BASE_REF:-$(default_base_ref "${PROJECT_ROOT}")}"
EXISTING_WORKTREE_PATH="$(find_worktree_path_for_branch "${PROJECT_ROOT}" "${BRANCH_NAME}" || true)"

mkdir -p "$(worktree_base_dir "${PROJECT_ROOT}")"

if [[ -n "${EXISTING_WORKTREE_PATH}" ]]; then
  WORKTREE_ROOT="${EXISTING_WORKTREE_PATH}"
elif [[ -d "${WORKTREE_ROOT}/.git" || -f "${WORKTREE_ROOT}/.git" ]]; then
  :
elif git -C "${PROJECT_ROOT}" show-ref --verify --quiet "refs/heads/${BRANCH_NAME}"; then
  git -C "${PROJECT_ROOT}" worktree add "${WORKTREE_ROOT}" "${BRANCH_NAME}" >/dev/null
else
  git -C "${PROJECT_ROOT}" worktree add -b "${BRANCH_NAME}" "${WORKTREE_ROOT}" "${BASE_REF}" >/dev/null
fi

sync_shared_paths_into_worktree "${PROJECT_ROOT}" "${WORKTREE_ROOT}"
ensure_worktree_git_excludes "${WORKTREE_ROOT}"
write_session_metadata "${PROJECT_ROOT}" "${SESSION_ID}" "1" "${WORKTREE_ROOT}" "${BRANCH_NAME}" "${BASE_REF}"

echo "Session: ${SESSION_ID}"
echo "Project Root: ${PROJECT_ROOT}"
echo "Worktree Root: ${WORKTREE_ROOT}"
echo "Branch: ${BRANCH_NAME}"
