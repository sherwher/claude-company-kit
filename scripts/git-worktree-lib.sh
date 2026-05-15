#!/usr/bin/env bash
set -euo pipefail

sanitize_session_token() {
  local raw="${1:-}"
  printf '%s' "${raw}" | tr -cs '[:alnum:]._- ' '-' | tr ' ' '-'
}

session_branch_name() {
  local session_id="$1"
  printf 'workstream/%s' "$(sanitize_session_token "${session_id}")"
}

generate_session_id() {
  # R14 cleanup: run-session.sh / prepare-session.sh 에 중복 정의되어 있던
  # 함수를 공통 lib 으로 추출. R13 Phase E 에서 두 사본 동시 패치를 맞췄지만
  # 중복 정의 자체가 drift 위험이라 SSOT 일원화. 시그니처:
  #   generate_session_id <topic> [<project_root>]
  # project_root 미지정 시 cwd 사용. 함수는 PROJECT_ROOT 전역에 의존하지 않음
  # (R13 Phase E Option 2 인자화 결과 보존).
  local topic="$1"
  local project_root="${2:-.}"
  local slug=""
  # generic slug 금지 목록 — 이 이름들은 세션 ID로 단독 사용 금지
  local BLACKLISTED_SLUGS="init planning plannning brainstorm design engineering worker-request test-update feature phase default session"
  if [[ -n "${topic}" ]]; then
    slug="$(sanitize_session_token "${topic}" | tr '[:upper:]' '[:lower:]' | sed 's/^-*//; s/-*$//' | cut -c1-32)"
  fi
  if [[ -z "${slug}" ]]; then
    slug="session-$(date '+%m%d-%H%M')"
  fi
  # blacklist 검사
  if echo " ${BLACKLISTED_SLUGS} " | grep -q " ${slug} "; then
    echo "ERROR: Session slug '${slug}' is too generic. Please provide a more specific topic." >&2
    echo "Example: '${slug}-canvas-crop', '${slug}-onboarding-v2'" >&2
    exit 1
  fi
  # 기존 세션/artifacts 디렉토리와 충돌 시 -2, -3 ... suffix 자동 부여
  local base_slug="${slug}"
  local suffix=2
  while [[ -d "${project_root}/.company-runtime/sessions/${slug}" || -d "${project_root}/.company-artifacts/${slug}" ]]; do
    slug="${base_slug}-${suffix}"
    suffix=$((suffix + 1))
    if [[ ${suffix} -gt 99 ]]; then
      echo "ERROR: too many session collisions for '${base_slug}'" >&2
      exit 1
    fi
  done
  printf '%s' "${slug}"
}

session_metadata_path() {
  local project_root="$1"
  local session_id="$2"
  printf '%s/.company-runtime/sessions/%s/session.env' "${project_root}" "${session_id}"
}

resolve_shared_project_root() {
  local candidate_root="$1"
  if [[ -e "${candidate_root}/.company-shared" ]]; then
    cd "${candidate_root}/.company-shared" && pwd
  else
    cd "${candidate_root}" && pwd
  fi
}

worktree_base_dir() {
  local project_root="$1"
  local root_parent
  local root_name

  root_parent="$(cd "$(dirname "${project_root}")" && pwd)"
  root_name="$(basename "${project_root}")"
  printf '%s/.company-worktrees/%s' "${root_parent}" "${root_name}"
}

session_worktree_path() {
  local project_root="$1"
  local session_id="$2"
  printf '%s/%s' "$(worktree_base_dir "${project_root}")" "$(sanitize_session_token "${session_id}")"
}

is_git_repo() {
  local project_root="$1"
  git -C "${project_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

default_base_ref() {
  local project_root="$1"
  git -C "${project_root}" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'HEAD'
}

find_worktree_path_for_branch() {
  local project_root="$1"
  local branch_name="$2"
  local current_path=""
  local current_branch=""

  git -C "${project_root}" worktree list --porcelain | while IFS= read -r line; do
    case "${line}" in
      worktree\ *)
        current_path="${line#worktree }"
        ;;
      branch\ *)
        current_branch="${line#branch }"
        if [[ "${current_branch}" == "refs/heads/${branch_name}" ]]; then
          printf '%s\n' "${current_path}"
          break
        fi
        ;;
      "")
        current_path=""
        current_branch=""
        ;;
    esac
  done
}

ensure_shared_link() {
  local source_path="$1"
  local target_path="$2"

  [[ -e "${source_path}" || -L "${source_path}" ]] || return 0
  [[ -e "${target_path}" || -L "${target_path}" ]] && return 0

  mkdir -p "$(dirname "${target_path}")"
  ln -s "${source_path}" "${target_path}"
}

sync_shared_paths_into_worktree() {
  local project_root="$1"
  local worktree_root="$2"

  ensure_shared_link "${project_root}" "${worktree_root}/.company-shared"
}

ensure_worktree_git_excludes() {
  local worktree_root="$1"
  local exclude_file

  exclude_file="$(git -C "${worktree_root}" rev-parse --git-dir)/info/exclude"
  mkdir -p "$(dirname "${exclude_file}")"
  touch "${exclude_file}"

  while IFS= read -r pattern; do
    grep -qxF "${pattern}" "${exclude_file}" || printf '%s\n' "${pattern}" >> "${exclude_file}"
  done <<'EOF'
/.company-shared
EOF
}

write_session_metadata() {
  local project_root="$1"
  local session_id="$2"
  local worktree_enabled="$3"
  local worktree_root="$4"
  local branch_name="$5"
  local base_ref="$6"
  local metadata_path

  metadata_path="$(session_metadata_path "${project_root}" "${session_id}")"
  mkdir -p "$(dirname "${metadata_path}")"
  {
    printf 'SESSION_ID=%q\n' "${session_id}"
    printf 'PROJECT_ROOT=%q\n' "${project_root}"
    printf 'WORKTREE_ENABLED=%q\n' "${worktree_enabled}"
    printf 'WORKTREE_ROOT=%q\n' "${worktree_root}"
    printf 'WORKTREE_BRANCH=%q\n' "${branch_name}"
    printf 'WORKTREE_BASE_REF=%q\n' "${base_ref}"
  } > "${metadata_path}"
}

load_session_metadata() {
  local project_root="$1"
  local session_id="$2"
  local metadata_path

  metadata_path="$(session_metadata_path "${project_root}" "${session_id}")"
  if [[ -f "${metadata_path}" ]]; then
    # shellcheck disable=SC1090
    source "${metadata_path}"
    return 0
  fi

  return 1
}
