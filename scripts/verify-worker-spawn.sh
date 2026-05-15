#!/usr/bin/env bash
set -euo pipefail

# verify-worker-spawn.sh (v1.3.7)
#
# 목적: 워커 pane/컨텍스트가 실제로 reachable 해졌는지를 확인하고 canonical 이벤트를
#       emit 한다. v1.3.7 부터는 runner 추상화에 맞춰 tmux 하드코딩을 제거했다.
#
# 이벤트 semantics (v1.3.7):
#   - spawn_prepared   : prepare-worker.sh 가 worker-request.md 를 드롭한 시점 (prepare-worker 에서 emit)
#   - spawn_started    : 러너가 spawn_worker 를 받아들인 시점 (runner 어댑터에서 emit)
#   - spawn_ready      : 워커가 실제로 reachable (tmux 면 pane 보임, sequential 이면 즉시) — 본 스크립트
#   - worker_output_ready : compact-plan/result 가 관측됨 (result-collector.sh)
#
# 하위 호환: 기존 spawn_success / spawn_succeeded 이벤트도 병행 emit 한다. watchdog 과
#           runtime-insights 파서가 두 이벤트 모두를 인식하도록 유지.
#
# 사용:
#   bash verify-worker-spawn.sh <session_id> <worker_name> [project_root] [timeout_sec=30] [interval=2]
#
# 멱등성: 동일 session/worker 에 대해 spawn_succeeded 마커가 이미 있으면 skip.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./runner-lib.sh
source "${SCRIPT_DIR}/runner-lib.sh"

SESSION_ID="${1:-}"
WORKER_NAME="${2:-}"
PROJECT_ROOT="${3:-.}"
TIMEOUT_SEC="${4:-30}"
INTERVAL_SEC="${5:-2}"

if [[ -z "${SESSION_ID}" || -z "${WORKER_NAME}" ]]; then
  echo "Usage: $0 <session_id> <worker_name> [project_root] [timeout_sec=30] [interval=2]" >&2
  exit 1
fi

if ! [[ "${TIMEOUT_SEC}" =~ ^[0-9]+$ ]]; then
  echo "verify-worker-spawn: invalid timeout (숫자만): ${TIMEOUT_SEC}" >&2
  exit 1
fi
if ! [[ "${INTERVAL_SEC}" =~ ^[0-9]+$ ]] || (( INTERVAL_SEC < 1 )); then
  echo "verify-worker-spawn: invalid interval (>=1 정수): ${INTERVAL_SEC}" >&2
  exit 1
fi

MARKER_DIR="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}"
MARKER="${MARKER_DIR}/spawn_succeeded"

# Phase 2 (2026-05-13) D1-D: marker early-return 블록을 RUNNER 결정 이후로 이동.
# legacy marker-only 워커 케이스 (case B) — backfill 거부 + Phase 5 doctor 위임.
# Marker early-return 자체는 RUNNER 결정 + registry_worker_exists 호출 후 수행.

# Runner 결정: preflight.json 이 있으면 그 값을, 없으면 COMPANY_RUNNER env 를, 그래도
# 없으면 현재 컨텍스트 기준 auto 로 추론한다. OMC_NO_TMUX=1 하위 호환도 유지.
_preflight="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/preflight.json"
RUNNER=""
if [[ -f "${_preflight}" ]] && command -v jq >/dev/null 2>&1; then
  RUNNER="$(jq -r '.runner // empty' "${_preflight}" 2>/dev/null || printf '')"
fi
if [[ -z "${RUNNER}" ]]; then
  if [[ -n "${COMPANY_RUNNER:-}" ]]; then
    RUNNER="${COMPANY_RUNNER}"
  elif [[ "${OMC_NO_TMUX:-}" == "1" ]] || [[ -z "${TMUX:-}" ]] || ! command -v tmux >/dev/null 2>&1; then
    RUNNER="sequential"
  else
    RUNNER="tmux"
  fi
fi

emit() {
  bash "${SCRIPT_DIR}/company-emit.sh" "$@" >/dev/null 2>&1 || true
}

# Phase 2 (2026-05-13) D1-D: registry-aware marker early-return.
# 결정문: docs/decisions/2026-05-12-worker-registry-phase2.md v0.5 D1-D
# (line 51 의 기존 marker early-return 블록은 위에서 삭제됨 — RUNNER 결정 이후 위치로 이동)
_registry_lib_path="${SCRIPT_DIR}/worker-registry-lib.sh"
if [[ -f "${MARKER}" ]]; then
  worker_id="wkr-${SESSION_ID}-${WORKER_NAME}"
  if [[ -f "${_registry_lib_path}" ]] && command -v jq >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    source "${_registry_lib_path}"
    registry_worker_exists "${PROJECT_ROOT}" "${worker_id}"; _reg_rc=$?
    case "${_reg_rc}" in
      0)
        echo "verify-worker-spawn: already verified — ${SESSION_ID}/${WORKER_NAME}"
        exit 0
        ;;
      1)
        # case B: stale marker without registry record — backfill 거부 + Phase 5 doctor 위임
        echo "verify-worker-spawn: WARNING stale marker without registry record for ${worker_id}" >&2
        echo "  Phase 5 doctor 가 정리 대상으로 진단 예정." >&2
        exit 0
        ;;
      2)
        echo "verify-worker-spawn: registry lock unavailable — proceeding with legacy early-return for ${worker_id}" >&2
        exit 0
        ;;
    esac
  else
    # registry lib 부재 (Phase 1 미머지) — legacy 행동 유지
    echo "verify-worker-spawn: already verified — ${SESSION_ID}/${WORKER_NAME}"
    exit 0
  fi
fi

mark_ready_and_emit() {
  local mode="$1"; shift
  mkdir -p "${MARKER_DIR}"

  # Phase 2 (2026-05-13) D1-D: registry append spawn_ready (legacy emit 보다 먼저)
  if [[ -f "${_registry_lib_path}" ]] && command -v jq >/dev/null 2>&1; then
    local worker_id="wkr-${SESSION_ID}-${WORKER_NAME}"
    # runner_handle 산출 (Phase 0 D3-B 동결값, prefix 없음)
    local rh="unknown"
    case "${RUNNER}" in
      sequential) rh="inline:${SESSION_ID}" ;;
      tmux) rh="$(tmux display-message -p '#S:#I.#P' 2>/dev/null || echo 'unknown')" ;;
      cmux)
        local _surface="unknown"
        if [[ -f "${_preflight}" ]]; then
          _surface="$(jq -r '.cmux_surface_id // empty' "${_preflight}" 2>/dev/null || true)"
          [[ -n "${_surface}" ]] || _surface="unknown"
        fi
        rh="surface:${_surface}"
        ;;
      manual) rh="marker:${MARKER_DIR}/spawn.started" ;;
    esac
    local ready_payload
    ready_payload="$(jq -S -c -n --arg rh "${rh}" '{runner_handle:$rh}')"
    registry_append_event "${PROJECT_ROOT}" spawn_ready "${worker_id}" "${RUNNER}" "${ready_payload}" \
      || echo "verify-worker-spawn: registry append (spawn_ready) failed (legacy fallback)" >&2
  fi

  printf 'mode: %s\nts: %s\n' "${mode}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${MARKER}"
  # 신규: spawn_ready + 호환: spawn_succeeded 병행
  emit "spawn_ready" "${SESSION_ID}" "${PROJECT_ROOT}" "worker=${WORKER_NAME}" "runner=${RUNNER}" "$@"
  emit "spawn_succeeded" "${SESSION_ID}" "${PROJECT_ROOT}" "worker=${WORKER_NAME}" "runner=${RUNNER}" "mode=${mode}" "$@"
}

# Phase 2 (2026-05-13) D1-D: spawn_failure 도 registry crash_detected append (post-spawn 영역만).
emit_failure_with_registry() {
  local reason="$1" mode="$2"
  emit "spawn_failure" "${SESSION_ID}" "${PROJECT_ROOT}" \
    "worker=${WORKER_NAME}" "reason=${reason}" "mode=${mode}"
  if [[ -f "${_registry_lib_path}" ]] && command -v jq >/dev/null 2>&1; then
    local worker_id="wkr-${SESSION_ID}-${WORKER_NAME}"
    registry_worker_exists "${PROJECT_ROOT}" "${worker_id}"; local _frc=$?
    if [[ "${_frc}" == "0" ]]; then
      registry_append_event "${PROJECT_ROOT}" crash_detected "${worker_id}" "${RUNNER}" \
        "$(jq -S -c -n --arg er "${reason}" '{exit_reason:$er}')" \
        || true
    fi
    # _frc==1 (pre-spawn) 또는 2 (lock 실패) 는 registry ignore (legacy emit 만)
  fi
}

# ─── 러너별 분기 ────────────────────────────────────────────────────────────
case "${RUNNER}" in
  sequential|manual)
    # 개념상 pane 이 필요 없으므로 즉시 ready 선언.
    mark_ready_and_emit "${RUNNER}"
    echo "verify-worker-spawn: ${RUNNER}-mode OK — ${SESSION_ID}/${WORKER_NAME}"
    exit 0
    ;;
  tmux)
    # tmux 어댑터 경로: 기존 pane_count>=2 검증 유지. 단, 현재 tmux 안이 아닌 경우
    # (강제 지정이지만 감지 실패) sequential 마킹으로 soft-pass.
    if ! command -v tmux >/dev/null 2>&1 || [[ -z "${TMUX:-}" ]]; then
      mark_ready_and_emit "tmux-no-client"
      echo "verify-worker-spawn: tmux runner but not inside tmux — soft OK (${SESSION_ID}/${WORKER_NAME})" >&2
      exit 0
    fi
    elapsed=0
    while (( elapsed < TIMEOUT_SEC )); do
      cnt="$(tmux list-panes -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' ')"
      if [[ "${cnt}" =~ ^[0-9]+$ ]] && (( cnt >= 2 )); then
        mark_ready_and_emit "tmux" "pane_count=${cnt}"
        echo "verify-worker-spawn: OK — ${SESSION_ID}/${WORKER_NAME} (pane_count=${cnt}, elapsed=${elapsed}s)"
        exit 0
      fi
      sleep "${INTERVAL_SEC}"
      elapsed=$((elapsed + INTERVAL_SEC))
    done
    emit_failure_with_registry "no-pane-within-${TIMEOUT_SEC}s" "tmux"
    echo "verify-worker-spawn: TIMEOUT — ${SESSION_ID}/${WORKER_NAME} (${TIMEOUT_SEC}s 내 pane 미확인)" >&2
    echo "  hint: 워커 pane 을 수동으로 띄운 뒤 다시 실행하거나 'company recover ${SESSION_ID}' 를 쓰세요." >&2
    exit 2
    ;;
  cmux)
    if ! command -v cmux >/dev/null 2>&1 || [[ -z "${CMUX_PANEL_ID:-}${CMUX_WORKSPACE_ID:-}" ]]; then
      mark_ready_and_emit "cmux-no-client"
      echo "verify-worker-spawn: cmux runner but not inside cmux — soft OK (${SESSION_ID}/${WORKER_NAME})" >&2
      exit 0
    fi
    runner_load cmux 2>/dev/null || true
    if declare -f runner_cmux_spawn_worker >/dev/null 2>&1; then
      runner_cmux_spawn_worker "${SESSION_ID}" "${WORKER_NAME}" "${PROJECT_ROOT}" >/dev/null 2>&1 || true
    fi
    target_file="${MARKER_DIR}/cmux-target"
    target=""
    if declare -f _cmux_read_target_file >/dev/null 2>&1; then
      target="$(_cmux_read_target_file "${target_file}" 2>/dev/null || true)"
    elif [[ -s "${target_file}" ]]; then
      target="$(grep -E '^(surface|panel):[^[:space:]]+$' "${target_file}" 2>/dev/null | head -n1 || true)"
    fi
    if [[ "${target}" =~ ^(surface|panel):[^[:space:]]+$ ]]; then
      mark_ready_and_emit "cmux" "target=${target}"
      echo "verify-worker-spawn: OK — ${SESSION_ID}/${WORKER_NAME} (${target})"
      exit 0
    fi
    emit_failure_with_registry "missing-cmux-target" "cmux"
    echo "verify-worker-spawn: cmux target missing — ${SESSION_ID}/${WORKER_NAME}" >&2
    echo "  hint: ${target_file} 첫 줄에 surface:<id> 또는 panel:<id> 를 적고 다시 실행하세요." >&2
    exit 2
    ;;
  *)
    # 구현 안 된 어댑터 (cmux / codex-native 등) — 안전하게 sequential 처럼 soft-pass
    mark_ready_and_emit "${RUNNER}"
    echo "verify-worker-spawn: runner=${RUNNER} (unverified adapter) — soft OK" >&2
    exit 0
    ;;
esac
