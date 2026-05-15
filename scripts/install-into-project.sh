#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── 인자 파싱 ──
TARGET_ROOT=""
PROJECT_NAME=""
PROJECT_DOMAIN=""
PROJECT_STACK=""
PRIMARY_WORKER="service-planner"
SUPPORTING_WORKERS=""
CATEGORIES="base,business,engineering,design"

usage() {
  echo "Usage: $0 <target-project-root> [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --name=<name>                  프로젝트 이름 (필수)"
  echo "  --domain=<domain>              도메인 한 줄 설명 (필수)"
  echo "  --stack=<stack>                기술 스택 (필수)"
  echo "  --primary-worker=<worker>      기본 워커 (기본값: service-planner)"
  echo "  --supporting-workers=<list>    쉼표 구분 보조 워커 (선택)"
  echo "  --categories=<list>            agent 카테고리 (기본: base,business,engineering,design)"
  echo "                                 게임 프로젝트: base,business,engineering,design,game"
  echo ""
  echo "Example:"
  echo "  $0 /path/to/my-project --name=MyApp --domain='결제 서비스' --stack=nextjs-ts"
  exit 1
}

for arg in "$@"; do
  case "${arg}" in
    --name=*)        PROJECT_NAME="${arg#--name=}" ;;
    --domain=*)      PROJECT_DOMAIN="${arg#--domain=}" ;;
    --stack=*)       PROJECT_STACK="${arg#--stack=}" ;;
    --primary-worker=*)     PRIMARY_WORKER="${arg#--primary-worker=}" ;;
    --supporting-workers=*) SUPPORTING_WORKERS="${arg#--supporting-workers=}" ;;
    --categories=*)         CATEGORIES="${arg#--categories=}" ;;
    --help|-h)       usage ;;
    -*)              echo "Unknown option: ${arg}"; usage ;;
    *)
      if [[ -z "${TARGET_ROOT}" ]]; then
        TARGET_ROOT="${arg}"
      fi
      ;;
  esac
done

if [[ -z "${TARGET_ROOT}" ]]; then
  echo "Error: target-project-root is required"
  usage
fi

# ── 인터랙티브 프롬프트 (플래그 미제공 시) ──
if [[ -t 0 ]]; then
  # TTY 대화형 모드
  if [[ -z "${PROJECT_NAME}" ]]; then
    printf "프로젝트 이름: "; read -r PROJECT_NAME
  fi
  if [[ -z "${PROJECT_DOMAIN}" ]]; then
    printf "도메인 설명: "; read -r PROJECT_DOMAIN
  fi
  if [[ -z "${PROJECT_STACK}" ]]; then
    printf "기술 스택: "; read -r PROJECT_STACK
  fi
else
  # 비대화형 모드 — 누락 인자 명시 후 실패
  MISSING=()
  [[ -z "${PROJECT_NAME}" ]]  && MISSING+=("--name")
  [[ -z "${PROJECT_DOMAIN}" ]] && MISSING+=("--domain")
  [[ -z "${PROJECT_STACK}" ]]  && MISSING+=("--stack")
  if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "Error: 비대화형 환경에서 필수 인자가 누락되었습니다: ${MISSING[*]}" >&2
    echo "Usage: $0 <target> --name=<name> --domain=<domain> --stack=<stack>" >&2
    exit 1
  fi
fi

# 기본값 적용
[[ -z "${PRIMARY_WORKER}" ]]    && PRIMARY_WORKER="service-planner"
[[ -z "${SUPPORTING_WORKERS}" ]] && SUPPORTING_WORKERS="strategy-planner"

mkdir -p "${TARGET_ROOT}"

bash "${SCRIPT_DIR}/export-company-kit.sh" "${TARGET_ROOT}" >/dev/null
bash "${TARGET_ROOT}/.company-kit/scripts/init-cloned-project.sh" "${TARGET_ROOT}" >/dev/null

# ── 템플릿 렌더링: install wizard 치환 ──
# sed replacement에서 특수문자(&, \, |)를 이스케이프
_sed_escape() { printf '%s\n' "$1" | sed 's/[&\|/\\]/\\&/g'; }

render_template() {
  local tmpl_src="$1"
  local dest="$2"
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

TMPL_DIR="${TEMPLATE_ROOT}/templates/install"
render_template "${TMPL_DIR}/CLAUDE.md.tmpl"              "${TARGET_ROOT}/CLAUDE.md"
render_template "${TMPL_DIR}/project-context.md.tmpl"     "${TARGET_ROOT}/.company-project/project-context.md"
render_template "${TMPL_DIR}/project-standards.md.tmpl"   "${TARGET_ROOT}/.company-project/project-standards.md"

# ── Agent 생성: 카테고리 기반 ──
bash "${SCRIPT_DIR}/generate-project-agents.sh" "${TARGET_ROOT}" --categories="${CATEGORIES}"

# .company-template.lock에 categories 기록
if [[ -f "${TARGET_ROOT}/.company-template.lock" ]]; then
  if grep -q "^categories:" "${TARGET_ROOT}/.company-template.lock"; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "s/^categories:.*/categories: ${CATEGORIES}/" "${TARGET_ROOT}/.company-template.lock"
    else
      sed -i "s/^categories:.*/categories: ${CATEGORIES}/" "${TARGET_ROOT}/.company-template.lock"
    fi
  else
    echo "categories: ${CATEGORIES}" >> "${TARGET_ROOT}/.company-template.lock"
  fi
fi

cat <<EOF

Installed team-profile-company into ${TARGET_ROOT}

Project  : ${PROJECT_NAME}
Domain   : ${PROJECT_DOMAIN}
Stack    : ${PROJECT_STACK}
Primary  : ${PRIMARY_WORKER}
Support  : ${SUPPORTING_WORKERS}
Categories: ${CATEGORIES}

Next steps:
1. Open ${TARGET_ROOT}/START_HERE.md
2. Fill ${TARGET_ROOT}/.company-project/integrations/*.env
3. Restart or reopen Claude once so it refreshes slash commands.
4. ⭐ 5분 만에 첫 완주를 체험해보세요:
   cd ${TARGET_ROOT} && bash .company-kit/scripts/company demo
5. Then start your real session with:
   /rw <topic>
6. Or from a terminal:
   company run "<topic>"
7. Monitor current state with:
   company status
EOF
