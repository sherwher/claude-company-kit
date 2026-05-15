#!/usr/bin/env bash
set -euo pipefail

TEAM_NAME="${1:-}"
ROOT="${2:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${TEAM_NAME}" ]]; then
  echo "Usage: $0 <worker-or-team-name> [project-root]"
  exit 1
fi

# shellcheck source=./skill-pack-lib.sh
source "${SCRIPT_DIR}/skill-pack-lib.sh"

PROJECT_ENABLED_PACKS="$(read_project_enabled_packs_csv "${ROOT}")"
TEAM_PACKS="$(resolve_team_packs_csv "${ROOT}" "${TEAM_NAME}")"
TEAM_SKILLS="$(resolve_team_skills_csv "${ROOT}" "${TEAM_NAME}")"

cat <<EOF
Project Enabled Packs: ${PROJECT_ENABLED_PACKS}
Recommended Worker Packs: ${TEAM_PACKS}
Recommended Skills: ${TEAM_SKILLS}
EOF
