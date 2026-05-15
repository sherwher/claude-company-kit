#!/usr/bin/env bash
# scripts/sentinel-scan.sh (R26 Phase 4b 신규)
#
# 목적: 세션의 compact-plan / compact-result 산출물에서 **sentinel placeholder 패턴**을
#       탐지하여 canonical 이벤트 `sentinel_detected` 를 emit 한다.
#       (산출물 오염 조기 경고 — notification-policy §6 해당)
#
# 탐지 대상 패턴 (대소문자 무시):
#   TODO / FIXME / XXX / PLACEHOLDER / <TBD> / <TODO> / {{placeholder}}
#
# 사용:
#   bash scripts/sentinel-scan.sh <session_id> [project_root]
#   bash scripts/sentinel-scan.sh <session_id> [project_root] --dry-run   # emit 없이 탐지만
#
# 종료 코드:
#   0 — 정상 실행 (패턴 탐지 여부 무관)
#   1 — 인자 오류
#
# 정책:
#   - sentinel 탐지는 **경고**이며 실패가 아니다 (워커 작업은 계속)
#   - emit 은 best-effort: company-emit.sh 가 silent skip 해도 전체 실행은 0 유지
#   - HTTP 서버 실재화 금지 (R24 D1 연장) — 본 스크립트는 one-shot 실행만
#
# 게이트:
#   smoke-sentinel-scan.sh 가 본 스크립트의 탐지/무탐지 2 경로를 mock fixture 로 검증

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SESSION_ID="${1:-}"
PROJECT_ROOT="${2:-.}"
DRY_RUN=0
if [[ "${3:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

if [[ -z "${SESSION_ID}" ]]; then
  echo "Usage: $0 <session_id> [project_root] [--dry-run]" >&2
  exit 1
fi

# 탐지 대상 디렉토리 (compact-plan / compact-result 가 존재할 수 있는 3 경로)
SCAN_ROOTS=(
  "${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}"
  "${PROJECT_ROOT}/.company-artifacts/${SESSION_ID}"
  "${PROJECT_ROOT}/.company-exports/${SESSION_ID}"
)

# 탐지 패턴 (ripgrep/grep 확장 정규식). 대소문자 무시.
# 왜 이 집합인가:
#   - TODO/FIXME/XXX: 워커가 미완성 표시를 남기고 merge 하는 케이스
#   - PLACEHOLDER: 템플릿 스킵 (compact-plan v2 에서 금기로 지정)
#   - <TBD>/<TODO>: ADR 스타일 불완전 표기
#   - {{placeholder}}: 이중 중괄호 미치환 템플릿 변수
PATTERN='TODO|FIXME|XXX|PLACEHOLDER|<TBD>|<TODO>|\{\{[a-zA-Z_][a-zA-Z0-9_]*\}\}'

# v1.4 Phase 2: subagent 호출 흔적 감지 (warn-only, separate report line)
# 왜 분리했나:
#   - sentinel(미완성 표시) 과 subagent 누수(비용 우회) 는 의미가 다르다
#   - 하나의 PATTERN 에 묶으면 운영자가 어느 쪽 위반인지 구분 못 함
#   - subagent 패턴은 compact-plan/result 에 우연히 등장할 수 있는 일반 단어가 아니므로 false positive 낮음
# 감지 대상:
#   - "Agent(...)"  / "Task(...)"  : Claude Code 의 Agent/Task 도구 호출
#   - "oh-my-claudecode:" : OMC subagent 호출 prefix
#   - "EnterPlanMode" / "ExitPlanMode" : 워커가 자체적으로 plan 모드 전환 (파일 게이트 우회)
SUBAGENT_PATTERN='Agent\(|Task\(|oh-my-claudecode:|EnterPlanMode|ExitPlanMode'

# 탐지 결과 누적
detected_files=()
detected_count=0
subagent_files=()
subagent_count=0

for root in "${SCAN_ROOTS[@]}"; do
  if [[ ! -d "${root}" ]]; then
    continue
  fi
  # compact-plan.* / compact-result.* 만 스캔 (다른 산출물은 R26 범위 밖)
  while IFS= read -r -d '' file; do
    # 바이너리/대용량 파일 방어: 1MB 초과 skip
    size=$(wc -c < "${file}" 2>/dev/null | tr -d ' ')
    if [[ "${size:-0}" -gt 1048576 ]]; then
      continue
    fi
    if grep -q -E -i "${PATTERN}" "${file}" 2>/dev/null; then
      detected_files+=("${file}")
      file_hits=$(grep -c -E -i "${PATTERN}" "${file}" 2>/dev/null || echo 0)
      detected_count=$((detected_count + file_hits))
    fi
    # v1.4 Phase 2: subagent 호출 흔적 (case-sensitive — 식별자는 대소문자 구분이 정확)
    if grep -q -E "${SUBAGENT_PATTERN}" "${file}" 2>/dev/null; then
      subagent_files+=("${file}")
      sa_hits=$(grep -c -E "${SUBAGENT_PATTERN}" "${file}" 2>/dev/null || echo 0)
      subagent_count=$((subagent_count + sa_hits))
    fi
  done < <(find "${root}" -type f \( -name "compact-plan.*" -o -name "compact-result.*" \) -print0 2>/dev/null)
done

# v1.4 Phase 2: subagent 누수 별도 리포트 (Sonnet 비용 제한 우회 가능성)
if [[ "${#subagent_files[@]}" -gt 0 ]]; then
  echo "sentinel-scan: SUBAGENT-LEAK — session=${SESSION_ID} files=${#subagent_files[@]} hits=${subagent_count}"
  echo "  ⚠️  Sonnet worker 비용 제한 우회 가능성 — 워커가 Agent/Task/EnterPlanMode 호출 흔적 발견"
  for f in "${subagent_files[@]}"; do
    rel="${f#${PROJECT_ROOT}/}"
    echo "  ✗ ${rel}"
  done
fi

# 결과 리포트 (stdout)
if [[ "${#detected_files[@]}" -eq 0 ]]; then
  echo "sentinel-scan: CLEAN — session=${SESSION_ID} (0 patterns)"
  exit 0
fi

echo "sentinel-scan: DETECTED — session=${SESSION_ID} files=${#detected_files[@]} patterns=${detected_count}"
for f in "${detected_files[@]}"; do
  # 상대 경로로 출력
  rel="${f#${PROJECT_ROOT}/}"
  echo "  ✗ ${rel}"
done

# emit 단계 (--dry-run 이면 skip)
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "sentinel-scan: dry-run — emit skipped"
  exit 0
fi

# R26 Phase 4b: sentinel_detected canonical 이벤트 발화
# severity=P1 (산출물 오염 위험 — notification-policy §1 참조)
# idempotency_key: session_id + 파일 수 + 패턴 수 (동일 세션 반복 호출 시 중복 방지)
# 비어 있지 않은 첫 파일의 상대 경로를 샘플로 첨부
first_file_rel="${detected_files[0]#${PROJECT_ROOT}/}"
bash "${SCRIPT_DIR}/company-emit.sh" "sentinel_detected" "${SESSION_ID}" "${PROJECT_ROOT}" \
  "files=${#detected_files[@]}" \
  "patterns=${detected_count}" \
  "sample=${first_file_rel}" \
  "severity=P1" \
  "idempotency_key=${SESSION_ID}:sentinel:${#detected_files[@]}:${detected_count}" \
  >/dev/null 2>&1 || true

exit 0
