#!/usr/bin/env bash
set -euo pipefail

TOPIC="${1:-}"
PRIMARY_WORKER="${2:-}"
FEEDBACK="${3:-}"
ROOT="${4:-.}"
SUPPORT_WORKERS="${5:-none}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${TOPIC}" || -z "${PRIMARY_WORKER}" || -z "${FEEDBACK}" ]]; then
  echo "Usage: $0 <topic> <primary-worker> <feedback> [project-root] [support-workers]"
  exit 1
fi

case "${FEEDBACK}" in
  good|overkill|insufficient|wrong-worker)
    ;;
  *)
    echo "Invalid feedback: ${FEEDBACK}"
    echo "Allowed values: good, overkill, insufficient, wrong-worker"
    exit 1
    ;;
esac

# shellcheck source=./git-worktree-lib.sh
source "${SCRIPT_DIR}/git-worktree-lib.sh"

PROJECT_ROOT="$(resolve_shared_project_root "${ROOT}")"
FEEDBACK_FILE="${PROJECT_ROOT}/.company-project/routing-feedback.md"
TIMESTAMP="$(date '+%Y-%m-%d')"

mkdir -p "$(dirname "${FEEDBACK_FILE}")"
if [[ ! -f "${FEEDBACK_FILE}" ]]; then
  cat > "${FEEDBACK_FILE}" <<'EOF'
# Routing Feedback

이 파일은 리더가 라우팅 결과를 짧게 평가하는 곳입니다.

권장 태그:

- `good`
- `overkill`
- `insufficient`
- `wrong-worker`
EOF
fi

printf -- '- %s | %s | primary=`%s` | support=`%s` | feedback=`%s`\n' \
  "${TIMESTAMP}" \
  "${TOPIC}" \
  "${PRIMARY_WORKER}" \
  "${SUPPORT_WORKERS}" \
  "${FEEDBACK}" >> "${FEEDBACK_FILE}"

echo "Recorded routing feedback: ${FEEDBACK} (${PRIMARY_WORKER})"
