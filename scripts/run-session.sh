#!/usr/bin/env bash
set -euo pipefail

# run-session.sh — `company run <topic>` 의 실제 엔트리포인트.
#
# v1.3.7: runner-agnostic. TOPIC/SESSION_ID/PROJECT_ROOT 포지셔널 뒤에
# 선택적으로 --runner=<name> / --no-fallback 플래그를 받을 수 있다.
# 러너 해상도 결과는 preflight.json 에 기록되고 runner_selected 이벤트로 emit.

TOPIC=""
SESSION_ID=""
ROOT="."
RUNNER_FLAG=""
NO_FALLBACK=""
ALLOW_EXPERIMENTAL=""

# 포지셔널 vs 플래그 파싱 — company CLI 가 '--runner=...' 를 뒤에 붙여 넘길 수 있도록
POSITIONAL=()
for _arg in "$@"; do
  case "${_arg}" in
    --runner=*)            RUNNER_FLAG="${_arg}" ;;
    --runner)              RUNNER_FLAG="--runner" ;;  # 다음 토큰을 값으로 소비 — company CLI 에서는 주로 --runner=X 형태
    --no-fallback)         NO_FALLBACK="--no-fallback" ;;
    --allow-experimental)  ALLOW_EXPERIMENTAL="--allow-experimental" ;;
    *)                     POSITIONAL+=("${_arg}") ;;
  esac
done

TOPIC="${POSITIONAL[0]:-}"
SESSION_ID="${POSITIONAL[1]:-}"
ROOT="${POSITIONAL[2]:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${TOPIC}" ]]; then
  echo "Usage: $0 <topic> [session-id] [project-root] [--runner=<name>] [--no-fallback] [--allow-experimental]"
  exit 1
fi

# shellcheck source=./git-worktree-lib.sh
source "${SCRIPT_DIR}/git-worktree-lib.sh"
# shellcheck source=./runner-lib.sh
source "${SCRIPT_DIR}/runner-lib.sh"

PROJECT_ROOT="$(resolve_shared_project_root "${ROOT}")"

# ─── SESSION_ID 추론 ────────────────────────────────────────────────────────
# v1.3.9 P1: tmux/cmux 어느 attached 러너 안이든 SESSION_ID 자동 감지.
# resolve_runner 이전 단계라 stable+experimental 매트릭스를 polling 만 한다 (실행
# 러너 결정은 아래 resolve_runner 가 별도로 수행). 어떤 attached 러너도 잡히지
# 않으면 TOPIC 기반 generate_session_id 로 폴백.
if [[ -z "${SESSION_ID}" ]]; then
  if declare -f runner_probe_session_name >/dev/null 2>&1; then
    _PROBE_OUT="$(runner_probe_session_name 2>/dev/null || true)"
    if [[ -n "${_PROBE_OUT}" ]]; then
      SESSION_ID="$(printf '%s' "${_PROBE_OUT}" | sed -n '2p')"
    fi
    unset _PROBE_OUT
  fi
fi

if [[ -z "${SESSION_ID}" ]]; then
  SESSION_ID="$(generate_session_id "${TOPIC}" "${PROJECT_ROOT}")"
fi

# ─── 세션 준비 ─────────────────────────────────────────────────────────────
bash "${SCRIPT_DIR}/prepare-session.sh" "${SESSION_ID}" "${PROJECT_ROOT}" "${TOPIC}" >/dev/null

# ─── 러너 해상도 + preflight ──────────────────────────────────────────────
# resolve_runner 는 전역 RUNNER_SELECTED/RUNNER_SOURCE/RUNNER_FALLBACK_REASON 을 세팅.
# 실패(비 0) 시 --no-fallback 이 설정됐고 요청 러너가 없다는 뜻 → 종료.
# 플래그를 배열로 모아 한 번에 전달 (set -u 하에서 빈 배열 확장 가드).
_RESOLVE_ARGS=()
[[ -n "${RUNNER_FLAG}" ]]          && _RESOLVE_ARGS+=("${RUNNER_FLAG}")
[[ -n "${NO_FALLBACK}" ]]          && _RESOLVE_ARGS+=("${NO_FALLBACK}")
[[ -n "${ALLOW_EXPERIMENTAL}" ]]   && _RESOLVE_ARGS+=("${ALLOW_EXPERIMENTAL}")

set +e
resolve_runner ${_RESOLVE_ARGS[@]+"${_RESOLVE_ARGS[@]}"}
_resolve_rc=$?
set -e

if [[ "${_resolve_rc}" == "5" ]]; then
  # experimental 러너를 opt-in 없이 명시 선택한 경우 — resolve_runner 가 이유 출력 완료
  cat >&2 <<EOF

💡 힌트:
  - '--allow-experimental' 또는 COMPANY_ALLOW_EXPERIMENTAL=1 을 추가해 실험 러너를 명시 opt-in 해 주세요.
  - 안정 러너 (${RUNNER_STATES_stable:-sequential tmux manual}) 는 플래그 없이 그대로 사용할 수 있습니다.
EOF
  exit "${_resolve_rc}"
elif [[ "${_resolve_rc}" != "0" ]]; then
  # explicit --no-fallback 실패 — actionable hint 는 resolve_runner 가 이미 stderr 에 찍음
  cat >&2 <<EOF
[ERROR] 요청한 러너를 사용할 수 없고 --no-fallback 이 설정돼 있습니다.
        원인: ${RUNNER_FALLBACK_REASON:-unknown}

💡 힌트:
  - 안정 러너(${RUNNER_STATES_stable:-sequential tmux manual}) 중 가용한 환경에서 재실행하거나 '--runner=sequential' 로 폴백하세요.
  - cmux 등 experimental 러너는 '--runner=<name> --allow-experimental' 로 명시 opt-in 해야 사용됩니다.
EOF
  exit "${_resolve_rc}"
fi

# 사용자 친화적 배너
runner_banner

# preflight.json drop
_PREFLIGHT="$(runner_write_preflight "${PROJECT_ROOT}" "${SESSION_ID}")"

# runner_selected 이벤트 emit
runner_emit_selected "${PROJECT_ROOT}" "${SESSION_ID}"

# 실제로 쓰일 어댑터 load (resolve 단계에서 load 되지만 안전망)
runner_load "${RUNNER_SELECTED}" 2>/dev/null || true

# ─── 라우팅 + 워커 준비 ────────────────────────────────────────────────────
ROUTING_OUTPUT="$(bash "${SCRIPT_DIR}/recommend-routing.sh" "${TOPIC}" "${PROJECT_ROOT}" --record)"

extract_field() {
  local key="$1"
  printf '%s\n' "${ROUTING_OUTPUT}" | awk -F': ' -v key="${key}" '$1 == key {print $2; exit}'
}

COST_MODE="$(extract_field "Cost Mode")"
AUTO_COST_HINT="$(extract_field "Auto Cost Hint")"
PRIMARY_WORKER="$(extract_field "Recommended Primary Worker")"
SUPPORTING_WORKERS="$(extract_field "Supporting Workers")"
WORKER_LIMIT="$(extract_field "Worker Limit")"
ROUTING_WHY="$(extract_field "Routing Why")"
SIMILAR_PATTERN="$(extract_field "Similar Session Pattern")"

if [[ -z "${PRIMARY_WORKER}" ]]; then
  echo "Failed to resolve primary worker."
  exit 1
fi

# v1.5.5: 라우팅 추천을 환경변수로 강제 override.
# `company run --primary X --secondary Y,Z` 가 v1.5.3 부터 환경변수를 export 하지만
# 실제 라우팅 강제는 이번 버전에서 처음 반영. 환경변수가 없으면 추천 그대로 사용.
if [[ -n "${COMPANY_PRIMARY_WORKER:-}" ]]; then
  if [[ "${COMPANY_PRIMARY_WORKER}" != "${PRIMARY_WORKER}" ]]; then
    echo "[INFO] Primary worker overridden by COMPANY_PRIMARY_WORKER: ${PRIMARY_WORKER} → ${COMPANY_PRIMARY_WORKER}"
  fi
  PRIMARY_WORKER="${COMPANY_PRIMARY_WORKER}"
fi
if [[ -n "${COMPANY_SECONDARY_WORKERS:-}" ]]; then
  if [[ "${COMPANY_SECONDARY_WORKERS}" != "${SUPPORTING_WORKERS}" ]]; then
    echo "[INFO] Supporting workers overridden by COMPANY_SECONDARY_WORKERS: ${SUPPORTING_WORKERS:-none} → ${COMPANY_SECONDARY_WORKERS}"
  fi
  SUPPORTING_WORKERS="${COMPANY_SECONDARY_WORKERS}"
fi

# sequential / manual 러너에서는 병렬 지원이 없으므로 supporting workers 스폰을
# 강제로 제한한다. 준비(prepare-worker)는 그대로 돌려서 요청서는 다 생성하되,
# supporting workers 의 실제 '스폰' 은 사용자가 필요 시 순서대로 진행하라고 안내만 남긴다.
PARALLEL_OK="$(runner_parallel_available "${RUNNER_SELECTED}")"

prepared_workers=()
# COMPANY_RUNNER 를 하위 스크립트(prepare-worker → verify-worker-spawn 등) 에도 전달
export COMPANY_RUNNER="${RUNNER_SELECTED}"

_maybe_spawn_via_runner() {
  # sequential/manual 러너는 준비 = 스폰이므로 즉시 spawn_worker 를 호출해
  # spawn_started + spawn_ready 까지 한 턴에 진행한다. tmux 러너는 리더 Claude 가
  # 별도 pane 을 띄워야 하므로 여기서는 건드리지 않는다.
  #
  # v1.5.6: cmux 분기는 spawn_worker 를 직접 호출하지 않지만(실제 pane 생성은
  # 리더가 cmux-start-worker.sh 로 한다), precheck 단계 events emit 보장을 위해
  # spawn_attempted / spawn_failed 까지는 항상 events.jsonl 에 남긴다.
  local _w="$1"
  local _rc=0
  case "${RUNNER_SELECTED}" in
    sequential|manual)
      runner_call "${RUNNER_SELECTED}" spawn_worker "${SESSION_ID}" "${_w}" "${PROJECT_ROOT}" || true
      # verify-worker-spawn.sh 가 spawn_ready 를 찍도록 후행 호출 (tmux 외에는 즉시 soft OK)
      bash "${SCRIPT_DIR}/verify-worker-spawn.sh" "${SESSION_ID}" "${_w}" "${PROJECT_ROOT}" >/dev/null 2>&1 || true
      ;;
    cmux)
      # cmux 는 리더가 별도 pane 을 띄우는 구조라 여기서 spawn 자체는 안 한다.
      # 다만 git precheck 같은 사전 조건은 미리 검증해 silent fail 을 피한다.
      bash "${SCRIPT_DIR}/company-emit.sh" "spawn_attempted" "${SESSION_ID}" "${PROJECT_ROOT}" \
        "worker=${_w}" "runner=cmux" "phase=run-session" >/dev/null 2>&1 || true
      if declare -f runner_cmux_precheck_git_repo >/dev/null 2>&1; then
        if ! runner_cmux_precheck_git_repo "${PROJECT_ROOT}" >&2; then
          bash "${SCRIPT_DIR}/company-emit.sh" "spawn_failed" "${SESSION_ID}" "${PROJECT_ROOT}" \
            "worker=${_w}" "runner=cmux" "reason=not-a-git-repo" "phase=run-session" >/dev/null 2>&1 || true
          _rc=6
        fi
      fi
      ;;
    *) ;;
  esac
  return "${_rc}"
}

# v1.5.11: TOPIC 을 prepare-worker 에 자동 전달 — worker-request.md 에 토픽이
# 박혀있지 않으면 워커가 잔여 컨텍스트로 표류한다 (R-2026-05-08).
bash "${SCRIPT_DIR}/prepare-worker.sh" "${PRIMARY_WORKER}" "${SESSION_ID}" "${PROJECT_ROOT}" --topic "${TOPIC}" >/dev/null
prepared_workers+=("${PRIMARY_WORKER}")
set +e
_maybe_spawn_via_runner "${PRIMARY_WORKER}"
_spawn_rc=$?
set -e
if [[ "${_spawn_rc}" != "0" ]]; then
  echo "[ERROR] cmux runner pre-flight 실패 — 위 메시지의 해결 가이드를 따라 재실행하세요." >&2
  exit "${_spawn_rc}"
fi

if [[ -n "${SUPPORTING_WORKERS}" && "${SUPPORTING_WORKERS}" != "none" ]]; then
  IFS=',' read -r -a support_array <<< "${SUPPORTING_WORKERS}"
  for worker in "${support_array[@]}"; do
    worker="$(printf '%s' "${worker}" | xargs)"
    [[ -n "${worker}" ]] || continue
    bash "${SCRIPT_DIR}/prepare-worker.sh" "${worker}" "${SESSION_ID}" "${PROJECT_ROOT}" --topic "${TOPIC}" >/dev/null
    prepared_workers+=("${worker}")
    # sequential/manual 러너는 병렬 불가이므로 supporting workers 는 prepare 만 하고
    # spawn_worker 는 호출하지 않는다. tmux 러너에서는 리더가 pane 을 띄울 때
    # verify-worker-spawn.sh 가 spawn_ready 를 찍는다.
    if [[ "${RUNNER_SELECTED}" == "manual" ]]; then
      # manual 은 준비만 하고 병렬 워커도 파일로만 남긴다 (요청서 생성 메시지는 이미 출력됨).
      :
    fi
  done
fi

SESSION_DIR="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}"
SUMMARY_PATH="${SESSION_DIR}/dispatch-summary.md"
{
  echo "# Dispatch Summary"
  echo
  echo "- Session: \`${SESSION_ID}\`"
  echo "- Topic: ${TOPIC}"
  echo "- Cost Mode: \`${COST_MODE}\`"
  echo "- Auto Cost Hint: \`${AUTO_COST_HINT}\`"
  echo "- Primary Worker: \`${PRIMARY_WORKER}\`"
  echo "- Supporting Workers: \`${SUPPORTING_WORKERS:-none}\`"
  echo "- Worker Limit: \`${WORKER_LIMIT}\`"
  echo "- Routing Why: ${ROUTING_WHY}"
  echo "- Similar Session Pattern: ${SIMILAR_PATTERN:-none}"
  echo "- Runner: \`${RUNNER_SELECTED}\` (source=${RUNNER_SOURCE}${RUNNER_FALLBACK_REASON:+, fallback_reason=${RUNNER_FALLBACK_REASON}})"
  echo "- Parallel Available: ${PARALLEL_OK}"
  echo
  echo "## Prepared Workers"
  echo
  for worker in "${prepared_workers[@]}"; do
    echo "- \`${worker}\` -> \`.company-runtime/sessions/${SESSION_ID}/workers/${worker}/worker-request.md\`"
  done
  echo
  echo "## Next Step"
  echo
  case "${RUNNER_SELECTED}" in
    tmux)
      echo "Spawn the prepared workers as Sonnet agent teams in the current tmux session (attached runner)."
      ;;
    cmux)
      echo "Spawn the prepared workers as Sonnet agent teams in the current cmux workspace (attached runner, experimental)."
      echo
      echo "cmux 권장 경로:"
      echo "  1) bash .company-kit/scripts/cmux-start-worker.sh ${SESSION_ID} <worker> ${PROJECT_ROOT} right"
      echo "  2) 워커 pane 에 Claude 입력창이 보이면:"
      echo "     bash .company-kit/scripts/cmux-submit-worker-message.sh ${SESSION_ID} <worker> ${PROJECT_ROOT}"
      echo
      echo "주의: cmux send ... --press Enter 는 지원 플래그가 아니라 literal 텍스트로 입력될 수 있으므로 사용하지 마세요."
      ;;
    sequential)
      echo "순차 실행 러너: primary worker 요청서를 현재 터미널에서 순서대로 투입하세요."
      echo "병렬 러너가 아니므로 supporting workers 는 primary 완료 후에 수동으로 진행합니다."
      ;;
    manual)
      echo "Manual 러너: 각 worker-request.md 를 확인하고 원하는 CLI 로 직접 워커를 띄우세요."
      ;;
    *)
      echo "Runner=${RUNNER_SELECTED}."
      ;;
  esac
} > "${SUMMARY_PATH}"

# v1.1.0 (C3): 이벤트 로거 — session_prepared 기록
bash "${SCRIPT_DIR}/company-emit.sh" "session_prepared" "${SESSION_ID}" "${PROJECT_ROOT}" \
  "topic=${TOPIC}" "primary=${PRIMARY_WORKER}" "runner=${RUNNER_SELECTED}" >/dev/null 2>&1 || true

# v1.5.6: cmux 러너에서 leader-watcher 백그라운드 데몬 자동 기동.
# 워커 pane 의 권한 게이트 / compact-plan / compact-result 도착을 폴링해
# leader_wake_ready / permission_gate_pending 이벤트로 emit (push 채널).
if [[ "${RUNNER_SELECTED}" == "cmux" ]] && [[ -z "${COMPANY_DISABLE_LEADER_WATCHER:-}" ]]; then
  if [[ -x "${SCRIPT_DIR}/cmux-leader-watcher.sh" ]]; then
    nohup bash "${SCRIPT_DIR}/cmux-leader-watcher.sh" "${SESSION_ID}" "${PROJECT_ROOT}" \
      >"${SESSION_DIR}/leader-watcher.log" 2>&1 &
    disown 2>/dev/null || true
    echo "[INFO] cmux leader-watcher 데몬 기동 (pid=$!) — 권한 게이트/plan 도착을 자동 감지합니다."
  fi
fi

echo "Session: ${SESSION_ID}"
echo "Topic: ${TOPIC}"
echo "Runner: ${RUNNER_SELECTED} (source=${RUNNER_SOURCE}${RUNNER_FALLBACK_REASON:+, fallback_reason=${RUNNER_FALLBACK_REASON}})"
echo "Parallel Available: ${PARALLEL_OK}"
echo "Cost Mode: ${COST_MODE}"
echo "Auto Cost Hint: ${AUTO_COST_HINT}"
echo "Primary Worker: ${PRIMARY_WORKER}"
echo "Supporting Workers: ${SUPPORTING_WORKERS:-none}"
echo "Worker Limit: ${WORKER_LIMIT}"
echo "Preflight: ${_PREFLIGHT#${PROJECT_ROOT}/}"
echo "Dispatch Summary: .company-runtime/sessions/${SESSION_ID}/dispatch-summary.md"
for worker in "${prepared_workers[@]}"; do
  echo "Worker Request: .company-runtime/sessions/${SESSION_ID}/workers/${worker}/worker-request.md"
done
