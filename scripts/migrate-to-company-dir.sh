#!/usr/bin/env bash
# migrate-to-company-dir.sh
# .company-* 여러 디렉토리 → .company/ 단일 구조로 마이그레이션
# 기존 경로는 symlink로 유지 (backward compat)
#
# 사용: bash .company-kit/scripts/migrate-to-company-dir.sh [--dry-run] [--no-symlink]

set -euo pipefail

DRY_RUN=false
NO_SYMLINK=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --no-symlink) NO_SYMLINK=true ;;
  esac
done

PROJECT_ROOT="$(pwd)"
echo "=== company directory migration ==="
echo "Project: ${PROJECT_ROOT}"
[[ "${DRY_RUN}" == true ]] && echo "Mode: DRY RUN (변경 없음)"
echo ""

run() {
  if [[ "${DRY_RUN}" == true ]]; then
    echo "[dry] $*"
  else
    eval "$@"
  fi
}

# 마이그레이션 매핑: 구 경로 → 신 경로
declare -A DIRS=(
  [".company-project"]=".company/config"
  [".company-runtime"]=".company/runtime"
  [".company-artifacts"]=".company/artifacts"
  [".company-exports"]=".company/exports"
)

# .company-kit은 설치 단위로 관리되므로 별도 처리 (마이그레이션 대상 아님)

MIGRATED=0
SKIPPED=0

for OLD_DIR in "${!DIRS[@]}"; do
  NEW_DIR="${DIRS[$OLD_DIR]}"

  if [[ ! -d "${OLD_DIR}" ]]; then
    echo "  skip: ${OLD_DIR} (존재하지 않음)"
    ((SKIPPED++)) || true
    continue
  fi

  if [[ -L "${OLD_DIR}" ]]; then
    echo "  skip: ${OLD_DIR} (이미 symlink)"
    ((SKIPPED++)) || true
    continue
  fi

  echo "  이동: ${OLD_DIR} → ${NEW_DIR}"

  # 부모 디렉토리 생성
  run "mkdir -p \"$(dirname "${NEW_DIR}")\""

  # 실제 이동
  run "mv \"${OLD_DIR}\" \"${NEW_DIR}\""

  # symlink로 구 경로 유지 (backward compat)
  if [[ "${NO_SYMLINK}" == false ]]; then
    run "ln -s \"${NEW_DIR}\" \"${OLD_DIR}\""
    echo "  symlink: ${OLD_DIR} → ${NEW_DIR}"
  fi

  ((MIGRATED++)) || true
done

echo ""
echo "결과: ${MIGRATED}개 이동, ${SKIPPED}개 건너뜀"

# smoke test
if [[ "${DRY_RUN}" == false ]]; then
  echo ""
  echo "=== Smoke test ==="
  PASS=0
  FAIL=0

  for OLD_DIR in "${!DIRS[@]}"; do
    NEW_DIR="${DIRS[$OLD_DIR]}"
    if [[ -d "${NEW_DIR}" ]]; then
      echo "  ✓ ${NEW_DIR}"
      ((PASS++)) || true
    elif [[ -d "${OLD_DIR}" ]]; then
      echo "  ✓ ${OLD_DIR} (symlink 또는 원본)"
      ((PASS++)) || true
    else
      echo "  ✗ ${NEW_DIR} (없음)"
      ((FAIL++)) || true
    fi
  done

  echo ""
  if [[ "${FAIL}" -gt 0 ]]; then
    echo "✗ Smoke test 실패 (${FAIL}개). 수동 확인 필요."
    echo "  롤백: git worktree list 확인 후 mv 명령으로 원복"
    exit 1
  else
    echo "✓ Smoke test 통과 (${PASS}개)"
  fi
fi

echo ""
echo "완료. 다음 단계:"
echo "  1. 'company status'로 정상 동작 확인"
echo "  2. 기존 경로를 참조하는 스크립트는 symlink를 통해 자동 호환됨"
echo "  3. 다음 major 버전에서 symlink 제거 예정"
