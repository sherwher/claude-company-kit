#!/usr/bin/env bash
set -euo pipefail

# ── 인자 파싱 ──
ROOT=""
PROJECT_NAME=""
PROJECT_DOMAIN=""
PROJECT_STACK=""
PRIMARY_WORKER="service-planner"
SUPPORTING_WORKERS=""

for arg in "$@"; do
  case "${arg}" in
    --name=*)        PROJECT_NAME="${arg#--name=}" ;;
    --domain=*)      PROJECT_DOMAIN="${arg#--domain=}" ;;
    --stack=*)       PROJECT_STACK="${arg#--stack=}" ;;
    --primary-worker=*)     PRIMARY_WORKER="${arg#--primary-worker=}" ;;
    --supporting-workers=*) SUPPORTING_WORKERS="${arg#--supporting-workers=}" ;;
    -*)              ;;  # unknown flags: silently skip (called from install script)
    *)
      if [[ -z "${ROOT}" ]]; then
        ROOT="${arg}"
      fi
      ;;
  esac
done

ROOT="${ROOT:-.}"
KIT_DIR="${ROOT}/.company-kit"
SAMPLE_DIR="${KIT_DIR}/scaffold/project-root-sample"
CONFIG_DIR="${KIT_DIR}/config"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -d "${KIT_DIR}" ]]; then
  echo "Missing ${KIT_DIR}"
  echo "Run this script from a project root that already contains .company-kit/."
  exit 1
fi

# shellcheck source=./manifest-lib.sh
source "${SCRIPT_DIR}/manifest-lib.sh"

while IFS= read -r dir_path; do
  mkdir -p "${ROOT}/${dir_path}"
done < <(read_nonempty_lines "${CONFIG_DIR}/init-directories.txt")

copy_if_missing() {
  local source_path="$1"
  local target_path="$2"

  if [[ -f "${source_path}" && ! -e "${target_path}" ]]; then
    mkdir -p "$(dirname "${target_path}")"
    cp "${source_path}" "${target_path}"
    echo "Created ${target_path}"
  fi
}

while IFS=$'\t' read -r source_base source_rel target_rel; do
  [[ -n "${source_base}" && -n "${source_rel}" && -n "${target_rel}" ]] || continue

  case "${source_base}" in
    kit)
      copy_if_missing "${KIT_DIR}/${source_rel}" "${ROOT}/${target_rel}"
      ;;
    sample)
      copy_if_missing "${SAMPLE_DIR}/${source_rel}" "${ROOT}/${target_rel}"
      ;;
    *)
      echo "Unknown init manifest source base: ${source_base}"
      exit 1
      ;;
  esac
done < <(read_nonempty_lines "${CONFIG_DIR}/init-files.tsv")

# v1.1.0: .company-template.lock 의 template_version을 현재 VERSION 파일과 동기화.
# 신규 install 시 lock.example의 낡은 버전(1.0.13 등)이 그대로 박혀 update
# 스크립트가 마이그레이션을 오인하는 문제를 방지.
VERSION_FILE="${KIT_DIR}/VERSION"
LOCK_FILE="${ROOT}/.company-template.lock"
if [[ -f "${VERSION_FILE}" && -f "${LOCK_FILE}" ]]; then
  CURRENT_VERSION="$(tr -d '\n' < "${VERSION_FILE}")"
  NOW="$(date '+%Y-%m-%dT%H:%M:%S%z' | sed 's/\(..\)$/:\1/')"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/^template_version:.*/template_version: ${CURRENT_VERSION}/" "${LOCK_FILE}"
    sed -i '' "s/^last_synced_at:.*/last_synced_at: ${NOW}/" "${LOCK_FILE}"
  else
    sed -i "s/^template_version:.*/template_version: ${CURRENT_VERSION}/" "${LOCK_FILE}"
    sed -i "s/^last_synced_at:.*/last_synced_at: ${NOW}/" "${LOCK_FILE}"
  fi
fi

# ── 템플릿 렌더링: install wizard 치환 (플래그 제공 시에만) ──
if [[ -n "${PROJECT_NAME}" || -n "${PROJECT_DOMAIN}" || -n "${PROJECT_STACK}" ]]; then
  # 인터랙티브 프롬프트 (init-cloned-project.sh 직접 호출 시)
  if [[ -z "${PROJECT_NAME}" ]]; then
    printf "프로젝트 이름: "; read -r PROJECT_NAME
  fi
  if [[ -z "${PROJECT_DOMAIN}" ]]; then
    printf "도메인 설명: "; read -r PROJECT_DOMAIN
  fi
  if [[ -z "${PROJECT_STACK}" ]]; then
    printf "기술 스택: "; read -r PROJECT_STACK
  fi
  [[ -z "${PRIMARY_WORKER}" ]]    && PRIMARY_WORKER="service-planner"
  [[ -z "${SUPPORTING_WORKERS}" ]] && SUPPORTING_WORKERS="strategy-planner"

  # .company-kit 내 템플릿 경로 (export 후에는 .company-kit/templates/install/ 에 있음)
  TMPL_DIR="${KIT_DIR}/templates/install"

  # sed replacement에서 특수문자(&, \, |)를 이스케이프
  _sed_escape() { printf '%s\n' "$1" | sed 's/[&\|/\\]/\\&/g'; }

  render_template() {
    local tmpl_src="$1"
    local dest="$2"
    [[ -f "${tmpl_src}" ]] || return 0
    mkdir -p "$(dirname "${dest}")"
    sed \
      -e "s|{{name}}|$(_sed_escape "${PROJECT_NAME}")|g" \
      -e "s|{{domain}}|$(_sed_escape "${PROJECT_DOMAIN}")|g" \
      -e "s|{{stack}}|$(_sed_escape "${PROJECT_STACK}")|g" \
      -e "s|{{primary_worker}}|$(_sed_escape "${PRIMARY_WORKER}")|g" \
      -e "s|{{supporting_workers}}|$(_sed_escape "${SUPPORTING_WORKERS}")|g" \
      "${tmpl_src}" > "${dest}"
    echo "Rendered ${dest}"
  }

  render_template "${TMPL_DIR}/CLAUDE.md.tmpl"            "${ROOT}/CLAUDE.md"
  render_template "${TMPL_DIR}/project-context.md.tmpl"   "${ROOT}/.company-project/project-context.md"
  render_template "${TMPL_DIR}/project-standards.md.tmpl" "${ROOT}/.company-project/project-standards.md"
fi

cat <<'EOF'

Initialization finished.

Quick start:
1. Open START_HERE.md — 3단계 안내만 따르면 됩니다.
2. Fill .company-project/integrations/*.env with credentials.
3. Restart Claude once so it refreshes slash commands.
4. Run: /rw <topic>

Details (막힐 때 참고):
- Review before first run: .claude/settings.json, .company-project/project-standards.md, .company-project/model-policy.md
- Working agreements: project-work/00-project/working-agreements.md
- Skill packs: .company-project/skills/enabled-packs.txt
- Personal overrides: .company-local.env (not committed)
- Bash fallback: .company-kit/scripts/run-session.sh "<topic>"
- Git worktrees: session worktree under ../.company-worktrees/<project>/<session-id>
EOF
