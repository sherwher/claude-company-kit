#!/usr/bin/env bash
# scripts/check-external-write-approval.sh (v1.5.0 신규)
#
# 목적: 워커가 외부 서비스 write (Notion/Slack/GitHub/email 등 비가역 호출) 직전에
#       호출하여 leader 의 승인 토큰을 검증한다. 워커는 사용 패턴이 단순한
#       "approve 됐는가? yes/no" 만 알면 되므로 rc=0/1 로 응답한다.
#
# 정책 (CLAUDE.md):
#   - 로컬 파일 write 는 워커 자유.
#   - 외부 서비스 write 는 leader 가 발행한 external_write_approved 이벤트가
#     같은 세션의 events.jsonl 에 있어야 실행 가능.
#   - 발행 명령: bash scripts/company-approve.sh <session> <root> --scope <scope>
#
# 사용:
#   bash scripts/check-external-write-approval.sh <session_id> <scope> [project_root]
#   bash scripts/check-external-write-approval.sh <session_id> <scope> [project_root] --quiet
#
#   scope 형식: external_write:<service>:<resource>
#     예) external_write:notion:page-create
#         external_write:slack:message-post
#
# 와일드카드 (leader 토큰 측):
#   leader 가 'external_write:notion:*' 로 발행했으면, 워커가
#   'external_write:notion:page-create' 로 check 해도 매칭된다.
#   leader 가 'external_write:*' 로 발행했으면 모든 external_write 매칭.
#   ※ 워커 측에서 와일드카드 check 는 허용하지 않는다 — 항상 구체적 액션을 명시해야 함.
#
# 종료 코드:
#   0 — 매칭되는 external_write_approved 이벤트가 같은 세션에 존재
#   1 — 미승인 (이벤트 없음)
#   2 — 사용법 오류 / 잘못된 scope 형식

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SESSION_ID="${1:-}"
SCOPE="${2:-}"
PROJECT_ROOT="${3:-.}"
QUIET=0
if [[ "${4:-}" == "--quiet" ]]; then
  QUIET=1
fi
# 3번째 인자가 --quiet 이고 PROJECT_ROOT 가 생략된 형태도 지원
if [[ "${PROJECT_ROOT}" == "--quiet" ]]; then
  PROJECT_ROOT="."
  QUIET=1
fi

if [[ -z "${SESSION_ID}" || -z "${SCOPE}" ]]; then
  echo "Usage: $0 <session_id> <scope> [project_root] [--quiet]" >&2
  echo "  scope 예: external_write:notion:page-create" >&2
  exit 2
fi

if [[ "${SCOPE}" != external_write:*:* && "${SCOPE}" != external_write:* ]]; then
  echo "Error: scope 형식 오류 — 'external_write:<service>:<resource>' 이어야 합니다 (받은 값: ${SCOPE})" >&2
  exit 2
fi

# 워커 측 와일드카드 사용 차단 (leader 만 허용)
if [[ "${SCOPE}" == *"*"* ]]; then
  echo "Error: 워커는 와일드카드 scope 로 check 할 수 없습니다. 구체적 액션을 명시하세요. (받은 값: ${SCOPE})" >&2
  exit 2
fi

EVENTS_FILE="${PROJECT_ROOT}/.company-runtime/harness/events.jsonl"

if [[ ! -f "${EVENTS_FILE}" ]]; then
  [[ "${QUIET}" -eq 1 ]] || echo "DENIED: events.jsonl 부재 — 세션이 시작되지 않았거나 잘못된 project_root" >&2
  exit 1
fi

# scope 분해: external_write:<service>:<resource>
_rest="${SCOPE#external_write:}"
_req_service="${_rest%%:*}"
if [[ "${_rest}" == *":"* ]]; then
  _req_resource="${_rest#*:}"
else
  _req_resource="*"
fi

# events.jsonl 에서 같은 session_id 의 external_write_approved 이벤트 추출.
# 매칭 규칙:
#   - 이벤트의 service 가 요청 service 와 같거나 '*'
#   - 이벤트의 resource 가 요청 resource 와 같거나 '*'
matched=0
matched_record=""
while IFS= read -r line; do
  # session_id 격리 — awk 보다 grep 이 빠르고 안전
  case "${line}" in
    *'"event":"external_write_approved"'*) ;;
    *) continue ;;
  esac
  case "${line}" in
    *"\"session_id\":\"${SESSION_ID}\""*) ;;
    *) continue ;;
  esac
  # service 추출
  svc="$(printf '%s' "${line}" | sed -n 's/.*"service":"\([^"]*\)".*/\1/p')"
  res="$(printf '%s' "${line}" | sed -n 's/.*"resource":"\([^"]*\)".*/\1/p')"
  [[ -z "${svc}" ]] && svc="*"
  [[ -z "${res}" ]] && res="*"

  # service 매칭
  if [[ "${svc}" != "*" && "${svc}" != "${_req_service}" ]]; then
    continue
  fi
  # resource 매칭
  if [[ "${res}" != "*" && "${res}" != "${_req_resource}" ]]; then
    continue
  fi
  matched=1
  matched_record="${line}"
  break
done < "${EVENTS_FILE}"

if [[ "${matched}" -eq 1 ]]; then
  if [[ "${QUIET}" -eq 0 ]]; then
    approver="$(printf '%s' "${matched_record}" | sed -n 's/.*"approver":"\([^"]*\)".*/\1/p')"
    ts="$(printf '%s' "${matched_record}" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')"
    echo "APPROVED scope=${SCOPE} service=${_req_service} resource=${_req_resource} approver=${approver:-?} approved_at=${ts:-?}"
  fi
  exit 0
fi

if [[ "${QUIET}" -eq 0 ]]; then
  echo "DENIED scope=${SCOPE} — 같은 세션에 매칭되는 external_write_approved 이벤트 없음."
  echo "       리더가 'bash scripts/company-approve.sh ${SESSION_ID} . --scope ${SCOPE}' 또는"
  echo "       서비스 단위 와일드카드 'bash scripts/company-approve.sh ${SESSION_ID} . --scope external_write:${_req_service}:*'"
  echo "       으로 토큰을 발행한 뒤 다시 시도하세요." >&2
fi
exit 1
