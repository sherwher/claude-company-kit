#!/usr/bin/env bash
# validate-compact-schemas.sh
#
# R13 (5-C 1차) — compact-{plan,result} schema soft-warn 검증기.
#
# 왜:
#   R12 5-B 에서 templates/schemas/ 에 schema 두 개를 운영 승격했지만 검증기 미연결
#   상태였다. 5-C 의 1차 단계는 (a) schema 자체가 JSON-parse 가능한지, (b) 실제
#   워커 산출물 (compact-plan.md / compact-result.md) 에 frontmatter.meta 5필드가
#   존재하는지를 soft-warn 으로만 검사한다. 마크다운 → JSON 표현 변환은 별도 세션
#   (5-C 2차). jsonschema 라이브러리 의존성 추가도 보류 — python3 stdlib 만 사용.
#
# 동작:
#   1. templates/schemas/*.schema.json 전수 JSON parse
#   2. SESSION_DIR (인자 또는 cwd) 하위 workers/<worker>/compact-{plan,result}.md
#      탐색. 각 파일에 대해:
#        - YAML frontmatter (`---` 펜스) 존재 확인
#        - meta.session_id / worker / role / plan_sha256 / created_at 5 필드 grep
#        - 누락 시 soft_warn_count++ (rc 영향 없음)
#   3. SUMMARY 출력 후 항상 rc=0 (5-C 1차는 soft-warn only).
#
# 호출 예:
#   bash scripts/validate-compact-schemas.sh                          # cwd 기준
#   bash scripts/validate-compact-schemas.sh /path/to/session         # 명시
#
# 검증기 hard gate 승격 (5-C 2차) 은 R13+ 별도 세션에서 결정.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCHEMA_DIR="${TEMPLATE_ROOT}/templates/schemas"

SESSION_DIR="${1:-$PWD}"

soft_warn=0
hard_fail=0
schemas_checked=0
manifests_checked=0

log_warn() { echo "[validate-compact-schemas] WARN: $*" >&2; soft_warn=$((soft_warn + 1)); }
log_info() { echo "[validate-compact-schemas] INFO: $*"; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "[validate-compact-schemas] ERROR: python3 missing — schema parse skip" >&2
  exit 0
fi

# ── 1. schema 자체 JSON parse ──
if [[ -d "${SCHEMA_DIR}" ]]; then
  while IFS= read -r f; do
    schemas_checked=$((schemas_checked + 1))
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${f}" 2>/dev/null; then
      echo "[validate-compact-schemas] HARD: $(basename "${f}") JSON parse 실패" >&2
      hard_fail=$((hard_fail + 1))
    fi
  done < <(find "${SCHEMA_DIR}" -maxdepth 1 -name '*.schema.json' -type f 2>/dev/null)
else
  log_warn "templates/schemas/ 디렉토리 없음 — R12 5-B 미반영"
fi

# ── 2. workers/<worker>/compact-{plan,result}.md frontmatter 검사 ──
# R15 5-C 2차: bash grep presence-only → python helper 로 pattern/minLength
# constraint 까지 검증. helper 자체는 존재 여부 + regex match 위반도 감지.
VALIDATE_PY="${SCRIPT_DIR}/validate-compact-frontmatter.py"
WORKERS_DIR="${SESSION_DIR}/workers"
if [[ -d "${WORKERS_DIR}" ]]; then
  md_files=()
  while IFS= read -r mdfile; do
    [[ -z "${mdfile}" ]] && continue
    md_files+=("${mdfile}")
    manifests_checked=$((manifests_checked + 1))
  done < <(find "${WORKERS_DIR}" -maxdepth 3 -type f \( -name 'compact-plan.md' -o -name 'compact-result.md' \) 2>/dev/null)

  if (( ${#md_files[@]} > 0 )); then
    if [[ -f "${VALIDATE_PY}" ]]; then
      # python helper 실행. rc=0 전부 OK, rc=2 violations (soft-warn 으로 downgrade),
      # rc=1 I/O 오류 (hard_fail). stdout/stderr 는 그대로 노출.
      set +e
      python3 "${VALIDATE_PY}" "${md_files[@]}"
      py_rc=$?
      set -e
      case "${py_rc}" in
        0) : ;;
        2) soft_warn=$((soft_warn + 1)) ;;
        *) hard_fail=$((hard_fail + 1));;
      esac
    else
      log_warn "validate-compact-frontmatter.py 미발견 — frontmatter constraint 검사 skip"
    fi
  fi
else
  log_info "workers/ 디렉토리 없음 — 스키마만 검사 (SESSION_DIR=${SESSION_DIR})"
fi

echo "[validate-compact-schemas] SUMMARY: schemas=${schemas_checked}, manifests=${manifests_checked}, soft_warnings=${soft_warn}, hard_fails=${hard_fail}"

# 5-C 1차는 soft-warn only — hard_fail 도 rc=0 (schema 파일 자체가 깨졌으면 doctor.sh 가 잡음)
exit 0
