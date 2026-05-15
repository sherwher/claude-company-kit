#!/usr/bin/env bash
# scripts/timeout-watchdog.sh (R26 Phase 4b 신규)
#
# 목적: events.jsonl 을 스캔하여 `spawn_attempt` 후 지정 임계 내에 `spawn_success` 가
#       기록되지 않은 워커를 탐지하고 canonical 이벤트 `worker_timeout` 을 emit 한다.
#
# 사용:
#   bash scripts/timeout-watchdog.sh <session_id> [project_root] [threshold_seconds]
#   bash scripts/timeout-watchdog.sh <session_id> [project_root] [threshold_seconds] --dry-run
#
# 기본 임계: 1800 초 (30분). notification-policy §7 tier 1 기준.
#
# 종료 코드:
#   0 — 정상 실행
#   1 — 인자 오류 또는 events.jsonl 없음
#
# 정책 (R24 D1 연장):
#   - HTTP 서버 / daemon / sleep loop 금지. 본 스크립트는 one-shot 스캔만 수행한다.
#   - 상주 실행이 필요하면 사용자가 cron / launchd 로 주기 호출한다 (MANUAL_VERIFY.md 참조).
#   - emit 은 best-effort: 실패 silent skip.
#
# 탐지 알고리즘:
#   1. events.jsonl 에서 session_id 매칭 라인 수집
#   2. spawn_attempt 의 (worker, ts) → pending 테이블
#   3. spawn_success 의 (worker) → pending 에서 제거
#   4. pending 에 남은 항목 중 (now - ts) > threshold 인 워커 → worker_timeout emit
#
# 멱등성:
#   idempotency_key = session_id:worker:worker_timeout:<spawn_attempt_ts>
#   동일 spawn_attempt 는 반복 실행돼도 동일 key → 중복 emit 방지 (event-flush 가 dedupe).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SESSION_ID="${1:-}"
PROJECT_ROOT="${2:-.}"
THRESHOLD_SECONDS="${3:-1800}"
DRY_RUN=0
if [[ "${4:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

if [[ -z "${SESSION_ID}" ]]; then
  echo "Usage: $0 <session_id> [project_root] [threshold_seconds] [--dry-run]" >&2
  exit 1
fi

# THRESHOLD_SECONDS validate (숫자만)
if ! [[ "${THRESHOLD_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "timeout-watchdog: invalid threshold (숫자만 허용): ${THRESHOLD_SECONDS}" >&2
  exit 1
fi

EVENTS_FILE="${PROJECT_ROOT}/.company-runtime/harness/events.jsonl"

if [[ ! -f "${EVENTS_FILE}" ]]; then
  echo "timeout-watchdog: events.jsonl 없음 — session=${SESSION_ID} (정상 무동작)"
  exit 0
fi

# jq 미설치 silent skip (company-emit.sh L29 정책 통일)
if ! command -v jq >/dev/null 2>&1; then
  echo "timeout-watchdog: jq 없음 — silent skip"
  exit 0
fi

# ts (ISO 8601) → epoch seconds 변환 (macOS/Linux 공통 호환)
ts_to_epoch() {
  local ts="$1"
  # date -d (GNU) 우선, 실패 시 date -j (BSD/macOS)
  if date -d "${ts}" +%s 2>/dev/null; then
    return 0
  fi
  # BSD date: %Y-%m-%dT%H:%M:%SZ 형식
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "${ts}" +%s 2>/dev/null || echo ""
}

now_epoch=$(date -u +%s)
threshold_window=$((now_epoch - THRESHOLD_SECONDS))

# 1. spawn_attempt 수집 (session_id 매칭, worker 별 가장 이른 ts)
# 출력 포맷: "<worker>\t<ts>\t<epoch>"
declare -a pending_workers=()
declare -a pending_ts=()

while IFS=$'\t' read -r worker ts; do
  [[ -z "${worker}" || -z "${ts}" ]] && continue
  epoch=$(ts_to_epoch "${ts}")
  [[ -z "${epoch}" ]] && continue
  pending_workers+=("${worker}")
  pending_ts+=("${ts}")
done < <(jq -r --arg sid "${SESSION_ID}" '
  select(.event == "spawn_attempt" and .session_id == $sid) |
  [(.worker // "unknown"), .ts] | @tsv
' "${EVENTS_FILE}" 2>/dev/null)

if [[ "${#pending_workers[@]}" -eq 0 ]]; then
  echo "timeout-watchdog: no spawn_attempt — session=${SESSION_ID}"
  exit 0
fi

# 2. spawn_success / spawn_succeeded 된 워커 집합 (macOS bash 3.2 호환)
# v1.3.6: spawn_succeeded (실제 pane 확인) 추가. spawn_success (요청서 드롭 완료)
# 는 기존 호환성을 위해 유지. 둘 중 하나라도 있으면 pending 에서 제거.
# 포맷: " worker-1 worker-2 worker-3 " (앞뒤 공백으로 부분매칭 방어)
succeeded_list=" "
while IFS= read -r worker; do
  [[ -z "${worker}" ]] && continue
  # 워커 이름 자체에 공백이 없다고 가정 (company-emit 검증 대상)
  succeeded_list="${succeeded_list}${worker} "
done < <(jq -r --arg sid "${SESSION_ID}" '
  select((.event == "spawn_success" or .event == "spawn_succeeded") and .session_id == $sid) |
  (.worker // "unknown")
' "${EVENTS_FILE}" 2>/dev/null)

# 3. pending 에 남은 워커 + threshold 초과 판정
timeout_workers=()
timeout_ts_list=()

for i in "${!pending_workers[@]}"; do
  w="${pending_workers[$i]}"
  t="${pending_ts[$i]}"
  # 이미 성공한 워커는 skip (공백 경계 매칭으로 부분 매칭 오검 방어)
  if [[ "${succeeded_list}" == *" ${w} "* ]]; then
    continue
  fi
  attempt_epoch=$(ts_to_epoch "${t}")
  [[ -z "${attempt_epoch}" ]] && continue
  elapsed=$((now_epoch - attempt_epoch))
  if (( elapsed > THRESHOLD_SECONDS )); then
    timeout_workers+=("${w}")
    timeout_ts_list+=("${t}")
  fi
done

if [[ "${#timeout_workers[@]}" -eq 0 ]]; then
  echo "timeout-watchdog: CLEAN — session=${SESSION_ID} (pending=${#pending_workers[@]}, threshold=${THRESHOLD_SECONDS}s)"
  exit 0
fi

echo "timeout-watchdog: TIMEOUT — session=${SESSION_ID} workers=${#timeout_workers[@]} threshold=${THRESHOLD_SECONDS}s"
for i in "${!timeout_workers[@]}"; do
  echo "  ✗ ${timeout_workers[$i]} (spawn_attempt=${timeout_ts_list[$i]})"
done

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "timeout-watchdog: dry-run — emit skipped"
  exit 0
fi

# 4. worker_timeout emit (각 타임아웃 워커마다 한 번씩)
# severity=P1, idempotency_key 는 spawn_attempt ts 로 고정 → 반복 실행 dedupe
for i in "${!timeout_workers[@]}"; do
  w="${timeout_workers[$i]}"
  t="${timeout_ts_list[$i]}"
  idem="${SESSION_ID}:${w}:worker_timeout:${t}"
  bash "${SCRIPT_DIR}/company-emit.sh" "worker_timeout" "${SESSION_ID}" "${PROJECT_ROOT}" \
    "worker=${w}" \
    "spawn_attempt_ts=${t}" \
    "threshold_seconds=${THRESHOLD_SECONDS}" \
    "severity=P1" \
    "idempotency_key=${idem}" \
    >/dev/null 2>&1 || true
done

# 5. Registry canonical 합성 — `stall_detected` (timing-based ADR v0.2 D2-A)
#    legacy emit 흐름은 위에서 끝났고, 여기는 추가 SSOT 매핑 (best-effort).
#    runner 산출: registry snapshot 조회 후 record 의 .runner 사용 (marker 파일
#    포맷이 4종 runner 별로 통일 안 됨 → ADR D2-A 의 "후자" 옵션).
if [[ -f "${SCRIPT_DIR}/worker-registry-lib.sh" ]] && command -v jq >/dev/null 2>&1; then
  # 이중 source 방지 가드 (lib 내부 _COMPANY_WORKER_REGISTRY_LIB_LOADED).
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/worker-registry-lib.sh" 2>/dev/null || true
  if declare -f registry_append_event >/dev/null 2>&1; then
    snap="$(registry_get_snapshot "${PROJECT_ROOT}" 2>/dev/null || echo '{"workers":{}}')"
    for i in "${!timeout_workers[@]}"; do
      w="${timeout_workers[$i]}"
      t="${timeout_ts_list[$i]}"
      wid="wkr-${SESSION_ID}-${w}"
      runner="$(echo "${snap}" | jq -r --arg w "${wid}" '.workers[$w].runner // "unknown"' 2>/dev/null)"
      payload="$(jq -S -c -n --arg last "${t}" --argjson th "${THRESHOLD_SECONDS}" \
        '{last_seen_at:$last, threshold_sec:$th}')"
      registry_append_event "${PROJECT_ROOT}" stall_detected "${wid}" "${runner}" "${payload}" \
        >/dev/null 2>&1 || echo "timeout-watchdog: registry append failed (worker=${w}, ignored)" >&2
    done
  fi
fi

exit 0
