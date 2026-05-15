#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./manifest-lib.sh
source "${SCRIPT_DIR}/manifest-lib.sh"

csv_to_lines() {
  printf '%s\n' "${1:-}" | tr ',' '\n' | while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    local line
    line="$(strip_comment_and_trim "${raw_line}")"
    [[ -n "${line}" ]] && printf '%s\n' "${line}"
  done
}

unique_lines() {
  awk 'NF && !seen[$0]++'
}

lines_to_csv() {
  paste -sd',' -
}

default_project_pack_lines() {
  cat <<'EOF'
core
research
review
frontend
backend
design
docs
EOF
}

default_team_pack_lines() {
  local team_name="$1"

  case "${team_name}" in
    strategy|strategy-planner)
      cat <<'EOF'
core
research
docs
EOF
      ;;
    planning|service-planner|brainstorm|brainstormer)
      cat <<'EOF'
core
research
docs
design
EOF
      ;;
    fullstack-architect|engineering)
      cat <<'EOF'
core
frontend
backend
review
EOF
      ;;
    frontend-engineer)
      cat <<'EOF'
core
frontend
design
review
EOF
      ;;
    backend-engineer|qa-reviewer)
      cat <<'EOF'
core
backend
review
EOF
      ;;
    data|data-analyst)
      cat <<'EOF'
core
research
review
EOF
      ;;
    marketing|growth-marketer)
      cat <<'EOF'
core
research
docs
design
EOF
      ;;
    risk|risk-reviewer)
      cat <<'EOF'
core
research
review
docs
EOF
      ;;
    proposal|proposal-writer)
      cat <<'EOF'
core
research
docs
review
EOF
      ;;
    *)
      default_project_pack_lines
      ;;
  esac
}

read_project_enabled_pack_lines() {
  local root="$1"
  local file_path="${root}/.company-project/skills/enabled-packs.txt"

  if [[ -f "${file_path}" ]]; then
    read_nonempty_lines "${file_path}"
  else
    default_project_pack_lines
  fi
}

read_team_override_pack_lines() {
  local root="$1"
  local team_name="$2"
  local file_path="${root}/.company-project/skills/team-pack-overrides.txt"

  [[ -f "${file_path}" ]] || return 0

  while IFS= read -r raw_line; do
    local line
    line="$(strip_comment_and_trim "${raw_line}")"
    [[ -n "${line}" ]] || continue
    [[ "${line}" == *:* ]] || continue

    local key="${line%%:*}"
    local value="${line#*:}"
    key="$(strip_comment_and_trim "${key}")"
    value="$(strip_comment_and_trim "${value}")"

    if [[ "${key}" == "${team_name}" ]]; then
      csv_to_lines "${value}"
      return 0
    fi
  done < "${file_path}"
}

resolve_team_pack_lines() {
  local root="$1"
  local team_name="$2"
  local override_lines

  override_lines="$(read_team_override_pack_lines "${root}" "${team_name}" || true)"

  if [[ -n "${override_lines}" ]]; then
    printf '%s\n' "${override_lines}" | unique_lines
  else
    default_team_pack_lines "${team_name}" | unique_lines
  fi
}

resolve_skill_lines_for_packs() {
  local root="$1"
  local pack_lines="$2"
  local kit_root="${root}/.company-kit"

  while IFS= read -r pack_name; do
    [[ -n "${pack_name}" ]] || continue
    read_nonempty_lines "${kit_root}/skills/packs/${pack_name}.txt"
  done <<< "${pack_lines}" | unique_lines
}

read_project_enabled_packs_csv() {
  local root="$1"
  read_project_enabled_pack_lines "${root}" | unique_lines | lines_to_csv
}

resolve_team_packs_csv() {
  local root="$1"
  local team_name="$2"
  resolve_team_pack_lines "${root}" "${team_name}" | unique_lines | lines_to_csv
}

resolve_team_skills_csv() {
  local root="$1"
  local team_name="$2"
  local pack_lines

  pack_lines="$(resolve_team_pack_lines "${root}" "${team_name}")"
  resolve_skill_lines_for_packs "${root}" "${pack_lines}" | unique_lines | lines_to_csv
}
