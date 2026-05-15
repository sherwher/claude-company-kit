#!/usr/bin/env bash
set -euo pipefail

# result-collector.sh (v1.3.6)
#
# 목적: 워커가 compact-result.md 를 쓰면 리더가 실시간으로 인지하도록 감시한다.
#       기존 compact_result_ready 이벤트는 session_closed alias 로만 발화돼
#       세션 종료 전에는 통지되지 않았다. 이 스크립트는 per-worker 감지 후
#       canonical 이벤트 `compact_result_ready` 를 즉시 emit 하고, 가능하면
#       리더 pane 에 tmux display-message 로 알림한다.
#
# 사용:
#   bash result-collector.sh <session_id> [project_root] --oneshot            # 한 번 스캔
#   bash result-collector.sh <session_id> [project_root] --daemon             # 백그라운드 폴링
#   bash result-collector.sh <session_id> [project_root] --daemon --interval=5
#   bash result-collector.sh <session_id> [project_root] --stop               # daemon 종료
#
# 동작:
#   - .company-runtime/sessions/<sid>/workers/*/compact-result.md 의 mtime 추적
#   - 새로 생성되거나 mtime 가 이전보다 더 최근이면 이벤트 emit
#   - daemon 모드: .collector.pid 에 PID 기록, SIGTERM 으로 graceful shutdown
#   - close-session.sh 가 자동 종료 (여부는 close-session 측 구현)
#
# 호환성:
#   - fswatch/inotify 미의존 (macOS bash 3.2 + POSIX find 로 충분)
#   - jq 부재 시 company-emit 가 silent skip → 이벤트는 안 찍혀도 terminal 알림은 계속

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SESSION_ID=""
PROJECT_ROOT="."
MODE=""
INTERVAL=5

for _arg in "$@"; do
  case "${_arg}" in
    --oneshot|--once) MODE="oneshot" ;;
    --daemon)         MODE="daemon" ;;
    --stop)           MODE="stop" ;;
    --interval=*)     INTERVAL="${_arg#--interval=}" ;;
    --help|-h)
      sed -n '4,35p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    -*)
      echo "Unknown option: ${_arg}" >&2
      exit 1
      ;;
    *)
      if [[ -z "${SESSION_ID}" ]]; then
        SESSION_ID="${_arg}"
      else
        PROJECT_ROOT="${_arg}"
      fi
      ;;
  esac
done

if [[ -z "${SESSION_ID}" ]]; then
  echo "Usage: $0 <session_id> [project_root] (--oneshot | --daemon [--interval=N] | --stop)" >&2
  exit 1
fi

if [[ -z "${MODE}" ]]; then
  MODE="oneshot"
fi

if ! [[ "${INTERVAL}" =~ ^[0-9]+$ ]] || (( INTERVAL < 1 )); then
  echo "result-collector: invalid --interval (>=1 정수)" >&2
  exit 1
fi

SESSION_DIR="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}"
WORKERS_DIR="${SESSION_DIR}/workers"
STATE_DIR="${SESSION_DIR}/collector"
PID_FILE="${STATE_DIR}/pid"
SEEN_FILE="${STATE_DIR}/seen.tsv"   # worker\tmtime_epoch 형식

mkdir -p "${STATE_DIR}"

# ── helper ──────────────────────────────────────────────────────────────────
file_mtime_epoch() {
  # macOS(BSD) / Linux(GNU) stat 호환
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

seen_get() {
  local _worker="$1"
  [[ -f "${SEEN_FILE}" ]] || return 0
  # Phase 2 (2026-05-13) D2-A: 키 형식 worker:artifact\tmtime 로 확장.
  # 기존 worker\tmtime 형식 (artifact 누락) 도 호환 — artifact 미지정 시 result 로 간주.
  local _artifact="${2:-result}"
  awk -F'\t' -v key="${_worker}:${_artifact}" -v legacy_w="${_worker}" -v artifact="${_artifact}" \
    '$1==key {print $2; found=1; exit}
     $1==legacy_w && artifact=="result" && !found {print $2; exit}' \
    "${SEEN_FILE}" 2>/dev/null
}

seen_set() {
  local _worker="$1"
  local _epoch="$2"
  local _artifact="${3:-result}"
  local _key="${_worker}:${_artifact}"
  local _tmp
  _tmp="$(mktemp)"
  if [[ -f "${SEEN_FILE}" ]]; then
    # Phase 2: 새 key + legacy key (worker 만) 둘 다 제거 후 재기록 (마이그레이션 호환)
    awk -F'\t' -v k="${_key}" -v lw="${_worker}" \
      '$1!=k && $1!=lw' "${SEEN_FILE}" > "${_tmp}" 2>/dev/null || true
  fi
  printf '%s\t%s\n' "${_key}" "${_epoch}" >> "${_tmp}"
  mv "${_tmp}" "${SEEN_FILE}"
}

# Phase 2 (2026-05-13) D2 — registry 합성 발행 helper.
# 결정문: docs/decisions/2026-05-12-worker-registry-phase2.md v0.5 D2
_REGISTRY_LIB="${SCRIPT_DIR}/worker-registry-lib.sh"
registry_synth_emit() {
  local _event="$1" _worker="$2" _path="$3" _payload_key="$4"
  if [[ ! -f "${_REGISTRY_LIB}" ]] || ! command -v jq >/dev/null 2>&1; then
    return 0  # registry 미설치 또는 jq 부재 — Phase 1 미머지 환경 (silent skip)
  fi
  # shellcheck disable=SC1090
  source "${_REGISTRY_LIB}"
  local _wid="wkr-${SESSION_ID}-${_worker}"
  local _payload
  _payload="$(jq -S -c -n --arg p "${_path}" --arg k "${_payload_key}" \
    '{($k): $p}' 2>/dev/null)" || return 0
  # 합성 발행 — lock 내부 idempotent ignore 가 dedup 보장
  registry_append_event "${PROJECT_ROOT}" "${_event}" "${_wid}" "watcher" "${_payload}" >/dev/null 2>&1 || true
}

leader_notify() {
  local _msg="$1"
  # tmux display-message 로 모든 클라이언트에 1회 표시 (best-effort)
  if command -v tmux >/dev/null 2>&1 && [[ -n "${TMUX:-}" ]]; then
    tmux display-message "${_msg}" 2>/dev/null || true
  fi
  # stderr 에도 한 줄 출력 (daemon 로그용)
  echo "result-collector: ${_msg}" >&2
}

scan_once() {
  local _emitted=0
  [[ -d "${WORKERS_DIR}" ]] || return 0
  while IFS= read -r _worker_dir; do
    [[ -d "${_worker_dir}" ]] || continue
    local _worker
    _worker="$(basename "${_worker_dir}")"

    # ── compact-result.md 감지 (기존) + Phase 2 registry result_emitted 합성 ──
    local _rfile="${_worker_dir}/compact-result.md"
    if [[ -f "${_rfile}" ]]; then
      local _mt
      _mt="$(file_mtime_epoch "${_rfile}")"
      if [[ "${_mt}" =~ ^[0-9]+$ ]]; then
        local _sz
        _sz="$(wc -c < "${_rfile}" 2>/dev/null | tr -d ' ')"
        if [[ "${_sz:-0}" -ge 200 ]]; then
          local _prev_r
          _prev_r="$(seen_get "${_worker}" result)"
          if [[ -z "${_prev_r}" ]] || (( _mt > _prev_r )); then
            bash "${SCRIPT_DIR}/company-emit.sh" "worker_output_ready" "${SESSION_ID}" "${PROJECT_ROOT}" \
              "worker=${_worker}" "artifact=compact-result" "mtime=${_mt}" "size=${_sz}" >/dev/null 2>&1 || true
            bash "${SCRIPT_DIR}/company-emit.sh" "compact_result_ready" "${SESSION_ID}" "${PROJECT_ROOT}" \
              "worker=${_worker}" "mtime=${_mt}" "size=${_sz}" >/dev/null 2>&1 || true
            # Phase 2 D2: registry result_emitted 합성
            registry_synth_emit "result_emitted" "${_worker}" "${_rfile}" "result_path"
            leader_notify "✅ compact-result 도착: ${_worker} (size=${_sz}B)"
            seen_set "${_worker}" "${_mt}" result
            _emitted=$((_emitted + 1))
          fi
        fi
      fi
    fi

    # ── compact-plan.md 감지 (Phase 2 신규) + registry plan_emitted 합성 ──
    local _pfile="${_worker_dir}/compact-plan.md"
    if [[ -f "${_pfile}" ]]; then
      local _pmt
      _pmt="$(file_mtime_epoch "${_pfile}")"
      if [[ "${_pmt}" =~ ^[0-9]+$ ]]; then
        local _psz
        _psz="$(wc -c < "${_pfile}" 2>/dev/null | tr -d ' ')"
        if [[ "${_psz:-0}" -ge 50 ]]; then
          local _prev_p
          _prev_p="$(seen_get "${_worker}" plan)"
          if [[ -z "${_prev_p}" ]] || (( _pmt > _prev_p )); then
            # Phase 2 D2: registry plan_emitted 합성 (lock 내부 idempotent ignore 가 dedup)
            registry_synth_emit "plan_emitted" "${_worker}" "${_pfile}" "plan_path"
            seen_set "${_worker}" "${_pmt}" plan
            _emitted=$((_emitted + 1))
          fi
        fi
      fi
    fi
  done < <(find "${WORKERS_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  return 0
}

# ── mode: stop ──────────────────────────────────────────────────────────────
if [[ "${MODE}" == "stop" ]]; then
  if [[ -f "${PID_FILE}" ]]; then
    _pid="$(cat "${PID_FILE}" 2>/dev/null || echo "")"
    if [[ -n "${_pid}" ]] && kill -0 "${_pid}" 2>/dev/null; then
      kill "${_pid}" 2>/dev/null || true
      echo "result-collector: sent TERM to pid ${_pid}"
    fi
    rm -f "${PID_FILE}"
  else
    echo "result-collector: no daemon running for ${SESSION_ID}"
  fi
  exit 0
fi

# ── mode: oneshot ───────────────────────────────────────────────────────────
if [[ "${MODE}" == "oneshot" ]]; then
  scan_once
  exit 0
fi

# ── mode: daemon ────────────────────────────────────────────────────────────
# 중복 기동 방지
if [[ -f "${PID_FILE}" ]]; then
  _existing="$(cat "${PID_FILE}" 2>/dev/null || echo "")"
  if [[ -n "${_existing}" ]] && kill -0 "${_existing}" 2>/dev/null; then
    echo "result-collector: daemon already running (pid=${_existing})" >&2
    exit 0
  fi
  rm -f "${PID_FILE}"
fi

printf '%s\n' "$$" > "${PID_FILE}"
cleanup_daemon() {
  rm -f "${PID_FILE}"
  exit 0
}
trap cleanup_daemon TERM INT EXIT

echo "result-collector: daemon start (pid=$$, interval=${INTERVAL}s, session=${SESSION_ID})" >&2
while true; do
  scan_once
  sleep "${INTERVAL}"
done
