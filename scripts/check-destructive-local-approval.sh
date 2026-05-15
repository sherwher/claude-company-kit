#!/usr/bin/env bash
# scripts/check-destructive-local-approval.sh (v1.12.0 Phase 5 신규)
#
# 목적: 워커/명령이 로컬 destructive 작업 (worktree 삭제, --gc 일괄 등) 직전에
#       호출하여 leader 의 승인 토큰을 검증한다. external_write 와 같은 정신.
#
# 정책 (ADR docs/decisions/2026-05-14-worker-registry-phase5.md v0.4 D10):
#   - 로컬 비파괴 (stop) 는 토큰 면제 (Phase 4 D9).
#   - 로컬 파괴 (cleanup, gc) 는 leader 가 발행한 destructive_local_approved
#     이벤트가 같은 세션의 events.jsonl 에 있어야 실행 가능.
#   - 발행 명령: bash scripts/company-approve.sh <session> <root> --scope <scope>
#               (--scope destructive_local:worker_cleanup:<wid> 또는
#                --scope destructive_local:worker_gc_all)
#
# 사용:
#   bash scripts/check-destructive-local-approval.sh <session_id> <scope> [project_root] [--quiet]
#
#   scope 형식: destructive_local:<action>:<target>
#     예) destructive_local:worker_cleanup:wkr-feat-x-w
#         destructive_local:worker_gc_all              (target 생략 — 일괄)
#
# 와일드카드 (leader 토큰 측):
#   leader 가 'destructive_local:worker_cleanup:*' 로 발행했으면, 워커가
#   'destructive_local:worker_cleanup:<wid>' 로 check 해도 매칭된다.
#   leader 가 'destructive_local:*' 로 발행했으면 모든 destructive_local 매칭.
#   ※ 워커 측 와일드카드 check 는 차단.
#
# 종료 코드:
#   0 — 매칭되는 destructive_local_approved 이벤트가 같은 세션에 존재
#   1 — 미승인
#   2 — 사용법 오류 / 잘못된 scope 형식

set -euo pipefail

SESSION_ID="${1:-}"
SCOPE="${2:-}"
PROJECT_ROOT="${3:-.}"
QUIET=0
if [[ "${4:-}" == "--quiet" ]]; then QUIET=1; fi
if [[ "${PROJECT_ROOT}" == "--quiet" ]]; then PROJECT_ROOT="."; QUIET=1; fi

if [[ -z "${SESSION_ID}" || -z "${SCOPE}" ]]; then
  echo "Usage: $0 <session_id> <scope> [project_root] [--quiet]" >&2
  echo "  scope 예: destructive_local:worker_cleanup:wkr-feat-x-w" >&2
  echo "           destructive_local:worker_gc_all" >&2
  exit 2
fi

case "${SCOPE}" in
  destructive_local:*:*|destructive_local:*) ;;
  *)
    echo "Error: scope 형식 오류 — 'destructive_local:<action>[:<target>]' 이어야 합니다 (받은 값: ${SCOPE})" >&2
    exit 2 ;;
esac

if [[ "${SCOPE}" == *"*"* ]]; then
  echo "Error: 워커는 와일드카드 scope 로 check 할 수 없습니다. 구체적 target 을 명시하세요. (받은 값: ${SCOPE})" >&2
  exit 2
fi

EVENTS_FILE="${PROJECT_ROOT}/.company-runtime/harness/events.jsonl"
if [[ ! -f "${EVENTS_FILE}" ]]; then
  [[ "${QUIET}" -eq 1 ]] || echo "DENIED: events.jsonl 부재 — 세션이 시작되지 않았거나 잘못된 project_root" >&2
  exit 1
fi

# scope 분해: destructive_local:<action>:<target>
_rest="${SCOPE#destructive_local:}"
_req_action="${_rest%%:*}"
if [[ "${_rest}" == *":"* ]]; then _req_target="${_rest#*:}"; else _req_target="*"; fi

matched=0
matched_record=""
while IFS= read -r line; do
  case "${line}" in
    *'"event":"destructive_local_approved"'*) ;;
    *) continue ;;
  esac
  case "${line}" in
    *"\"session_id\":\"${SESSION_ID}\""*) ;;
    *) continue ;;
  esac
  act="$(printf '%s' "${line}" | sed -n 's/.*"action":"\([^"]*\)".*/\1/p')"
  tgt="$(printf '%s' "${line}" | sed -n 's/.*"target":"\([^"]*\)".*/\1/p')"
  [[ -z "${act}" ]] && act="*"
  [[ -z "${tgt}" ]] && tgt="*"

  if [[ "${act}" != "*" && "${act}" != "${_req_action}" ]]; then continue; fi
  if [[ "${tgt}" != "*" && "${tgt}" != "${_req_target}" ]]; then continue; fi
  matched=1
  matched_record="${line}"
  break
done < "${EVENTS_FILE}"

if [[ "${matched}" -eq 1 ]]; then
  if [[ "${QUIET}" -eq 0 ]]; then
    approver="$(printf '%s' "${matched_record}" | sed -n 's/.*"approver":"\([^"]*\)".*/\1/p')"
    ts="$(printf '%s' "${matched_record}" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')"
    echo "APPROVED scope=${SCOPE} action=${_req_action} target=${_req_target} approver=${approver:-?} approved_at=${ts:-?}"
  fi
  exit 0
fi

if [[ "${QUIET}" -eq 0 ]]; then
  echo "DENIED scope=${SCOPE} — 같은 세션에 매칭되는 destructive_local_approved 이벤트 없음."
  echo "       리더가 'bash scripts/company-approve.sh ${SESSION_ID} . --scope ${SCOPE}' 또는"
  if [[ "${_req_target}" != "*" ]]; then
    echo "       action 단위 와일드카드 'bash scripts/company-approve.sh ${SESSION_ID} . --scope destructive_local:${_req_action}:*'"
  fi
  echo "       으로 토큰을 발행한 뒤 다시 시도하세요." >&2
fi
exit 1
