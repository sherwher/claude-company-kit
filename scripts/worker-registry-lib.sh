#!/usr/bin/env bash
# scripts/worker-registry-lib.sh
#
# Worker Registry — harness 자기 설명 SSOT (Phase 1 골격).
#
# 결정문:
#   - docs/decisions/2026-05-12-worker-registry-ssot.md v0.3 (Phase 0 accepted)
#   - docs/decisions/2026-05-12-worker-registry-phase1.md v0.3 (Phase 1 accepted)
#
# 책임:
#   - 워커 인스턴스 상태 SSOT (legacy events.jsonl 와 별도 파일로 공존).
#   - 저장 위치: ${project_root}/.company-runtime/harness/workers.{jsonl,idx.json,lock/}
#   - event log = truth (append-only), idx = derived cache.
#
# 비책임:
#   - 비문서 경로 (~/.claude/session-env/, sessions/, projects/, .claude/worktrees/agent-*/) 미접근 (G-Reg-1).
#   - legacy events.jsonl 형식/위치 미변경 (G-Reg-2).
#   - registry watcher (compact-plan/result 합성 event 발행) 는 Phase 2 범위.
#
# 의존성:
#   - jq (hard dependency, G-Reg-3). 부재 시 hard fail.
#   - bash 3.2 / macOS 표준 도구만 (flock, lockfile, GNU timeout, coreutils 등 의존 금지).

set -euo pipefail

# 이중 source 방지
if [[ "${_COMPANY_WORKER_REGISTRY_LIB_LOADED:-0}" == "1" ]]; then
  return 0 2>/dev/null || true
fi
_COMPANY_WORKER_REGISTRY_LIB_LOADED=1

# 환경변수 override (smoke/테스트 용)
: "${STALE_LOCK_SEC:=300}"  # mkdir lockdir stale recovery 임계치 (초). 기본 5분.
: "${REGISTRY_LOCK_MAX_RETRIES:=30}"  # mkdir 락 획득 최대 시도
: "${REGISTRY_SCHEMA_VERSION:=2}"  # Phase 0 schema bump v1→v2 (worker_archived event + archived state)

# ─────────────────────────────────────────────────────────────────────────────
# Internal helpers
# ─────────────────────────────────────────────────────────────────────────────

# _registry_paths <project_root>
#   stdout: RUNTIME_DIR<TAB>EVENTS_FILE<TAB>IDX_FILE<TAB>LOCK_DIR
_registry_paths() {
  local pr="$1"
  local runtime="${pr}/.company-runtime/harness"
  printf '%s\t%s\t%s\t%s\n' \
    "${runtime}" \
    "${runtime}/workers.jsonl" \
    "${runtime}/workers.idx.json" \
    "${runtime}/workers.lock"
}

# _registry_require_jq
#   G-Reg-3. jq 부재 시 hard fail (registry 는 SSOT 이므로 silent skip 금지).
_registry_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "worker-registry: jq is required (hard dependency, G-Reg-3)." >&2
    echo "  install: brew install jq  /  apt install jq  /  yum install jq" >&2
    return 1
  fi
}

# _registry_now
#   ISO8601 UTC 시각.
_registry_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# _registry_lock_mtime_epoch <lock_dir>
#   stdout: 락 디렉터리의 mtime epoch. 부재 시 0.
#   macOS stat -f / Linux stat -c 양쪽 호환.
_registry_lock_mtime_epoch() {
  local lock="$1"
  if [[ ! -d "${lock}" ]]; then
    echo 0
    return 0
  fi
  if stat -f %m "${lock}" 2>/dev/null; then
    return 0
  fi
  stat -c %Y "${lock}" 2>/dev/null || echo 0
}

# _registry_acquire_lock <lock_dir>
#   mkdir lockdir 패턴 (company-emit.sh:14 와 동일). stale recovery 포함.
#   return 0 on success, 1 on failure after retries.
_registry_acquire_lock() {
  local lock="$1"
  local attempt=0
  local now mtime age
  while (( attempt < REGISTRY_LOCK_MAX_RETRIES )); do
    if mkdir "${lock}" 2>/dev/null; then
      return 0
    fi
    # stale recovery
    now="$(date +%s)"
    mtime="$(_registry_lock_mtime_epoch "${lock}")"
    age=$(( now - mtime ))
    if (( age > STALE_LOCK_SEC )); then
      echo "worker-registry: stale lock recovered (age=${age}s > STALE_LOCK_SEC=${STALE_LOCK_SEC})" >&2
      rmdir "${lock}" 2>/dev/null || true
      continue
    fi
    # backoff 20~50ms
    local jitter=$(( (RANDOM % 30) + 20 ))
    sleep "0.0${jitter}" 2>/dev/null || sleep 1
    attempt=$(( attempt + 1 ))
  done
  echo "worker-registry: failed to acquire lock after ${REGISTRY_LOCK_MAX_RETRIES} attempts" >&2
  return 1
}

# _registry_release_lock <lock_dir>
_registry_release_lock() {
  rmdir "$1" 2>/dev/null || true
}

# _registry_normalize_payload <payload_json>
#   stdout: jq -S -c 로 정규화된 payload (key sort + compact).
#   volatile field (ts, last_seen_at) 은 호출자가 payload 에 포함시키지 않는 운영 약속.
_registry_normalize_payload() {
  jq -S -c '.' <<<"$1"
}

# _registry_find_existing_event <events_file> <worker_id> <event_type>
#   stdout: 같은 (worker_id, event_type) 의 가장 최근 event 라인 1개 (없으면 빈 출력).
_registry_find_existing_event() {
  local events="$1"
  local wid="$2"
  local etype="$3"
  [[ -s "${events}" ]] || return 0
  jq -c --arg wid "${wid}" --arg et "${etype}" \
    'select(.worker_id == $wid and .event_type == $et)' \
    "${events}" 2>/dev/null | tail -n1
}

# ─────────────────────────────────────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────────────────────────────────────

# registry_init <project_root>
#   디렉터리 + 빈 파일 보장. idempotent.
registry_init() {
  local pr="$1"
  local paths runtime events idx lock
  paths="$(_registry_paths "${pr}")"
  runtime="$(echo "${paths}" | cut -f1)"
  events="$(echo "${paths}" | cut -f2)"
  idx="$(echo "${paths}" | cut -f3)"
  mkdir -p "${runtime}"
  [[ -f "${events}" ]] || : > "${events}"
  [[ -f "${idx}" ]] || echo '{"schema_version":'"${REGISTRY_SCHEMA_VERSION}"',"workers":{}}' > "${idx}"
}

# _registry_is_repeatable_event <event_type>
#   ADR 2026-05-13-registry-repeatable-events D2 v0.1 화이트리스트.
#   return 0: repeatable (distinct payload multi-emit 의도됨)
#   return 1: non-repeatable (P1-12 정책 — distinct payload 는 hard fail)
_registry_is_repeatable_event() {
  local etype="$1"
  case "${etype}" in
    stop_requested) return 0 ;;
    *) return 1 ;;
  esac
}

# _registry_append_line_locked <events_file> <event_type> <worker_id> <runner> <normalized_payload>
#   호출자 (registry_append_event) 가 lock 보유 상태에서 호출. 본 helper 는 lock 인지 0.
#   ADR 2026-05-13-registry-repeatable-events D3-A invariants:
#     - errexit 면제는 호출자 conditional context (`if ! ...; then`) 가 책임.
#     - jq / append 실패 경로 명시 return 1.
#   smoke 전용 fault injection: _REGISTRY_TEST_FAIL_APPEND=1 → 즉시 return 1 (운영 경로 미문서화).
_registry_append_line_locked() {
  local events="$1" etype="$2" wid="$3" runner="$4" normalized="$5"
  [[ "${_REGISTRY_TEST_FAIL_APPEND:-0}" == "1" ]] && return 1
  local ts line
  ts="$(_registry_now)"
  if ! line="$(jq -c -n \
    --arg ts "${ts}" \
    --argjson sv "${REGISTRY_SCHEMA_VERSION}" \
    --arg etype "${etype}" \
    --arg wid "${wid}" \
    --arg runner "${runner}" \
    --argjson payload "${normalized}" \
    '{ts:$ts, schema_version:$sv, event_type:$etype, worker_id:$wid, runner:$runner, payload:$payload}')"; then
    return 1
  fi
  printf '%s\n' "${line}" >> "${events}" || return 1
  return 0
}

# registry_append_event <project_root> <event_type> <worker_id> <runner> <payload_json>
#   본 함수가 Phase 1 P1-12 의 authoritative duplicate guard 를 담당.
#   분기 (lock 내부 재검증):
#     - repeatable event (D2 화이트리스트):
#         * same payload  → idempotent ignore (P1-B 정신 보존)
#         * distinct payload → 정상 append (hard fail 안 함 — repeatable 의 본질)
#     - non-repeatable event (P1-12 정책 그대로):
#         * same payload  → idempotent ignore
#         * distinct payload → hard fail
#         * no prior       → 정상 append
registry_append_event() {
  local pr="$1"
  local etype="$2"
  local wid="$3"
  local runner="$4"
  local payload="$5"

  _registry_require_jq || return 1

  # payload 유효성 검증 (jq -e .)
  local normalized
  if ! normalized="$(_registry_normalize_payload "${payload}" 2>/dev/null)"; then
    echo "worker-registry: invalid payload (jq -e . failed): ${payload}" >&2
    return 1
  fi

  local paths events idx lock
  paths="$(_registry_paths "${pr}")"
  events="$(echo "${paths}" | cut -f2)"
  idx="$(echo "${paths}" | cut -f3)"
  lock="$(echo "${paths}" | cut -f4)"

  registry_init "${pr}"

  _registry_acquire_lock "${lock}" || return 1

  # ── lock 내부 authoritative duplicate 재검증 (P1-12 핵심) ──
  local existing existing_payload
  existing="$(_registry_find_existing_event "${events}" "${wid}" "${etype}")"

  # ── repeatable 분기 (ADR repeatable-events D3) ──
  if _registry_is_repeatable_event "${etype}"; then
    if [[ -n "${existing}" ]]; then
      existing_payload="$(jq -S -c '.payload' <<<"${existing}")"
      if [[ "${existing_payload}" == "${normalized}" ]]; then
        # 정확 일치 retry — repeatable 이라도 idempotent ignore (P1-B)
        _registry_release_lock "${lock}"
        echo "worker-registry: idempotent ignore (repeatable, worker_id=${wid}, event_type=${etype})" >&2
        return 0
      fi
      # distinct payload — fall through 하여 정상 append (hard fail 안 함)
    fi
    if ! _registry_append_line_locked "${events}" "${etype}" "${wid}" "${runner}" "${normalized}"; then
      _registry_release_lock "${lock}"
      return 1
    fi
    _registry_release_lock "${lock}"
    registry_rebuild_index "${pr}" >/dev/null || true
    return 0
  fi
  # ─────────────────────────────────────────────────────────

  # ── 비 repeatable event — Phase 1 P1-12 정책 ──
  if [[ -n "${existing}" ]]; then
    existing_payload="$(jq -S -c '.payload' <<<"${existing}")"
    if [[ "${existing_payload}" == "${normalized}" ]]; then
      _registry_release_lock "${lock}"
      echo "worker-registry: idempotent ignore (worker_id=${wid}, event_type=${etype})" >&2
      return 0
    else
      _registry_release_lock "${lock}"
      echo "worker-registry: conflicting payload for (worker_id=${wid}, event_type=${etype})" >&2
      echo "  existing: ${existing_payload}" >&2
      echo "  incoming: ${normalized}" >&2
      return 1
    fi
  fi

  if ! _registry_append_line_locked "${events}" "${etype}" "${wid}" "${runner}" "${normalized}"; then
    _registry_release_lock "${lock}"
    return 1
  fi

  _registry_release_lock "${lock}"

  # idx 갱신은 atomic write (락 없이)
  registry_rebuild_index "${pr}" >/dev/null || true
  return 0
}

# registry_replay <project_root>
#   stdout: workers.jsonl 처음부터 읽어 D3-C transition guard 적용 후 snapshot JSON 출력.
#   transition guard:
#     1. 비합리적 전이 (completed → running 등) → warn + ignore
#     2. terminal 상태 ({completed,failed,stopped,orphaned}) 이후 active 전이 → warn + ignore
#     3. terminal 이후 approval_token_* 은 정상 처리 (post-mortem 토큰 회수)
registry_replay() {
  local pr="$1"
  local paths events
  paths="$(_registry_paths "${pr}")"
  events="$(echo "${paths}" | cut -f2)"
  _registry_require_jq || return 1
  [[ -s "${events}" ]] || {
    echo '{"schema_version":'"${REGISTRY_SCHEMA_VERSION}"',"workers":{}}'
    return 0
  }
  # Phase 2 (2026-05-13): D3-C transition guard + plan_emitted/result_emitted/crash_detected 3종 추가.
  # 결정문: docs/decisions/2026-05-12-worker-registry-phase2.md v0.5 D2-D
  # Timing-based (2026-05-13): stall_detected/permission_prompt/permission_resolved 3종 추가.
  # 결정문: docs/decisions/2026-05-13-timing-based-synthetic-events.md v0.2 D3
  # transition guard:
  #   1. 비합리적 전이 (예: completed → running): event 기록되지만 snapshot 무시 + stderr 경고
  #   2. terminal 이후 active 전이 ({completed,failed,stopped,orphaned} → active): warn + ignore
  #   3. terminal 이후 approval_token_*: 정상 처리 (post-mortem) — Phase 4 에서 활성
  # D3-A (implicit stall clear): active event 도착 시 prior state == stalled 면 state_reason 에 흔적 + 정상 transition.
  jq -s --argjson sv "${REGISTRY_SCHEMA_VERSION}" '
    def is_terminal(s): s == "completed" or s == "failed" or s == "stopped" or s == "orphaned" or s == "archived";
    def is_active_event(t):
      t == "spawn_ready" or t == "plan_emitted" or t == "plan_approved"
      or t == "result_emitted" or t == "permission_resolved";

    reduce .[] as $ev ({workers:{}};
      .workers[$ev.worker_id] as $cur
      | (if ($cur != null) and ($cur.state == "stalled") and is_active_event($ev.event_type) then
           .workers[$ev.worker_id].state_reason = ("stall implicitly cleared by " + $ev.event_type + " at " + $ev.ts)
         else . end)
      | if $ev.event_type == "spawn_started" then
          if ($cur != null) and is_terminal($cur.state) then
            .
          else
            .workers[$ev.worker_id] = {
              worker_id: $ev.worker_id,
              runner: $ev.runner,
              runner_handle: $ev.payload.runner_handle,
              session_id: ($ev.payload.session_id // null),
              worktree_path: $ev.payload.worktree_path,
              branch: ($ev.payload.branch // null),
              topic: $ev.payload.topic,
              worker_role: $ev.payload.worker_role,
              state: "starting",
              state_reason: null,
              started_at: $ev.ts,
              last_seen_at: $ev.ts,
              stopped_at: null,
              exit_reason: null,
              approval_tokens: [],
              schema_version: $ev.schema_version
            }
          end
        elif $ev.event_type == "spawn_ready" then
          if ($cur != null) and is_terminal($cur.state) then
            .
          else
            .workers[$ev.worker_id].state = "running"
            | .workers[$ev.worker_id].last_seen_at = $ev.ts
          end
        elif $ev.event_type == "plan_emitted" then
          if ($cur != null) and is_terminal($cur.state) then
            .
          else
            .workers[$ev.worker_id].state = "waiting_approval"
            | .workers[$ev.worker_id].state_reason = ($ev.payload.plan_path // null)
            | .workers[$ev.worker_id].last_seen_at = $ev.ts
          end
        elif $ev.event_type == "result_emitted" then
          if ($cur != null) and is_terminal($cur.state) then
            .
          else
            .workers[$ev.worker_id].state = "completed"
            | .workers[$ev.worker_id].stopped_at = $ev.ts
            | .workers[$ev.worker_id].exit_reason = "result"
            | .workers[$ev.worker_id].last_seen_at = $ev.ts
          end
        elif $ev.event_type == "crash_detected" then
          if ($cur != null) and is_terminal($cur.state) then
            .
          else
            .workers[$ev.worker_id].state = "failed"
            | .workers[$ev.worker_id].stopped_at = $ev.ts
            | .workers[$ev.worker_id].exit_reason = ("crash:" + (($ev.payload.exit_reason // "unknown") | tostring))
            | .workers[$ev.worker_id].last_seen_at = $ev.ts
          end
        elif $ev.event_type == "stall_detected" then
          # Phase 0 D3-C: terminal guard. running/waiting_* 등에서만 stalled 진입.
          if ($cur == null) or is_terminal($cur.state) then
            .
          else
            .workers[$ev.worker_id].state = "stalled"
            | .workers[$ev.worker_id].state_reason = (
                "stalled since " + (($ev.payload.last_seen_at // $ev.ts) | tostring)
                + " (threshold=" + (($ev.payload.threshold_sec // "?") | tostring) + "s)")
            | .workers[$ev.worker_id].last_seen_at = $ev.ts
          end
        elif $ev.event_type == "permission_prompt" then
          if ($cur == null) or is_terminal($cur.state) then
            .
          else
            .workers[$ev.worker_id].state = "waiting_permission"
            | .workers[$ev.worker_id].state_reason = (
                "permission prompt detected (" + (($ev.payload.prompt_type // "unknown") | tostring) + ")")
            | .workers[$ev.worker_id].last_seen_at = $ev.ts
          end
        elif $ev.event_type == "permission_resolved" then
          # Phase 0 D3-C 규칙: 직전 state == waiting_permission 인 경우만 running 복원.
          # 그 외 state (running/waiting_approval/terminal) 에서 도착 → ignore (snapshot 변경 0).
          if ($cur == null) or ($cur.state != "waiting_permission") then
            .
          else
            .workers[$ev.worker_id].state = "running"
            | .workers[$ev.worker_id].state_reason = (
                "permission resolved by " + (($ev.payload.actor // "unknown") | tostring)
                + " (" + (($ev.payload.resolution // "allowed") | tostring) + ")")
            | .workers[$ev.worker_id].last_seen_at = $ev.ts
          end
        elif $ev.event_type == "stall_cleared" then
          # Phase 0 enum 자리 유지. 발행자 운영 안 함 (D3-A 가 implicit clear 로 대체).
          # 명시 emit 도착 시: prior stalled 만 running 복원 (보수적).
          if ($cur == null) or ($cur.state != "stalled") then
            .
          else
            .workers[$ev.worker_id].state = "running"
            | .workers[$ev.worker_id].state_reason = ("stall explicitly cleared at " + $ev.ts)
            | .workers[$ev.worker_id].last_seen_at = $ev.ts
          end
        elif $ev.event_type == "stop_requested" then
          # Phase 0 D3-C line 161: state 변경 0 (stop_confirmed 가 transition).
          # Repeatable Events v0.5 화이트리스트로 distinct payload 도 audit 보존.
          .
        elif $ev.event_type == "stop_confirmed" then
          # Phase 4 D2: state=stopped, exit_reason=payload.reason or "user".
          if ($cur != null) and is_terminal($cur.state) then
            .
          else
            .workers[$ev.worker_id].state = "stopped"
            | .workers[$ev.worker_id].stopped_at = $ev.ts
            | .workers[$ev.worker_id].exit_reason = (($ev.payload.reason // "user") | tostring)
            | .workers[$ev.worker_id].last_seen_at = $ev.ts
          end
        elif $ev.event_type == "orphan_detected" then
          # Phase 4 D4-A derive 규칙: 직전 stop_confirmed.exit_reason 이 "force:" prefix 면
          # state_reason 을 "force_stop_assumed_leak: ..." 로 합성. 그 외는 "runner not-found".
          # Phase 0 D3-C line 164 — stopped → orphaned 도 정상 transition.
          .workers[$ev.worker_id].state = "orphaned"
          | (if ($cur != null) and (($cur.exit_reason // "") | tostring | startswith("force:")) then
              .workers[$ev.worker_id].state_reason = ("force_stop_assumed_leak: " + (($cur.exit_reason | tostring | sub("^force:"; ""))))
            else
              .workers[$ev.worker_id].state_reason = "runner not-found"
            end)
          | .workers[$ev.worker_id].last_seen_at = $ev.ts
        elif $ev.event_type == "worker_archived" then
          # Phase 5 cleanup 명령 → archived 영구 terminal.
          # ADR docs/decisions/2026-05-14-phase0-schema-v2-archived.md D2.
          # invariant: worker_archived event 가 state=archived 의 유일한 진입점.
          # terminal-to-archived 전이 (stopped/orphaned 에서 진입) 정상 처리.
          .workers[$ev.worker_id].state = "archived"
          | .workers[$ev.worker_id].state_reason = ("archived: " + (($ev.payload.scenario // "unknown") | tostring))
          | .workers[$ev.worker_id].stopped_at = ($cur.stopped_at // $ev.ts)
          | .workers[$ev.worker_id].exit_reason = ($cur.exit_reason // (($ev.payload.reason // "user") | tostring))
          | .workers[$ev.worker_id].last_seen_at = $ev.ts
        elif $ev.event_type == "approval_token_issued" then
          # Phase 0 D6 line 119: approval_tokens 에 issued 토큰 추가.
          if ($cur == null) then
            .
          else
            .workers[$ev.worker_id].approval_tokens = (
              ($cur.approval_tokens // [])
              + [{
                  scope: ($ev.payload.scope // ""),
                  actor: ($ev.payload.actor // "user"),
                  status: "issued",
                  issued_at: $ev.ts
                }]
            )
            | .workers[$ev.worker_id].last_seen_at = $ev.ts
          end
        elif $ev.event_type == "approval_token_consumed" then
          # Phase 0 D6: 매칭 scope 의 issued 토큰 → consumed.
          if ($cur == null) then
            .
          else
            .workers[$ev.worker_id].approval_tokens = (
              ($cur.approval_tokens // [])
              | map(if .scope == ($ev.payload.scope // "") and .status == "issued"
                    then . + {status: "consumed", consumed_at: $ev.ts}
                    else . end)
            )
            | .workers[$ev.worker_id].last_seen_at = $ev.ts
          end
        elif $ev.event_type == "approval_token_revoked" then
          # Phase 0 D3-C line 165-167: terminal 이후도 정상 처리 (post-mortem).
          # state 변경 0, approval_tokens 의 매칭 scope 토큰을 revoked 로 표시.
          if ($cur == null) then
            .
          else
            .workers[$ev.worker_id].approval_tokens = (
              ($cur.approval_tokens // [])
              | map(if .scope == ($ev.payload.scope // "") and .status == "issued"
                    then . + {status: "revoked", revoked_at: $ev.ts}
                    else . end)
            )
            | .workers[$ev.worker_id].last_seen_at = $ev.ts
          end
        else
          .
        end
    )
    | {schema_version: $sv, workers: .workers}
  ' "${events}"
}

# _registry_replay_state_for_worker <events_path> <worker_id>
#   Phase 4 D6-A 보조 helper. registry_replay 의 worker-단위 축약 (option b).
#   stdout: latest state ("starting"/"running"/"waiting_approval"/"waiting_permission"/
#           "stalled"/"completed"/"failed"/"stopped"/"orphaned"/"missing")
#   events.jsonl 부재/empty 시 "missing".
_registry_replay_state_for_worker() {
  local events="$1" wid="$2"
  [[ -s "${events}" ]] || { echo "missing"; return 0; }
  # registry_replay 의 reducer 결과를 그대로 사용 — drift 0 보장 (option b).
  jq -r -s --arg wid "${wid}" --argjson sv "${REGISTRY_SCHEMA_VERSION}" '
    def is_terminal(s): s == "completed" or s == "failed" or s == "stopped" or s == "orphaned" or s == "archived";
    def is_active_event(t):
      t == "spawn_ready" or t == "plan_emitted" or t == "plan_approved"
      or t == "result_emitted" or t == "permission_resolved";
    map(select(.worker_id == $wid))
    | reduce .[] as $ev ({workers:{}};
        .workers[$ev.worker_id] as $cur
        | (if ($cur != null) and ($cur.state == "stalled") and is_active_event($ev.event_type) then . else . end)
        | if $ev.event_type == "spawn_started" then
            if ($cur != null) and is_terminal($cur.state) then . else
              .workers[$ev.worker_id] = {state:"starting", exit_reason:null}
            end
          elif $ev.event_type == "spawn_ready" then
            if ($cur != null) and is_terminal($cur.state) then . else
              .workers[$ev.worker_id].state = "running"
            end
          elif $ev.event_type == "plan_emitted" then
            if ($cur != null) and is_terminal($cur.state) then . else
              .workers[$ev.worker_id].state = "waiting_approval"
            end
          elif $ev.event_type == "result_emitted" then
            if ($cur != null) and is_terminal($cur.state) then . else
              .workers[$ev.worker_id].state = "completed"
              | .workers[$ev.worker_id].exit_reason = "result"
            end
          elif $ev.event_type == "crash_detected" then
            if ($cur != null) and is_terminal($cur.state) then . else
              .workers[$ev.worker_id].state = "failed"
            end
          elif $ev.event_type == "stall_detected" then
            if ($cur == null) or is_terminal($cur.state) then . else
              .workers[$ev.worker_id].state = "stalled"
            end
          elif $ev.event_type == "permission_prompt" then
            if ($cur == null) or is_terminal($cur.state) then . else
              .workers[$ev.worker_id].state = "waiting_permission"
            end
          elif $ev.event_type == "permission_resolved" then
            if ($cur == null) or ($cur.state != "waiting_permission") then . else
              .workers[$ev.worker_id].state = "running"
            end
          elif $ev.event_type == "stall_cleared" then
            if ($cur == null) or ($cur.state != "stalled") then . else
              .workers[$ev.worker_id].state = "running"
            end
          elif $ev.event_type == "stop_requested" then .
          elif $ev.event_type == "stop_confirmed" then
            if ($cur != null) and is_terminal($cur.state) then . else
              .workers[$ev.worker_id].state = "stopped"
              | .workers[$ev.worker_id].exit_reason = (($ev.payload.reason // "user") | tostring)
            end
          elif $ev.event_type == "orphan_detected" then
            .workers[$ev.worker_id].state = "orphaned"
          elif $ev.event_type == "worker_archived" then
            .workers[$ev.worker_id].state = "archived"
          elif ($ev.event_type | startswith("approval_token_")) then .
          else . end
      )
    | (.workers[$wid].state // "missing")
  ' "${events}" 2>/dev/null
}

# registry_append_event_with_terminal_check <project_root> <event_type> <worker_id> <runner> <payload> <terminal_csv>
#   Phase 4 D6-A 5계약 atomic helper.
#   ADR docs/decisions/2026-05-13-worker-registry-phase4.md D6-A.
#   계약:
#     (a) lock 단일 획득 (중첩 금지)
#     (b) lock 안에서 _registry_replay_state_for_worker 로 latest state 판단
#     (c) terminal 이면 append 0건 + return 0 + stderr warn
#     (d) non-terminal 이면 _registry_append_line_locked 로 같은 lock 안에서 append
#     (e) lock release 후 rebuild trigger (best-effort)
#   리턴: 0 = 정상 append 또는 terminal no-op, 1 = lock 실패 / append 실패
registry_append_event_with_terminal_check() {
  local pr="$1" etype="$2" wid="$3" runner="$4" payload="$5" terminal_csv="$6"

  _registry_require_jq || return 1

  local normalized
  if ! normalized="$(_registry_normalize_payload "${payload}" 2>/dev/null)"; then
    echo "worker-registry: invalid payload (jq -e . failed): ${payload}" >&2
    return 1
  fi

  local paths events lock
  paths="$(_registry_paths "${pr}")"
  events="$(echo "${paths}" | cut -f2)"
  lock="$(echo "${paths}" | cut -f4)"

  registry_init "${pr}"

  _registry_acquire_lock "${lock}" || return 1

  local current_state
  current_state="$(_registry_replay_state_for_worker "${events}" "${wid}")"

  case ",${terminal_csv}," in
    *",${current_state},"*)
      _registry_release_lock "${lock}"
      echo "worker-registry: terminal guard: already ${current_state} (worker_id=${wid}, event_type=${etype})" >&2
      return 0
      ;;
  esac

  if ! _registry_append_line_locked "${events}" "${etype}" "${wid}" "${runner}" "${normalized}"; then
    _registry_release_lock "${lock}"
    return 1
  fi

  _registry_release_lock "${lock}"
  registry_rebuild_index "${pr}" >/dev/null || true
  return 0
}

# registry_worker_exists <project_root> <worker_id>
#   Phase 2 D1-B/D1-D 의 authoritative 판정용 (P1-12 lock 안에서 실행, P1-14 exit code 3종).
#   exit: 0 = exists, 1 = not exists, 2 = lock 획득 실패.
#   stdout 없음 (exists check only — P2 v0.5 계약).
registry_worker_exists() {
  local pr="$1" wid="$2"
  local paths events lock
  paths="$(_registry_paths "${pr}")"
  events="$(echo "${paths}" | cut -f2)"
  lock="$(echo "${paths}" | cut -f4)"

  registry_init "${pr}"

  # P2 v0.5: lock 획득 후 파일 체크 (좁은 race 차단)
  _registry_acquire_lock "${lock}" || return 2

  if [[ ! -s "${events}" ]]; then
    _registry_release_lock "${lock}"
    return 1
  fi

  local found=1
  if jq -e --arg wid "${wid}" \
       'select(.worker_id == $wid) | .event_type' \
       "${events}" >/dev/null 2>&1; then
    found=0
  fi

  _registry_release_lock "${lock}"
  return "${found}"
}

# registry_rebuild_index <project_root>
#   replay 결과를 idx.json 에 atomic write (tmp + rename).
registry_rebuild_index() {
  local pr="$1"
  local paths idx tmp
  paths="$(_registry_paths "${pr}")"
  idx="$(echo "${paths}" | cut -f3)"
  tmp="${idx}.tmp.$$"
  if registry_replay "${pr}" > "${tmp}"; then
    mv -f "${tmp}" "${idx}"
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

# registry_get_snapshot <project_root>
#   stdout: idx.json 내용. 부재 시 rebuild 후 출력.
registry_get_snapshot() {
  local pr="$1"
  local paths idx
  paths="$(_registry_paths "${pr}")"
  idx="$(echo "${paths}" | cut -f3)"
  if [[ ! -s "${idx}" ]]; then
    registry_rebuild_index "${pr}" >/dev/null || return 1
  fi
  cat "${idx}"
}
