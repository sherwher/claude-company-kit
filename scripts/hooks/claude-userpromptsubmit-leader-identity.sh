#!/usr/bin/env bash
# scripts/hooks/claude-userpromptsubmit-leader-identity.sh (v1.5.9 신규)
#
# 목적: 사용자 turn 마다 메인 Claude 에게 "리더 정체성 + workload budget"
#       1줄 reminder 를 <system-reminder> 로 주입한다. 긴 세션이나 컨텍스트
#       압축 후에도 정체성이 묻히지 않도록.
#
# 톤: 짧고 단호. 매 turn 노출되므로 잡음 최소화.
#
# 비활성 조건:
#   - $COMPANY_DISABLE_LEADER_IDENTITY=1 환경변수
#   - 워커 페르소나 마커 (.company-runtime/sessions/<sid>/workers/<w>/active)
#     가 발견되면 워커 정체성을 주입 (리더 reminder 와 충돌 방지)
#
# 등록 (.claude/settings.json):
#   UserPromptSubmit hooks 배열에 추가. leader-wake 와 같은 turn 에 둘 다
#   실행되어도 stdout 이 합쳐지므로 안전.

set -uo pipefail

# 비활성 토글
if [[ "${COMPANY_DISABLE_LEADER_IDENTITY:-0}" == "1" ]]; then
  exit 0
fi

# stdin drain (leader-wake 와 동일 패턴)
if [[ -t 0 ]]; then
  :
else
  cat >/dev/null 2>&1 &
  _drain_pid=$!
  ( sleep 0.2; kill "${_drain_pid}" 2>/dev/null || true ) &
  wait "${_drain_pid}" 2>/dev/null || true
fi

PROJECT_ROOT="${COMPANY_PROJECT_ROOT:-$(pwd)}"

# 현재 셸이 워커 페르소나로 전환된 상태인지 감지.
# sequential 러너에서 worker-request.md 를 active 로 마킹한 워커가 있으면
# 리더 reminder 를 출력하지 않는다 (이중 정체성 혼선 방지).
_active_worker=""
_sessions_dir="${PROJECT_ROOT}/.company-runtime/sessions"
if [[ -d "${_sessions_dir}" ]]; then
  while IFS= read -r _marker; do
    [[ -f "${_marker}" ]] || continue
    _active_worker="$(dirname "${_marker}" | xargs basename)"
    break
  done < <(find "${_sessions_dir}" -maxdepth 4 -name "active-worker-persona" -type f 2>/dev/null)
fi

if [[ -n "${_active_worker}" ]]; then
  printf '<system-reminder>\n'
  printf '워커 페르소나 활성: %s. 리더 모드 아님 — worker-request.md 를 따르고 plan-mode 부터 진행.\n' "${_active_worker}"
  printf '</system-reminder>\n'
  exit 0
fi

# 리더 reminder (default path)
printf '<system-reminder>\n'
printf 'YOU ARE THE LEADER. 직접 코드/문서/초안 작성 금지. 워커 경유 (/rw, /spawn-worker).\n'
printf '예외: sequential 워커 페르소나 전환, .company-kit / CLAUDE.md / scaffold / 운영 스크립트 편집.\n'
printf '한 워커 turn 작업량 한도: 코드 ≤8 파일 / 400 LOC, 콘텐츠 ≤12 항목. 초과 시 chunk 분할.\n'
printf '토픽 한 번 승인 후 라우팅→prepare→spawn→첫입력까지 자동 진행 (CLAUDE.md 자동 진행 정책).\n'
printf '</system-reminder>\n'

exit 0
