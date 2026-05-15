#!/usr/bin/env bash
# scripts/permission-stall-watchdog.sh (v1.4.4 신규)
#
# 목적: 워커 panel 이 권한 prompt 에 막혀 멈춰 있을 때, 메인(리더) 이 다음
#       체크 사이클 전까지 그 사실을 모르는 "메인 멍 상태" 를 해소한다.
#       각 워커 pane 콘텐츠를 capture 하여 권한 prompt 시그너처를 매칭하고,
#       시그너처가 threshold 초 이상 지속되면 canonical 이벤트
#       `worker_blocked_on_permission` 을 emit 한다.
#
# 정책 (timeout-watchdog 와 동일 운영 모델):
#   - one-shot 스캔만 수행. HTTP/sleep loop/daemon 금지 — cron/launchd 또는
#     리더 호출(`company status` 등) 로 주기 실행하는 패턴.
#   - capture 실패 / 어댑터 미지원 → silent skip (rc=0).
#   - emit 은 best-effort. 실패해도 메인 흐름을 막지 않는다.
#
# 사용:
#   bash scripts/permission-stall-watchdog.sh <session_id> [project_root] [threshold_seconds] [--dry-run]
#   기본 threshold: 120 초 (권한 prompt 짧은 stall 도 빠르게 캐치)
#
# 동작:
#   1. session 의 모든 워커 디렉토리 순회
#   2. 각 워커:
#      - 어댑터의 `capture_worker_pane` 으로 가시 영역 capture
#      - 권한 prompt 시그너처 매칭 (regex 다중)
#      - 시그너처 미매칭 → first_seen 마커 클리어
#      - 시그너처 매칭 → first_seen 없으면 now 기록, 있으면 elapsed 계산
#      - elapsed > threshold + emitted 마커와 first_seen 다름 → emit
#   3. emit 후 emitted 마커에 first_seen 기록 (동일 stall window dedupe)
#
# 멱등성:
#   idempotency_key = <session>:<worker>:permission_stall:<first_seen_ts>
#   같은 first_seen_ts 는 emit 한 번만. 사용자가 prompt 응답 → first_seen 클리어 →
#   다음 prompt 발생 시 새 first_seen → 새 emit.
#
# 시그너처:
#   - "Do you want to ..." / "Do you trust ..."
#   - "Approve this command"
#   - "Run this command\?"
#   - "Allow this"
#   - "(y/N)" / "[y/N]" / "(Y/n)"
#   - "❯ 1" / "❯ Yes" / "❯ No"
#   - "1\. Yes" + "2\. No" 가 같은 capture 안에 모두
#   * Claude Code 권한 prompt 패턴. broad 보다 conservative 우선.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SESSION_ID="${1:-}"
PROJECT_ROOT="${2:-.}"
THRESHOLD_SECONDS="${3:-120}"
DRY_RUN=0
if [[ "${4:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

if [[ -z "${SESSION_ID}" ]]; then
  echo "Usage: $0 <session_id> [project_root] [threshold_seconds] [--dry-run]" >&2
  exit 1
fi

if ! [[ "${THRESHOLD_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "permission-stall-watchdog: invalid threshold (숫자만): ${THRESHOLD_SECONDS}" >&2
  exit 1
fi

WORKERS_DIR="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers"
PREFLIGHT="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/preflight.json"

if [[ ! -d "${WORKERS_DIR}" ]]; then
  echo "permission-stall-watchdog: workers dir 없음 — session=${SESSION_ID} (정상 무동작)"
  exit 0
fi

# 어댑터 로드 (preflight 기반 또는 inside-context 추론).
RUNNER=""
if [[ -f "${PREFLIGHT}" ]] && command -v jq >/dev/null 2>&1; then
  RUNNER="$(jq -r '.runner // empty' "${PREFLIGHT}" 2>/dev/null)"
fi
if [[ -z "${RUNNER}" ]]; then
  if [[ -n "${TMUX:-}" ]]; then
    RUNNER="tmux"
  elif [[ -n "${CMUX_PANEL_ID:-}${CMUX_WORKSPACE_ID:-}" ]]; then
    RUNNER="cmux"
  fi
fi

case "${RUNNER}" in
  tmux|cmux) ;;
  *)
    echo "permission-stall-watchdog: capture 미지원 러너 (${RUNNER:-none}) — skip"
    exit 0
    ;;
esac

# runner-lib + 해당 어댑터 source
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/runner-lib.sh"
runner_load "${RUNNER}" 2>/dev/null || {
  echo "permission-stall-watchdog: 어댑터 로드 실패 — runner=${RUNNER}" >&2
  exit 0
}
if ! runner_has_fn "${RUNNER}" capture_worker_pane; then
  echo "permission-stall-watchdog: ${RUNNER} 어댑터에 capture_worker_pane 없음 — skip"
  exit 0
fi

now_epoch=$(date -u +%s)
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 권한 prompt 시그너처 (extended regex).
# 한 라인이라도 매치되면 stall 후보. broad 한 패턴은 다중 라인 동시 매치 (yes+no
# 라인 페어) 로 강화.
SIGNATURE_REGEX='(Do you (want|trust)|Approve this command|Run this command\?|Allow this|\(y/N\)|\(Y/n\)|\[y/N\]|❯[[:space:]]*(Yes|No|1)|^[[:space:]]*1\.[[:space:]]*Yes)'

emitted_count=0
detected_count=0

while IFS= read -r worker_dir; do
  [[ -d "${worker_dir}" ]] || continue
  worker="$(basename "${worker_dir}")"
  state_first="${worker_dir}/.permission-stall.first_seen"
  state_emitted="${worker_dir}/.permission-stall.emitted"

  # capture
  capture_text="$(runner_call "${RUNNER}" capture_worker_pane "${SESSION_ID}" "${worker}" "${PROJECT_ROOT}" 2>/dev/null || true)"
  if [[ -z "${capture_text}" ]]; then
    # capture 실패 — 마커는 보존(이전 stall window 가 살아 있을 수 있음)
    continue
  fi

  if printf '%s\n' "${capture_text}" | grep -E -q "${SIGNATURE_REGEX}"; then
    # 시그너처 매칭 — stall 후보
    detected_count=$((detected_count + 1))
    if [[ ! -f "${state_first}" ]]; then
      printf '%s\n' "${now_iso}" > "${state_first}"
      continue
    fi
    first_iso="$(head -n1 "${state_first}" 2>/dev/null | tr -d '\r' || echo '')"
    [[ -n "${first_iso}" ]] || { printf '%s\n' "${now_iso}" > "${state_first}"; continue; }
    # ISO → epoch (macOS/Linux 호환)
    first_epoch="$(date -d "${first_iso}" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "${first_iso}" +%s 2>/dev/null || echo '')"
    [[ -n "${first_epoch}" ]] || continue
    elapsed=$((now_epoch - first_epoch))
    if (( elapsed < THRESHOLD_SECONDS )); then
      continue
    fi
    # dedupe — emitted 마커가 같은 first_iso 이면 skip
    if [[ -f "${state_emitted}" ]]; then
      emitted_iso="$(head -n1 "${state_emitted}" 2>/dev/null | tr -d '\r' || echo '')"
      if [[ "${emitted_iso}" == "${first_iso}" ]]; then
        continue
      fi
    fi
    # emit
    echo "permission-stall-watchdog: STALL — worker=${worker} elapsed=${elapsed}s threshold=${THRESHOLD_SECONDS}s first_seen=${first_iso}"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      continue
    fi
    idem="${SESSION_ID}:${worker}:permission_stall:${first_iso}"
    bash "${SCRIPT_DIR}/company-emit.sh" "worker_blocked_on_permission" "${SESSION_ID}" "${PROJECT_ROOT}" \
      "worker=${worker}" \
      "first_seen_ts=${first_iso}" \
      "elapsed_seconds=${elapsed}" \
      "threshold_seconds=${THRESHOLD_SECONDS}" \
      "runner=${RUNNER}" \
      "severity=P1" \
      "idempotency_key=${idem}" \
      >/dev/null 2>&1 || true
    printf '%s\n' "${first_iso}" > "${state_emitted}"
    emitted_count=$((emitted_count + 1))

    # Registry canonical 합성 — `permission_prompt` (timing-based ADR v0.2 D2-B).
    # legacy `worker_blocked_on_permission` 흐름은 위에서 끝남. SSOT 매핑은 best-effort.
    if [[ -f "${SCRIPT_DIR}/worker-registry-lib.sh" ]]; then
      # shellcheck disable=SC1091
      source "${SCRIPT_DIR}/worker-registry-lib.sh" 2>/dev/null || true
      if declare -f registry_append_event >/dev/null 2>&1; then
        wid="wkr-${SESSION_ID}-${worker}"
        registry_append_event "${PROJECT_ROOT}" permission_prompt "${wid}" "${RUNNER}" \
          "$(jq -S -c -n '{prompt_type:"stall_signature"}')" \
          >/dev/null 2>&1 || true
      fi
    fi
  else
    # 시그너처 미매칭 — stall 마커 클리어
    if [[ -f "${state_first}" ]]; then
      # 이전에 stall 감지된 워커가 풀린 경우만 emit (false alarm clear 회피)
      cleared_first="$(head -n1 "${state_first}" 2>/dev/null | tr -d '\r' || echo '')"
      rm -f "${state_first}" "${state_emitted}" 2>/dev/null || true

      # legacy clear emit (신규 — ADR v0.2 D2-B 가 도입)
      if [[ "${DRY_RUN}" -ne 1 ]] && [[ -n "${cleared_first}" ]]; then
        bash "${SCRIPT_DIR}/company-emit.sh" "worker_permission_cleared" "${SESSION_ID}" "${PROJECT_ROOT}" \
          "worker=${worker}" \
          "first_seen_ts=${cleared_first}" \
          "runner=${RUNNER}" \
          "idempotency_key=${SESSION_ID}:${worker}:permission_cleared:${cleared_first}" \
          >/dev/null 2>&1 || true

        # Registry canonical 합성 — `permission_resolved` (actor=user).
        # Phase 0 D3-C 규칙: 직전 waiting_permission 만 running 복원, 아니면 ignore.
        if [[ -f "${SCRIPT_DIR}/worker-registry-lib.sh" ]]; then
          # shellcheck disable=SC1091
          source "${SCRIPT_DIR}/worker-registry-lib.sh" 2>/dev/null || true
          if declare -f registry_append_event >/dev/null 2>&1; then
            wid="wkr-${SESSION_ID}-${worker}"
            registry_append_event "${PROJECT_ROOT}" permission_resolved "${wid}" "${RUNNER}" \
              "$(jq -S -c -n '{resolution:"allowed", actor:"user"}')" \
              >/dev/null 2>&1 || true
          fi
        fi
      fi
    else
      # false alarm — 마커 부재. 단순 정리 (silent rm 유지).
      rm -f "${state_emitted}" 2>/dev/null || true
    fi
  fi
done < <(find "${WORKERS_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

echo "permission-stall-watchdog: session=${SESSION_ID} runner=${RUNNER} detected=${detected_count} emitted=${emitted_count} threshold=${THRESHOLD_SECONDS}s"
exit 0
