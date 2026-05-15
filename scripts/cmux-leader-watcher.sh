#!/usr/bin/env bash
set -euo pipefail

# cmux-leader-watcher.sh (v1.5.6)
#
# Background daemon that polls all cmux worker surfaces in a session and
# emits leader_wake_ready events when:
#   1) A worker surface shows a permission gate ("Do you want to proceed?",
#      "1. Yes ... 2. No ..." prompt).
#   2) compact-plan.md becomes non-empty (plan ready for review).
#   3) compact-result.md becomes non-empty AND not the template-example.
#
# This is the push channel that complements the pull-based UserPromptSubmit
# leader-wake hook. Without this watcher, leader has no way to learn that a
# worker pane is blocked on a permission gate inside its TUI.
#
# Usage:
#   bash cmux-leader-watcher.sh <session_id> <project_root> [--once] [--interval=5]
#
# Lifecycle:
#   - Writes PID to .company-runtime/sessions/<session>/leader-watcher.pid
#   - Exits cleanly when session is closed (session_closed event seen) or on
#     SIGTERM. Idempotent: a second start with same session is a no-op.

SESSION_ID="${1:-}"
PROJECT_ROOT_ARG="${2:-.}"

ONCE=""
INTERVAL=5
for _arg in "${@:3}"; do
  case "${_arg}" in
    --once)         ONCE="1" ;;
    --interval=*)   INTERVAL="${_arg#--interval=}" ;;
  esac
done

if [[ -z "${SESSION_ID}" ]]; then
  echo "Usage: $0 <session_id> <project_root> [--once] [--interval=<sec>]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./git-worktree-lib.sh
source "${SCRIPT_DIR}/git-worktree-lib.sh"
# shellcheck source=./runner-lib.sh
source "${SCRIPT_DIR}/runner-lib.sh"

PROJECT_ROOT="$(resolve_shared_project_root "${PROJECT_ROOT_ARG}")"
SESSION_DIR="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}"
PID_FILE="${SESSION_DIR}/leader-watcher.pid"
STATE_DIR="${SESSION_DIR}/.leader-watcher"
mkdir -p "${STATE_DIR}"

# Idempotency: if another watcher is already running for this session, exit.
if [[ -f "${PID_FILE}" ]]; then
  _existing_pid="$(cat "${PID_FILE}" 2>/dev/null | tr -d ' \n')"
  if [[ -n "${_existing_pid}" ]] && kill -0 "${_existing_pid}" 2>/dev/null; then
    [[ -n "${ONCE}" ]] || echo "leader-watcher: already running (pid=${_existing_pid})" >&2
    exit 0
  fi
  rm -f "${PID_FILE}"
fi

if [[ -z "${ONCE}" ]]; then
  echo "$$" > "${PID_FILE}"
  trap 'rm -f "${PID_FILE}"' EXIT
fi

runner_load cmux 2>/dev/null || true

# v1.5.6: 화이트리스트 기반 자동 승인 로딩 (config/auto-approve.yaml).
# 환경변수 COMPANY_DISABLE_AUTO_APPROVE=1 로 전체 비활성화.
AUTO_APPROVE_ENABLED="0"
AUTO_APPROVE_KEYWORDS=()
AUTO_DENY_KEYWORDS=()
AUTO_APPROVE_RATE_LIMIT_MIN="${COMPANY_AUTO_APPROVE_RATE_LIMIT:-5}"
AUTO_APPROVE_MAX_PER_SESSION="${COMPANY_AUTO_APPROVE_MAX:-50}"
AUTO_APPROVE_COUNT=0

if [[ -z "${COMPANY_DISABLE_AUTO_APPROVE:-}" ]]; then
  # v1.5.6: .company-overrides/ 가 있으면 우선 — 사용자가 안전하게 정책 보강 가능.
  for cfg in \
    "${PROJECT_ROOT}/.company-overrides/config/auto-approve.yaml" \
    "${PROJECT_ROOT}/.company-kit/config/auto-approve.yaml" \
    "${PROJECT_ROOT}/config/auto-approve.yaml" \
    "${SCRIPT_DIR}/../config/auto-approve.yaml"; do
    if [[ -f "${cfg}" ]]; then
      # 매우 간단한 yaml 파싱 — enabled, auto_approve_keywords, deny_keywords 만.
      # python3 가 있으면 확실히 처리, 없으면 awk fallback.
      if command -v python3 >/dev/null 2>&1; then
        eval "$(python3 - "${cfg}" <<'PYEOF'
import sys
try:
    import yaml
    cfg = yaml.safe_load(open(sys.argv[1])) or {}
except ImportError:
    # PyYAML 미설치 — 매우 간이 수동 파싱 (들여쓰기 의존)
    import re
    cfg = {"enabled": False, "auto_approve_keywords": [], "deny_keywords": []}
    section = None
    with open(sys.argv[1]) as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("enabled:"):
                cfg["enabled"] = "true" in line.lower()
            elif line.startswith("auto_approve_keywords:"):
                section = "auto_approve_keywords"
            elif line.startswith("deny_keywords:"):
                section = "deny_keywords"
            elif line.startswith("limits:") or (line and not line.startswith(" ") and ":" in line):
                section = None
            elif section and line.strip().startswith("- "):
                m = re.match(r'\s*- "(.*)"', line) or re.match(r"\s*- '(.*)'", line)
                if m:
                    cfg[section].append(m.group(1))
print(f"AUTO_APPROVE_ENABLED={'1' if cfg.get('enabled') else '0'}")
kws = cfg.get("auto_approve_keywords") or []
dws = cfg.get("deny_keywords") or []
print("AUTO_APPROVE_KEYWORDS=(" + " ".join(repr(k) for k in kws) + ")")
print("AUTO_DENY_KEYWORDS=(" + " ".join(repr(k) for k in dws) + ")")
PYEOF
)" 2>/dev/null || true
      fi
      break
    fi
  done
fi

_keyword_match() {
  local text="$1"; shift
  local kw
  for kw in "$@"; do
    if [[ "${text}" == *"${kw}"* ]]; then
      return 0
    fi
  done
  return 1
}

_emit() {
  local event="$1"; shift
  bash "${SCRIPT_DIR}/company-emit.sh" "${event}" "${SESSION_ID}" "${PROJECT_ROOT}" "$@" >/dev/null 2>&1 || true

  # Registry canonical 매핑 (timing-based ADR v0.2 D2-C).
  # legacy 흐름은 위에서 끝남. SSOT 매핑은 best-effort. worker_id 는
  # REGISTRY_WORKER_ID 환경변수로 호출 site 가 export (없으면 silent skip).
  if [[ -z "${REGISTRY_WORKER_ID:-}" ]]; then
    return 0
  fi
  if [[ ! -f "${SCRIPT_DIR}/worker-registry-lib.sh" ]]; then
    return 0
  fi
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/worker-registry-lib.sh" 2>/dev/null || return 0
  declare -f registry_append_event >/dev/null 2>&1 || return 0

  local _reg_event="" _reg_payload="{}"
  case "${event}" in
    permission_gate_auto_approved)
      _reg_event="permission_resolved"
      _reg_payload="$(jq -S -c -n '{resolution:"allowed", actor:"auto"}')"
      ;;
    permission_gate_pending)
      _reg_event="permission_prompt"
      _reg_payload="$(jq -S -c -n '{prompt_type:"cmux_gate"}')"
      ;;
    *) return 0 ;;
  esac
  registry_append_event "${PROJECT_ROOT}" "${_reg_event}" "${REGISTRY_WORKER_ID}" cmux "${_reg_payload}" \
    >/dev/null 2>&1 || true
}

_emit_wake() {
  local source_type="$1" source_id="$2" artifact="$3" worker="$4"
  local key
  key="$(printf '%s|%s|%s|%s' "${source_type}" "${source_id}" "${artifact}" "${worker}" | shasum 2>/dev/null | awk '{print $1}')"
  [[ -n "${key}" ]] || key="${source_type}-${source_id}-${artifact}"
  local seen="${STATE_DIR}/wake-${key}.seen"
  if [[ -f "${seen}" ]]; then
    return 0
  fi
  : > "${seen}"
  _emit "leader_wake_ready" \
    "source_type=${source_type}" \
    "source_id=${source_id}" \
    "artifact=${artifact}" \
    "worker=${worker}" \
    "idempotency_key=${key}"
  # Terminal bell + stderr notice — leader pane이 보고 있으면 즉시 인지.
  printf '\a' >&2 || true
  echo "[leader-wake] worker=${worker} artifact=${artifact} (source=${source_type})" >&2
}

_check_worker() {
  local worker_dir="$1"
  local worker
  worker="$(basename "${worker_dir}")"
  # ADR v0.2 D2-C: registry 매핑용 worker_id 환경변수. _emit 함수가 참조.
  export REGISTRY_WORKER_ID="wkr-${SESSION_ID}-${worker}"

  # 1) compact-plan.md 도착
  if [[ -s "${worker_dir}/compact-plan.md" ]]; then
    _emit_wake "compact_plan" "${worker}" "compact-plan.md" "${worker}"
  fi

  # 2) compact-result.md 도착 (template-example 제외)
  if [[ -s "${worker_dir}/compact-result.md" ]] \
    && ! grep -qE 'status:[[:space:]]*"?template-example"?' "${worker_dir}/compact-result.md" 2>/dev/null; then
    _emit_wake "compact_result" "${worker}" "compact-result.md" "${worker}"
  fi

  # 3) 권한 게이트 — cmux pane capture 후 패턴 매치
  if declare -f runner_cmux_capture_worker_pane >/dev/null 2>&1; then
    local capture
    capture="$(runner_cmux_capture_worker_pane "${SESSION_ID}" "${worker}" "${PROJECT_ROOT}" 2>/dev/null || true)"
    if [[ -n "${capture}" ]]; then
      if printf '%s' "${capture}" | grep -qE 'Do you want to (proceed|make this edit)|^[[:space:]]*1\.[[:space:]]*Yes' 2>/dev/null; then
        # 게이트 텍스트 일부 추출 (자동 승인 판정용 — 더 넓게 캡쳐)
        local gate_line gate_excerpt
        gate_line="$(printf '%s' "${capture}" | grep -m1 -E 'Do you want to|1\. Yes' | head -c 200 | tr '\n' ' ')"
        # 게이트 직전 5줄까지 합쳐 도구 이름/명령 키워드 매칭 정확도 ↑
        gate_excerpt="$(printf '%s' "${capture}" | tail -20 | tr '\n' ' ' | head -c 800)"
        local gate_key="permission|${worker}|${gate_line}"
        local gate_seen="${STATE_DIR}/gate-$(printf '%s' "${gate_key}" | shasum 2>/dev/null | awk '{print $1}').seen"

        # v1.5.6: 화이트리스트 자동 승인. deny 매치 우선 → approve 매치 → 그 외는 leader-wake.
        local auto_handled="0"
        if [[ "${AUTO_APPROVE_ENABLED}" == "1" ]] \
          && (( AUTO_APPROVE_COUNT < AUTO_APPROVE_MAX_PER_SESSION )) \
          && [[ ! -f "${gate_seen}" ]]; then
          if _keyword_match "${gate_excerpt}" "${AUTO_DENY_KEYWORDS[@]+"${AUTO_DENY_KEYWORDS[@]}"}"; then
            : # deny 매치 — 자동 승인 안 함 (사용자에게)
          elif _keyword_match "${gate_excerpt}" "${AUTO_APPROVE_KEYWORDS[@]+"${AUTO_APPROVE_KEYWORDS[@]}"}"; then
            # 자동 승인: "1" + Enter 전송
            if declare -f runner_cmux_send_worker_message >/dev/null 2>&1; then
              if runner_cmux_send_worker_message "${SESSION_ID}" "${worker}" "${PROJECT_ROOT}" "1" >/dev/null 2>&1; then
                AUTO_APPROVE_COUNT=$((AUTO_APPROVE_COUNT + 1))
                : > "${gate_seen}"
                _emit "permission_gate_auto_approved" \
                  "worker=${worker}" \
                  "session_id=${SESSION_ID}" \
                  "gate_excerpt=${gate_line}" \
                  "auto_approve_count=${AUTO_APPROVE_COUNT}"
                echo "[auto-approve] worker=${worker} 안전 read-only 행동 자동 승인 (#${AUTO_APPROVE_COUNT})" >&2
                auto_handled="1"
              fi
            fi
          fi
        fi

        if [[ "${auto_handled}" == "0" ]] && [[ ! -f "${gate_seen}" ]]; then
          : > "${gate_seen}"
          _emit "permission_gate_pending" \
            "worker=${worker}" \
            "session_id=${SESSION_ID}" \
            "gate_excerpt=${gate_line}"
          printf '\a' >&2 || true
          echo "[permission-gate] worker=${worker} — 워커 pane 에서 승인 대기 중. cmux GUI 에서 직접 응답하세요." >&2
        fi
      fi
    fi
  fi
}

_scan_once() {
  local workers_root="${SESSION_DIR}/workers"
  [[ -d "${workers_root}" ]] || return 0
  local d
  for d in "${workers_root}"/*/; do
    [[ -d "${d}" ]] || continue
    _check_worker "${d%/}" || true
  done
}

_session_closed() {
  local events="${PROJECT_ROOT}/.company-runtime/harness/events.jsonl"
  [[ -f "${events}" ]] || return 1
  grep -F "\"event\":\"session_closed\"" "${events}" 2>/dev/null \
    | grep -F "\"session_id\":\"${SESSION_ID}\"" >/dev/null 2>&1
}

if [[ -n "${ONCE}" ]]; then
  _scan_once
  exit 0
fi

# Daemon loop
while true; do
  _scan_once || true
  if _session_closed; then
    break
  fi
  sleep "${INTERVAL}"
done
