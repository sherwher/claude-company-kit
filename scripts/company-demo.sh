#!/usr/bin/env bash
set -euo pipefail

# company-demo.sh — 1인 사용자가 첫 5분 안에 "아 이거 작동하네" 느끼게
# 만드는 고정 시나리오. v1.1.0 (C5): HARNESS_V0 §4.5 구현.
#
# 사용:
#   company demo                  현재 프로젝트에서 데모 1회 실행
#   company demo --skip-approve   리더 승인 단계를 건너뛰고 자동 진행
#                                 (CI/smoke test용)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./git-worktree-lib.sh
source "${SCRIPT_DIR}/git-worktree-lib.sh"

PROJECT_ROOT="$(resolve_shared_project_root ".")"
SKIP_APPROVE=0
for arg in "$@"; do
  case "${arg}" in
    --skip-approve) SKIP_APPROVE=1 ;;
    *) ;;
  esac
done

DEMO_TOPIC="README의 한 줄 요약을 3개 bullet로 개선"
DEMO_SESSION="demo"

cat <<'BANNER'
═══════════════════════════════════════════════════════════
  company demo — 5분 안에 첫 완주 체험
═══════════════════════════════════════════════════════════

이 데모는 1인 사용자가 처음 5분 안에 다음 5단계를 경험하게 합니다:

  1. 세션 준비 (session_prepared 이벤트)
  2. 워커 스폰 준비 (spawn_attempt 이벤트)
  3. 워커가 compact-plan 작성 (Write 툴로 직접 생성)
  4. 리더 승인 (approved 마커 + 이벤트)
  5. 세션 종료 + 10초 요약 (session_closed)

샘플 토픽: README의 한 줄 요약을 3개 bullet로 개선
워커: service-planner (단일)

BANNER

echo "[1/5] 세션 준비 중..."
bash "${SCRIPT_DIR}/prepare-session.sh" "${DEMO_SESSION}" "${PROJECT_ROOT}" "${DEMO_TOPIC}" >/dev/null
echo "      ✓ 세션 'demo' 준비 완료"
echo

echo "[2/5] 워커 스폰 준비 (service-planner 단일, 자동 라우팅 우회)..."
bash "${SCRIPT_DIR}/prepare-worker.sh" "${DEMO_SESSION}" "service-planner" "${PROJECT_ROOT}" >/dev/null
echo "      ✓ worker-request.md 생성됨"
echo "      → .company-runtime/sessions/demo/workers/service-planner/worker-request.md"
echo

echo "[3/5] 워커 compact-plan 작성 시뮬레이션..."
echo "      (실제 워커 스폰 대신 데모용 5섹션 plan을 직접 작성합니다)"
WORKER_PLAN="${PROJECT_ROOT}/.company-runtime/sessions/${DEMO_SESSION}/workers/service-planner/compact-plan.md"
mkdir -p "$(dirname "${WORKER_PLAN}")"
cat > "${WORKER_PLAN}" <<'PLAN'
# Compact Plan

## Goal
- README 첫 단락의 한 줄 설명을 3개의 bullet로 분해해서 핵심 가치를 빠르게 전달한다.

## Steps
- README.md 현재 한 줄 요약 위치 식별
- 핵심 가치 3가지 도출 (대상/문제/해결)
- bullet 3줄 작성 후 한 줄 설명 위에 삽입

## Outputs
- README.md (수정)
- .company-artifacts/demo/service-planner/docs/before-after.md (변경 비교)

## Risks
- 현재 가정: README 최상단이 한 줄 설명이며 변경 가능
- bullet이 너무 길면 한 줄 요약보다 정보 밀도가 떨어질 수 있음

## Questions
- 없음
PLAN
echo "      ✓ compact-plan.md 작성 완료 (5섹션 모두 채움)"
echo "      → ${WORKER_PLAN}"
echo

if [[ "${SKIP_APPROVE}" -eq 0 ]]; then
  echo "[4/5] 리더 승인 대기"
  printf "      이 plan을 승인하시겠습니까? [y/N] "
  read -r ans
  if [[ ! "${ans}" =~ ^[yY]$ ]]; then
    echo "      ❌ 승인 거부 — 데모 중단"
    echo
    echo "다시 시도: company demo"
    exit 0
  fi
else
  echo "[4/5] 리더 승인 (자동, --skip-approve)"
fi

bash "${SCRIPT_DIR}/company-approve.sh" "${DEMO_SESSION}" "${PROJECT_ROOT}" >/dev/null
echo "      ✓ 승인 완료 — approved 마커 생성"
echo

echo "[5/5] 데모 산출물 생성 + 세션 종료..."
ART_DIR="${PROJECT_ROOT}/.company-artifacts/${DEMO_SESSION}/service-planner/docs"
EXP_DIR="${PROJECT_ROOT}/.company-exports/${DEMO_SESSION}"
mkdir -p "${ART_DIR}" "${EXP_DIR}"
cat > "${ART_DIR}/before-after.md" <<'ART'
# README 한 줄 요약 → 3 bullet 개선안

## Before
> AI 회사 운영 템플릿.

## After
- **AI 워커 팀을 1인 운영자가 굴리기 위한** 최소 bash 하니스
- **리더-워커 분리**로 책임 영역을 명확히
- **5분 안에 첫 완주**를 데모로 즉시 체험

ART
cp "${ART_DIR}/before-after.md" "${EXP_DIR}/before-after.md"
echo "      ✓ artifact 1건 생성: before-after.md"
echo "      ✓ exports 1건 승격: ${EXP_DIR}/before-after.md"
echo

bash "${SCRIPT_DIR}/close-session.sh" "${DEMO_SESSION}" "${PROJECT_ROOT}" 2>&1 | tail -12

echo
echo "═══════════════════════════════════════════════════════════"
echo "  ✅ 데모 완주! 첫 export가 .company-exports/demo/ 에 생성됐습니다."
echo "═══════════════════════════════════════════════════════════"
echo
echo "다음 단계:"
echo "  • company status              현재 상태 + 이벤트 보기"
echo "  • cat .company-exports/demo/before-after.md   결과 확인"
echo "  • company run \"<원하는 토픽>\"   실제 토픽으로 첫 세션 시작"
