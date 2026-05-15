#!/usr/bin/env bash
# scripts/worker-registry-stop.sh
#
# Phase 4 (2026-05-13): registry SSOT 위의 첫 mutating CLI 표면 — `company workers stop`.
#
# 결정문: docs/decisions/2026-05-13-worker-registry-phase4.md v0.5
#
# 의존: worker-registry-lib.sh, scripts/runners/*.sh
# 호출: scripts/company workers stop <worker_id> [...] (위치한 분기에서 source 후 registry_cmd_stop 호출)

set -euo pipefail

_STOP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./worker-registry-lib.sh
source "${_STOP_SCRIPT_DIR}/worker-registry-lib.sh"

_stop_fail() { echo "company workers stop: $*" >&2; exit "${2:-1}"; }
_stop_warn() { echo "company workers stop: $*" >&2; }

# _stop_emit_json <action> <worker_id> [extra_jq_args...]
#   --json 출력 표준화. 호출자가 jq 를 직접 안 쓰도록.
_stop_emit_json() {
  local action="$1" wid="$2"; shift 2
  jq -c -n --arg action "${action}" --arg wid "${wid}" "$@" \
    '{action:$action, worker_id:$wid} + $ARGS.named | del(.action_dup, .wid_dup) | . + {action:$action, worker_id:$wid}'
}

# registry_cmd_stop <args...>
#   ADR D6 entry point. scripts/company workers stop 분기에서 호출.
registry_cmd_stop() {
  local wid="" reason="user" force=0 close_surface="auto" json=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help|help)
        cat <<'EOF'
Usage: company workers stop <worker_id> [--reason=<text>] [--force]
                                        [--close-surface=auto|yes|no]
                                        [--json]

  worker_id 정확 일치 (substring 안 함). 정상 transition: running/waiting_*/
  stalled/starting → stopped. terminal 상태 (completed/failed/stopped/orphaned)
  는 warn + no-op (idempotent, exit 0). approval_token 회수 (issued → revoked).
  stop 은 비파괴 — conversation/worktree 보존. worktree gc 는 Phase 5 cleanup.

Flags:
  --reason=<text>          exit_reason 에 기록 (미지정 시 "user").
  --force                  runner.stop_worker 호출 결과 무시하고 강제 stop_confirmed.
                          stop_confirmed 직후 orphan_detected 자동 emit (process leak 가시화).
  --close-surface=<mode>   cmux 만 의미. auto(default)=cmux 만 close 시도, yes=강제,
                          no=skip. close 실패는 warn + transition 진행.
  --json                   stdout 을 JSON 출력. 사람용 메시지 stderr.

Exit codes:
  0  정상 transition / terminal no-op / --force 강제
  1  worker_id not found
  2  runner stop_worker 실패 + --force 미지정
  3  registry append/rebuild 실패
EOF
        return 0 ;;
      --reason=*)        reason="${1#--reason=}"; shift ;;
      --reason)          [[ $# -ge 2 ]] || _stop_fail "--reason requires a value"; reason="$2"; shift 2 ;;
      --force)           force=1; shift ;;
      --close-surface=*) close_surface="${1#--close-surface=}"; shift ;;
      --close-surface)   [[ $# -ge 2 ]] || _stop_fail "--close-surface requires a value"; close_surface="$2"; shift 2 ;;
      --json)            json=1; shift ;;
      --) shift; break ;;
      --*) _stop_fail "unknown flag: $1" ;;
      *)
        if [[ -z "${wid}" ]]; then wid="$1"; shift
        else _stop_fail "stop accepts exactly one <worker_id>"
        fi ;;
    esac
  done

  [[ -n "${wid}" ]] || _stop_fail "stop requires <worker_id>"
  case "${close_surface}" in auto|yes|no) ;; *) _stop_fail "--close-surface must be auto|yes|no" ;; esac

  : "${PROJECT_ROOT:?PROJECT_ROOT must be exported by scripts/company}"

  # ── 1. mutating strict rebuild (D2 P1-4) ──
  registry_rebuild_index "${PROJECT_ROOT}" >/dev/null || {
    if [[ "${json}" -eq 1 ]]; then
      jq -c -n --arg w "${wid}" '{action:"error", worker_id:$w, reason:"registry_append_failed"}'
    else
      _stop_warn "registry rebuild failed (event log corrupt?). Use 'company workers doctor' (Phase 5)."
    fi
    exit 3
  }

  local snap record current_state runner session worker
  snap="$(registry_get_snapshot "${PROJECT_ROOT}")" || _stop_fail "registry snapshot failed" 3
  record="$(echo "${snap}" | jq -c --arg w "${wid}" '.workers[$w] // null')"

  if [[ "${record}" == "null" ]]; then
    if [[ "${json}" -eq 1 ]]; then
      jq -c -n --arg w "${wid}" '{action:"error", worker_id:$w, reason:"not_found"}'
    else
      _stop_warn "worker_id not found: ${wid}"
    fi
    exit 1
  fi

  current_state="$(echo "${record}" | jq -r '.state // "missing"')"
  runner="$(echo "${record}" | jq -r '.runner // ""')"
  session="$(echo "${record}" | jq -r '.session_id // ""')"
  worker="$(echo "${record}" | jq -r '(.worktree_path // "") | split("/") | .[-1]')"

  case "${current_state}" in
    completed|failed|stopped|orphaned)
      if [[ "${json}" -eq 1 ]]; then
        jq -c -n --arg w "${wid}" --arg s "${current_state}" \
          '{action:"noop", worker_id:$w, reason:"already_terminal", state:$s, tokens_revoked:0}'
      else
        _stop_warn "worker already in terminal state: ${current_state} — no-op"
      fi
      exit 0 ;;
    missing)
      if [[ "${json}" -eq 1 ]]; then
        jq -c -n --arg w "${wid}" '{action:"error", worker_id:$w, reason:"not_found"}'
      else
        _stop_warn "worker state missing — registry corrupt?"
      fi
      exit 1 ;;
    starting|running|waiting_approval|waiting_permission|stalled) ;;
    *)
      _stop_warn "unexpected state: ${current_state} — proceeding with stop"
      ;;
  esac

  local from_state="${current_state}"

  # ── 2. stop_requested emit (Phase 0 schema {actor, reason}, Repeatable Events 화이트리스트) ──
  local sr_payload
  sr_payload="$(jq -c -n --arg actor "user" --arg reason "${reason}" '{actor:$actor, reason:$reason}')"
  if ! registry_append_event "${PROJECT_ROOT}" stop_requested "${wid}" "${runner}" "${sr_payload}" >/dev/null 2>&1; then
    if [[ "${json}" -eq 1 ]]; then
      jq -c -n --arg w "${wid}" '{action:"error", worker_id:$w, reason:"registry_append_failed"}'
    else
      _stop_warn "stop_requested emit failed"
    fi
    exit 3
  fi

  # ── 3. cmux close-surface 분기 (D4) ──
  local close_surface_failed=false
  if [[ "${runner}" == "cmux" && "${close_surface}" != "no" && -n "${session}" && -n "${worker}" ]]; then
    local target_file="${PROJECT_ROOT}/.company-runtime/sessions/${session}/workers/${worker}/cmux-target"
    if [[ -f "${target_file}" ]] && command -v cmux >/dev/null 2>&1; then
      local target
      target="$(grep -E '^(surface|panel):' "${target_file}" 2>/dev/null | head -1 || true)"
      if [[ -n "${target}" ]]; then
        if ! cmux close-surface --surface "${target#surface:}" 2>/dev/null \
          && ! cmux close-surface --surface "${target}" 2>/dev/null; then
          close_surface_failed=true
          _stop_warn "cmux close-surface failed (transition will proceed)"
        fi
      fi
    fi
  fi

  # ── 4. runner.stop_worker 호출 ──
  local runner_rc=0
  if [[ -n "${runner}" && -n "${session}" && -n "${worker}" ]]; then
    local runner_lib="${_STOP_SCRIPT_DIR}/runners/${runner}.sh"
    if [[ -f "${runner_lib}" ]]; then
      # shellcheck source=/dev/null
      source "${runner_lib}"
      if declare -F "runner_${runner}_stop_worker" >/dev/null; then
        "runner_${runner}_stop_worker" "${session}" "${worker}" "${PROJECT_ROOT}" || runner_rc=$?
      fi
    fi
  fi

  if [[ "${runner_rc}" -ne 0 && "${force}" -eq 0 ]]; then
    if [[ "${json}" -eq 1 ]]; then
      jq -c -n --arg w "${wid}" \
        '{action:"error", worker_id:$w, reason:"runner_stop_failed", stop_requested_emitted:true}'
    else
      _stop_warn "runner stop failed (rc=${runner_rc}). retry with --force to override."
    fi
    exit 2
  fi

  # ── 5. stop_confirmed (atomic helper) ──
  local exit_reason="${reason}"
  [[ "${force}" -eq 1 ]] && exit_reason="force:${reason}"
  local sc_payload
  sc_payload="$(jq -c -n --arg r "${exit_reason}" '{reason:$r}')"

  local sc_log="${PROJECT_ROOT}/.company-runtime/harness/.stop-confirmed.stderr"
  : > "${sc_log}" 2>/dev/null || true
  registry_append_event_with_terminal_check "${PROJECT_ROOT}" stop_confirmed "${wid}" "${runner}" \
    "${sc_payload}" "completed,failed,stopped,orphaned,archived" 2>"${sc_log}" || {
    if [[ "${json}" -eq 1 ]]; then
      jq -c -n --arg w "${wid}" '{action:"error", worker_id:$w, reason:"registry_append_failed"}'
    else
      _stop_warn "stop_confirmed append failed"
    fi
    exit 3
  }

  # multi-leader race: 두 번째 호출은 terminal guard 로 noop
  if grep -q "terminal guard: already" "${sc_log}" 2>/dev/null; then
    local guarded_state guard_line
    guard_line="$(grep "terminal guard: already" "${sc_log}" | head -1)"
    guarded_state="$(echo "${guard_line}" | sed -n 's/.*terminal guard: already \([a-z]*\).*/\1/p')"
    [[ -n "${guarded_state}" ]] || guarded_state="stopped"
    # lib helper 의 원본 메시지를 stderr 로 그대로 흘려보내 multi-leader race audit 보존.
    echo "${guard_line}" >&2
    rm -f "${sc_log}" 2>/dev/null || true
    if [[ "${json}" -eq 1 ]]; then
      jq -c -n --arg w "${wid}" --arg s "${guarded_state}" \
        '{action:"noop", worker_id:$w, reason:"already_terminal", state:$s, tokens_revoked:0}'
    else
      _stop_warn "worker already in terminal state: ${guarded_state} — no-op"
    fi
    exit 0
  fi
  rm -f "${sc_log}" 2>/dev/null || true

  # ── 6. (force 시) orphan_detected — D4-A, token revoke 보다 앞 ──
  local to_state="stopped"
  local forced=false orphan_emitted=false
  if [[ "${force}" -eq 1 ]]; then
    forced=true
    if registry_append_event "${PROJECT_ROOT}" orphan_detected "${wid}" "${runner}" '{}' >/dev/null 2>&1; then
      orphan_emitted=true
      to_state="orphaned"
    fi
  fi

  # ── 7. approval token revoke ──
  local tokens_revoked=0
  local issued_scopes
  issued_scopes="$(echo "${record}" | jq -r '(.approval_tokens // []) | map(select(.status == "issued") | .scope) | .[]?')"
  if [[ -n "${issued_scopes}" ]]; then
    while IFS= read -r scope; do
      [[ -n "${scope}" ]] || continue
      local revoke_payload
      revoke_payload="$(jq -c -n --arg s "${scope}" --arg a "system" --arg r "worker stopped" \
        '{scope:$s, actor:$a, reason:$r}')"
      if registry_append_event "${PROJECT_ROOT}" approval_token_revoked "${wid}" "${runner}" \
        "${revoke_payload}" >/dev/null 2>&1; then
        tokens_revoked=$(( tokens_revoked + 1 ))
      fi
    done <<< "${issued_scopes}"
  fi

  # ── 8. 출력 (D7 4분기 schema) ──
  if [[ "${json}" -eq 1 ]]; then
    if [[ "${forced}" == "true" ]]; then
      jq -c -n --arg w "${wid}" --arg from "${from_state}" --arg to "${to_state}" \
        --arg reason "${exit_reason}" --argjson tr "${tokens_revoked}" \
        --argjson oe "${orphan_emitted}" \
        '{action:"stop", worker_id:$w, from:$from, to:$to, forced:true, orphan_emitted:$oe,
          reason:$reason, tokens_revoked:$tr}'
    else
      local cs_arg='{}'
      [[ "${runner}" == "cmux" ]] && cs_arg="$(jq -c -n --argjson f "${close_surface_failed}" '{close_surface_failed:$f}')"
      jq -c -n --arg w "${wid}" --arg from "${from_state}" --arg to "${to_state}" \
        --arg reason "${exit_reason}" --argjson tr "${tokens_revoked}" \
        --argjson cs "${cs_arg}" \
        '{action:"stop", worker_id:$w, from:$from, to:$to, reason:$reason, tokens_revoked:$tr} + $cs'
    fi
  else
    local msg="worker ${wid}: ${from_state} → ${to_state}"
    [[ "${forced}" == "true" ]] && msg="${msg} (forced, orphan_emitted=${orphan_emitted})"
    [[ "${tokens_revoked}" -gt 0 ]] && msg="${msg} [tokens_revoked=${tokens_revoked}]"
    echo "${msg}" >&2
  fi

  exit 0
}
