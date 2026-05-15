#!/usr/bin/env bash
# scripts/worker-registry-print.sh
#
# Worker Registry Phase 3 — 출력 계층 (사용자 표면).
#
# 결정문: docs/decisions/2026-05-13-worker-registry-phase3.md v0.2
#
# 책임:
#   - registry SSOT (workers.idx.json / workers.jsonl) 을 사용자에게 보여주는 layer.
#   - 3 명령: registry_print_list / registry_print_status / registry_print_logs.
#   - 출력 형식 2종: 사람용 (table/struct) + 기계용 (--json).
#
# 비책임:
#   - registry write (read-only).
#   - watcher / runner / spawn 로직 (Phase 1/2 lib 가 담당).
#   - state 변경 (Phase 4 stop, Phase 5 doctor 가 담당).
#
# 의존성:
#   - scripts/worker-registry-lib.sh (registry_get_snapshot / registry_rebuild_index / _registry_paths).
#   - jq (Phase 0 G-Reg-3 hard dependency).
#
# 안정 표면 (Phase 4/5/6 가 의존하는 stable contract):
#   - flag 이름·출력 컬럼·--json 키 집합. 이후 변경은 cli_version bump 동반.

set -euo pipefail

# 이중 source 방지
if [[ "${_COMPANY_WORKER_REGISTRY_PRINT_LOADED:-0}" == "1" ]]; then
  return 0 2>/dev/null || true
fi
_COMPANY_WORKER_REGISTRY_PRINT_LOADED=1

# lib 가 정의한 helper 와 환경변수를 그대로 상속 (idempotent source)
PRINT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./worker-registry-lib.sh
source "${PRINT_SCRIPT_DIR}/worker-registry-lib.sh"

# PROJECT_ROOT 는 호출자 (scripts/company) 가 export. 미지정 시 cwd 추정.
: "${PROJECT_ROOT:=$(pwd)}"

# ─────────────────────────────────────────────────────────────────────────────
# Internal helpers
# ─────────────────────────────────────────────────────────────────────────────

# _registry_fail <msg> — stderr + exit 1
_registry_fail() {
  echo "company workers: $*" >&2
  return 1
}

# _registry_print_age <started_at_iso>
#   ISO8601 → human-readable diff (D2-A 규칙).
_registry_print_age() {
  local started="$1"
  [[ -z "${started}" || "${started}" == "null" ]] && { echo "-"; return 0; }
  # ISO8601 → epoch (BSD/GNU 양쪽 시도)
  local start_epoch now diff
  start_epoch="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "${started}" +%s 2>/dev/null \
                || date -u -d "${started}" +%s 2>/dev/null \
                || echo 0)"
  [[ "${start_epoch}" -le 0 ]] && { echo "?"; return 0; }
  now="$(date -u +%s)"
  diff=$(( now - start_epoch ))
  (( diff < 0 )) && diff=0

  if   (( diff < 60 ));    then echo "${diff}s"
  elif (( diff < 3600 ));  then echo "$((diff/60))m"
  elif (( diff < 86400 )); then
    local h=$((diff/3600)) m=$(( (diff%3600)/60 ))
    if (( m == 0 )); then echo "${h}h"; else echo "${h}h${m}m"; fi
  else
    local d=$((diff/86400)) h=$(( (diff%86400)/3600 ))
    if (( h == 0 )); then echo "${d}d"; else echo "${d}d${h}h"; fi
  fi
}

# _registry_resolve_since <duration> → ISO8601 UTC
#   "5m" / "2h" / "1d" → now - N → ISO8601. 잘못된 입력은 빈 출력.
_registry_resolve_since() {
  local s="$1"
  [[ -z "${s}" ]] && { echo ""; return 0; }
  local n="${s%[smhd]}"
  local u="${s: -1}"
  [[ "${n}" =~ ^[0-9]+$ ]] || { echo ""; return 0; }
  local sec
  case "${u}" in
    s) sec="${n}" ;;
    m) sec=$(( n * 60 )) ;;
    h) sec=$(( n * 3600 )) ;;
    d) sec=$(( n * 86400 )) ;;
    *) echo ""; return 0 ;;
  esac
  local now_epoch=$(($(date -u +%s) - sec))
  date -u -r "${now_epoch}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "@${now_epoch}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || echo ""
}

# _registry_truncate <text> <maxlen>
#   visual width 가 아닌 byte 기반. emoji/한국어 정렬 깨짐 가능 — 결정문 v0.2 의 알려진 한계.
_registry_truncate() {
  local t="$1" n="$2"
  [[ -z "${t}" || "${t}" == "null" ]] && { echo "-"; return 0; }
  if (( ${#t} > n )); then
    echo "${t:0:n}…"
  else
    echo "${t}"
  fi
}

# _registry_maybe_strict <project_root> <strict_flag>
_registry_maybe_strict() {
  local pr="$1" strict="$2"
  if [[ "${strict}" == "1" ]]; then
    registry_rebuild_index "${pr}" >/dev/null || {
      echo "company workers: registry rebuild failed (event log corrupt?). Use 'company workers doctor' (Phase 5) to diagnose." >&2
      return 1
    }
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# D2. company workers list
# ─────────────────────────────────────────────────────────────────────────────

registry_print_list() {
  local states_csv="" session_filter="" runners_csv=""
  local json=0 strict=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state=*)   states_csv="${1#--state=}"; shift ;;
      --state)     [[ $# -ge 2 ]] || { _registry_fail "--state requires a value"; return 1; }
                   states_csv="$2"; shift 2 ;;
      --session=*) session_filter="${1#--session=}"; shift ;;
      --session)   [[ $# -ge 2 ]] || { _registry_fail "--session requires a value"; return 1; }
                   session_filter="$2"; shift 2 ;;
      --runner=*)  runners_csv="${1#--runner=}"; shift ;;
      --runner)    [[ $# -ge 2 ]] || { _registry_fail "--runner requires a value"; return 1; }
                   runners_csv="$2"; shift 2 ;;
      --json)      json=1; shift ;;
      --strict)    strict=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: company workers list [--state=<csv>] [--session=<id>] [--runner=<csv>]
                            [--json] [--strict]

  --state=<csv>    필터: starting,running,waiting_approval,waiting_permission,
                   stalled,completed,failed,stopped,orphaned (콤마 구분)
  --session=<id>   세션 id 정확 일치
  --runner=<csv>   sequential,tmux,cmux,manual (콤마 구분)
  --json           기계용 출력 (record array)
  --strict         읽기 직전 idx.json 강제 재빌드 (운영 실시간 정확도 보장)
EOF
        return 0 ;;
      *) _registry_fail "unknown flag for 'list': $1"; return 1 ;;
    esac
  done

  _registry_maybe_strict "${PROJECT_ROOT}" "${strict}" || return 1

  local snap
  snap="$(registry_get_snapshot "${PROJECT_ROOT}")" || {
    _registry_fail "snapshot 조회 실패"; return 1
  }

  # filtered record array (object → array 변환 후 필터)
  local filtered
  filtered="$(echo "${snap}" | jq -c \
    --arg states "${states_csv}" \
    --arg session "${session_filter}" \
    --arg runners "${runners_csv}" '
      ($states  | if . == "" then null else split(",") end) as $st  |
      ($runners | if . == "" then null else split(",") end) as $rn  |
      [ .workers
        | to_entries[]
        | .value
        | select(($st == null) or (.state  | IN($st[])))
        | select(($rn == null) or (.runner | IN($rn[])))
        | select(($session == "") or (.session_id == $session))
      ]
      | sort_by(.worker_id)
    ')"

  if [[ "${json}" == "1" ]]; then
    # --json 출력: snapshot record array (필터·정렬 적용)
    echo "${filtered}" | jq .
    return 0
  fi

  local count
  count="$(echo "${filtered}" | jq 'length')"
  if [[ "${count}" -eq 0 ]]; then
    echo "No workers registered."
    return 0
  fi

  # human table — 헤더
  printf '%-32s %-10s %-19s %-15s %-42s %-8s\n' \
    "WORKER_ID" "RUNNER" "STATE" "SESSION" "TOPIC" "AGE"

  # 라인별 출력 (TSV stream 으로 변환 후 한 줄씩)
  local line wid runner state session topic started age
  while IFS=$'\t' read -r wid runner state session topic started; do
    [[ -z "${wid}" ]] && continue
    age="$(_registry_print_age "${started}")"
    topic="$(_registry_truncate "${topic}" 40)"
    [[ -z "${session}" || "${session}" == "null" ]] && session="-"
    printf '%-32s %-10s %-19s %-15s %-42s %-8s\n' \
      "${wid}" "${runner}" "${state}" "${session}" "${topic}" "${age}"
  done < <(echo "${filtered}" | jq -r '.[] | [.worker_id, .runner, .state, (.session_id // "-"), (.topic // "-"), (.started_at // "")] | @tsv')

  # summary line
  echo "${filtered}" | jq -r '
    [ .[].state ] as $sts
    | (length) as $n
    | "" as $_
    | "\($n) worker(s)"
      + (if ($sts | length) > 0
         then ", " + (
           $sts
           | group_by(.)
           | map("\(length) \(.[0])")
           | join(", "))
         else ""
         end)
    '
}

# ─────────────────────────────────────────────────────────────────────────────
# D3. company workers status <worker_id>
# ─────────────────────────────────────────────────────────────────────────────

registry_print_status() {
  local worker_id="" events_n=5 json=0 strict=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --events=*) events_n="${1#--events=}"; shift ;;
      --events)   [[ $# -ge 2 ]] || { _registry_fail "--events requires a value"; return 1; }
                  events_n="$2"; shift 2 ;;
      --json)     json=1; shift ;;
      --strict)   strict=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: company workers status <worker_id> [--events=<N>] [--json] [--strict]

  --events=<N>     최근 event 개수 (기본 5)
  --json           기계용 출력 (snapshot record + recent_events)
  --strict         읽기 직전 idx.json 재빌드
EOF
        return 0 ;;
      -*) _registry_fail "unknown flag for 'status': $1"; return 1 ;;
      *)
        if [[ -z "${worker_id}" ]]; then worker_id="$1"; shift
        else _registry_fail "status accepts exactly one <worker_id>"; return 1
        fi ;;
    esac
  done
  [[ -n "${worker_id}" ]] || { _registry_fail "status requires <worker_id>"; return 1; }
  [[ "${events_n}" =~ ^[0-9]+$ ]] || { _registry_fail "--events must be a non-negative integer"; return 1; }

  _registry_maybe_strict "${PROJECT_ROOT}" "${strict}" || return 1

  local snap record
  snap="$(registry_get_snapshot "${PROJECT_ROOT}")" || { _registry_fail "snapshot 조회 실패"; return 1; }
  record="$(echo "${snap}" | jq -c --arg w "${worker_id}" '.workers[$w] // null')"

  if [[ "${record}" == "null" ]]; then
    if [[ "${json}" == "1" ]]; then
      echo "null"
    else
      echo "worker not found: ${worker_id}" >&2
    fi
    return 1
  fi

  # recent_events: workers.jsonl 의 마지막 N 라인 (해당 worker_id 만)
  local paths events_file recent_events
  paths="$(_registry_paths "${PROJECT_ROOT}")"
  events_file="$(echo "${paths}" | cut -f2)"
  if [[ -s "${events_file}" ]]; then
    recent_events="$(jq -c --arg w "${worker_id}" 'select(.worker_id == $w)' "${events_file}" 2>/dev/null \
                     | tail -n "${events_n}" | jq -s '.')"
  else
    recent_events="[]"
  fi

  if [[ "${json}" == "1" ]]; then
    echo "${record}" | jq --argjson re "${recent_events}" '. + {recent_events: $re}'
    return 0
  fi

  # human struct
  local started last seen_age
  started="$(echo "${record}" | jq -r '.started_at // "-"')"
  last="$(echo "${record}" | jq -r '.last_seen_at // "-"')"
  seen_age="$(_registry_print_age "${last}")"

  printf 'Worker:        %s\n' "$(echo "${record}" | jq -r '.worker_id')"
  printf 'Runner:        %s\n' "$(echo "${record}" | jq -r '.runner')"
  printf 'Handle:        %s\n' "$(echo "${record}" | jq -r '.runner_handle // "-"')"
  printf 'State:         %s\n' "$(echo "${record}" | jq -r '.state')"
  printf 'Reason:        %s\n' "$(echo "${record}" | jq -r '.state_reason // "-"')"
  printf 'Session:       %s\n' "$(echo "${record}" | jq -r '.session_id // "-"')"
  printf 'Worktree:      %s\n' "$(echo "${record}" | jq -r '.worktree_path // "-"')"
  printf 'Branch:        %s\n' "$(echo "${record}" | jq -r '.branch // "-"')"
  printf 'Topic:         %s\n' "$(echo "${record}" | jq -r '.topic // "-"')"
  printf 'Role:          %s\n' "$(echo "${record}" | jq -r '.worker_role // "-"')"
  printf 'Started:       %s (%s ago)\n' "${started}" "$(_registry_print_age "${started}")"
  printf 'Last seen:     %s (%s ago)\n' "${last}" "${seen_age}"
  printf 'Stopped:       %s\n' "$(echo "${record}" | jq -r '.stopped_at // "-"')"
  printf 'Exit reason:   %s\n' "$(echo "${record}" | jq -r '.exit_reason // "-"')"

  local tok_count
  tok_count="$(echo "${record}" | jq '(.approval_tokens // []) | length')"
  if [[ "${tok_count}" -gt 0 ]]; then
    echo 'Approval tokens:'
    echo "${record}" | jq -r '
      (.approval_tokens // [])[]
      | "  - \(.scope // "?") (issued_by=\(.issued_by // "-"), issued_at=\(.issued_at // "-"))"
        + (if .consumed_at != null then " (consumed by \(.consumed_by // "?"), \(.consumed_at))" else "" end)
        + (if .revoked_at  != null then " (revoked at \(.revoked_at))" else "" end)
    '
  fi

  if [[ "${events_n}" -gt 0 ]] && [[ "$(echo "${recent_events}" | jq 'length')" -gt 0 ]]; then
    echo "Recent events (last ${events_n}):"
    echo "${recent_events}" | jq -r '.[] | "  \(.ts // "?")  \(.event_type // "?")  \(.payload | tostring)"'
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# D4. company workers logs <worker_id>
# ─────────────────────────────────────────────────────────────────────────────

registry_print_logs() {
  local worker_id="" tail_n=50 all=0 since="" events_csv="" json=0 follow=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tail=*)  tail_n="${1#--tail=}"; shift ;;
      --tail)    [[ $# -ge 2 ]] || { _registry_fail "--tail requires a value"; return 1; }
                 tail_n="$2"; shift 2 ;;
      --all)     all=1; shift ;;
      --since=*) since="${1#--since=}"; shift ;;
      --since)   [[ $# -ge 2 ]] || { _registry_fail "--since requires a value"; return 1; }
                 since="$2"; shift 2 ;;
      --event=*) events_csv="${1#--event=}"; shift ;;
      --event)   [[ $# -ge 2 ]] || { _registry_fail "--event requires a value"; return 1; }
                 events_csv="$2"; shift 2 ;;
      --json)    json=1; shift ;;
      --follow|-f) follow=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: company workers logs <worker_id> [--tail=<N>|--all] [--since=<dur>]
                                        [--event=<type-csv>] [--json] [--follow]

  --tail=<N>       최근 N 라인 (기본 50)
  --all            전체 출력 (--tail 무시)
  --since=<dur>    "5m" / "2h" / "1d" → 그 시점 이후만
  --event=<csv>    event_type 필터 (콤마 구분)
  --json           기계용 출력 (event line array, NDJSON 아님)
  --follow,-f      tail -F 동작 (rotation 시 line 누락 가능)
EOF
        return 0 ;;
      -*) _registry_fail "unknown flag for 'logs': $1"; return 1 ;;
      *)
        if [[ -z "${worker_id}" ]]; then worker_id="$1"; shift
        else _registry_fail "logs accepts exactly one <worker_id>"; return 1
        fi ;;
    esac
  done
  [[ -n "${worker_id}" ]] || { _registry_fail "logs requires <worker_id>"; return 1; }
  [[ "${tail_n}" =~ ^[0-9]+$ ]] || { _registry_fail "--tail must be a non-negative integer"; return 1; }

  local paths events_file
  paths="$(_registry_paths "${PROJECT_ROOT}")"
  events_file="$(echo "${paths}" | cut -f2)"

  if [[ ! -s "${events_file}" ]]; then
    echo "No events recorded yet." >&2
    return 0
  fi

  local since_ts=""
  if [[ -n "${since}" ]]; then
    since_ts="$(_registry_resolve_since "${since}")"
    [[ -n "${since_ts}" ]] || { _registry_fail "invalid --since=${since} (expected like 5m/2h/1d)"; return 1; }
  fi

  # jq filter 구성
  local jq_select='select(.worker_id == $w)'
  [[ -n "${since_ts}" ]] && jq_select="${jq_select} | select(.ts >= \$since)"
  if [[ -n "${events_csv}" ]]; then
    jq_select="${jq_select} | select(.event_type | IN(\$events | split(\",\")[]))"
  fi

  _registry_emit_lines() {
    local src="$1"
    if [[ "${json}" == "1" ]]; then
      # 전체를 array 로
      jq -c -s --arg w "${worker_id}" --arg since "${since_ts}" --arg events "${events_csv}" \
        "[ .[] | ${jq_select} ]" "${src}"
    else
      jq -c --arg w "${worker_id}" --arg since "${since_ts}" --arg events "${events_csv}" \
        "${jq_select}" "${src}" \
        | jq -r '"\(.ts // "?")  \(.event_type // "?")  \(.payload | tostring)"'
    fi
  }

  if [[ "${follow}" == "1" ]]; then
    # tail -F | jq stream. --tail/--all 은 follow 와 함께면 의미 모호 — 무시.
    tail -F -n 0 "${events_file}" 2>/dev/null \
      | jq -c --unbuffered --arg w "${worker_id}" --arg since "${since_ts}" --arg events "${events_csv}" \
          "${jq_select}" \
      | { if [[ "${json}" == "1" ]]; then cat
          else jq -r --unbuffered '"\(.ts // "?")  \(.event_type // "?")  \(.payload | tostring)"'
          fi; }
    return 0
  fi

  if [[ "${all}" == "1" ]]; then
    _registry_emit_lines "${events_file}"
  else
    # human path 는 tail 제한, json 은 array 안에서 잘라야 함
    if [[ "${json}" == "1" ]]; then
      jq -s --arg w "${worker_id}" --arg since "${since_ts}" --arg events "${events_csv}" --argjson n "${tail_n}" \
        "[ .[] | ${jq_select} ] | (if length > \$n then .[length - \$n:] else . end)" \
        "${events_file}"
    else
      jq -c --arg w "${worker_id}" --arg since "${since_ts}" --arg events "${events_csv}" \
        "${jq_select}" "${events_file}" \
        | tail -n "${tail_n}" \
        | jq -r '"\(.ts // "?")  \(.event_type // "?")  \(.payload | tostring)"'
    fi
  fi

  # 결과 0건 안내 (json 모드는 [] 자체가 안내)
  if [[ "${json}" == "0" ]]; then
    local total
    total="$(jq -c --arg w "${worker_id}" "${jq_select}" \
                  --arg since "${since_ts}" --arg events "${events_csv}" \
                  "${events_file}" 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${total}" -eq 0 ]]; then
      echo "no events for worker_id=${worker_id}. Use 'company workers list' to see registered workers." >&2
    fi
  fi
}
