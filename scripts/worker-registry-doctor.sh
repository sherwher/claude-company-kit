#!/usr/bin/env bash
# scripts/worker-registry-doctor.sh
#
# Phase 5 (2026-05-15): registry SSOT 위의 read-only 진단 CLI — `company workers doctor`.
#
# 결정문: docs/decisions/2026-05-14-worker-registry-phase5.md v0.4 (accepted)
#         docs/decisions/2026-05-14-phase0-schema-v2-archived.md v0.4 (accepted)
#
# D4-A integrity (idx_drift / lock_leak / schema_version / enum_unknown)
# D4-B process   (runner_<r>_check_alive — orphaned 워커 5종 runner adapter)
# D4-C worktree  (5 시나리오 — normal_stopped / dirty_change / unpushed_commits /
#                 crash_orphan / force_stop_assumed_leak)
#
# 의존: worker-registry-lib.sh, scripts/runners/*.sh
# 호출: scripts/company workers doctor [...] (위치한 분기에서 source 후 registry_cmd_doctor 호출)
#
# **read-only**: events.jsonl 추가 0건. snapshot rebuild 는 strict (D2 P1-4 정신).

set -euo pipefail

_DOCTOR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./worker-registry-lib.sh
source "${_DOCTOR_SCRIPT_DIR}/worker-registry-lib.sh"

_doctor_fail() { echo "company workers doctor: $*" >&2; exit "${2:-2}"; }
_doctor_warn() { echo "company workers doctor: $*" >&2; }

# Phase 0 v0.4 (accepted) + schema bump v0.4 (accepted) — event_type 화이트리스트.
# enum_unknown 검사 (D4-A 항목 4) 가 이 표 외 event_type 발견 시 결함 보고.
_DOCTOR_EVENT_ENUM=(
  spawn_started spawn_ready spawn_failed
  permission_resolved permission_requested approval_requested approval_granted approval_token_revoked
  plan_emitted result_emitted
  worker_registered worker_archived
  crash_detected orphan_detected
  stop_requested stop_confirmed
  stalled_detected
)

# _doctor_in_enum <event_type>
_doctor_in_enum() {
  local t="$1"
  local e
  for e in "${_DOCTOR_EVENT_ENUM[@]}"; do
    [[ "${e}" == "${t}" ]] && return 0
  done
  return 1
}

# _doctor_check_integrity <project_root> -> emits jq-encoded array on stdout
_doctor_check_integrity() {
  local pr="$1"
  local paths events idx lockdir
  IFS=$'\t' read -r _ events idx lockdir < <(_registry_paths "${pr}")

  local idx_before idx_after idx_status="PASS"
  idx_before=""
  if [[ -f "${idx}" ]]; then
    idx_before="$(stat -f '%m' "${idx}" 2>/dev/null || stat -c '%Y' "${idx}" 2>/dev/null || echo 0)"
  fi
  # 빈 registry: events.jsonl 부재 + idx 부재 → 정상 시작 상태 (워커 0건).
  # rebuild 가 빈 idx 를 만들면서 PASS. drift 검사는 idx_before 가 있었을 때만 의미.
  if registry_rebuild_index "${pr}" >/dev/null 2>&1; then
    if [[ -n "${idx_before}" ]]; then
      idx_after="$(stat -f '%m' "${idx}" 2>/dev/null || stat -c '%Y' "${idx}" 2>/dev/null || echo 0)"
      [[ "${idx_before}" == "${idx_after}" ]] || idx_status="STALE"
    fi
  else
    idx_status="FAIL"
  fi

  local lock_status="PASS" lock_age=0
  if [[ -d "${lockdir}" ]]; then
    local lock_mtime now
    lock_mtime="$(stat -f '%m' "${lockdir}" 2>/dev/null || stat -c '%Y' "${lockdir}" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    lock_age=$(( now - lock_mtime ))
    if [[ "${lock_age}" -gt 600 ]]; then lock_status="HARD_FAIL"
    elif [[ "${lock_age}" -gt 60 ]]; then lock_status="STALE"
    fi
  fi

  local schema_status="PASS" schema_versions="[]"
  if [[ -f "${events}" ]]; then
    schema_versions="$(jq -s -c '[.[].schema_version] | group_by(.) | map({version: .[0], count: length})' "${events}" 2>/dev/null || echo '[]')"
    local distinct
    distinct="$(echo "${schema_versions}" | jq -r 'length')"
    [[ "${distinct}" -le 1 ]] || schema_status="MIXED"  # OQ-NEW-2: 혼합은 정상 보고만 (현 권고)
  fi

  local enum_status="PASS" unknown_count=0 unknown_types="[]"
  if [[ -f "${events}" ]]; then
    local types
    types="$(jq -r 'select(.event_type) | .event_type' "${events}" 2>/dev/null | sort -u)"
    local unknown=()
    local t
    while IFS= read -r t; do
      [[ -n "${t}" ]] || continue
      if ! _doctor_in_enum "${t}"; then unknown+=("${t}"); fi
    done <<< "${types}"
    if [[ "${#unknown[@]}" -gt 0 ]]; then
      enum_status="FAIL"
      unknown_count="${#unknown[@]}"
      unknown_types="$(printf '%s\n' "${unknown[@]}" | jq -R . | jq -s -c .)"
    fi
  fi

  jq -c -n \
    --arg idx "${idx_status}" \
    --arg lock "${lock_status}" --argjson lock_age "${lock_age}" \
    --arg schema "${schema_status}" --argjson sv "${schema_versions}" \
    --arg enum "${enum_status}" --argjson uc "${unknown_count}" --argjson ut "${unknown_types}" \
    '[
       {check:"idx_drift",      status:$idx},
       {check:"lock_leak",      status:$lock, age_seconds:$lock_age},
       {check:"schema_version", status:$schema, distribution:$sv},
       {check:"enum_unknown",   status:$enum, unknown_count:$uc, unknown_types:$ut}
     ]'
}

# _doctor_check_process <project_root> <snapshot_json> [worker_filter] -> jq array on stdout
_doctor_check_process() {
  local pr="$1" snap="$2" filter="${3:-}"
  local workers_json
  if [[ -n "${filter}" ]]; then
    workers_json="$(echo "${snap}" | jq -c --arg w "${filter}" '.workers[$w] // null | if . == null then [] else [. + {id:$w}] end')"
  else
    workers_json="$(echo "${snap}" | jq -c '[.workers | to_entries[] | .value + {id: .key}]')"
  fi

  local results=()
  local count i wid runner session worker state record runner_lib alive_rc result rec
  count="$(echo "${workers_json}" | jq 'length')"
  for ((i=0; i<count; i++)); do
    record="$(echo "${workers_json}" | jq -c ".[${i}]")"
    state="$(echo "${record}" | jq -r '.state // ""')"
    [[ "${state}" == "orphaned" ]] || continue  # process 검사는 orphaned 워커만

    wid="$(echo "${record}" | jq -r '.id // ""')"
    runner="$(echo "${record}" | jq -r '.runner // ""')"
    session="$(echo "${record}" | jq -r '.session_id // ""')"
    worker="$(echo "${record}" | jq -r '(.worktree_path // "") | split("/") | .[-1]')"

    result="INDETERMINATE"
    runner_lib="${_DOCTOR_SCRIPT_DIR}/runners/${runner}.sh"
    if [[ -f "${runner_lib}" ]]; then
      # shellcheck source=/dev/null
      source "${runner_lib}"
      if declare -F "runner_${runner}_check_alive" >/dev/null; then
        alive_rc=0
        "runner_${runner}_check_alive" "${session}" "${worker}" "${pr}" >/dev/null 2>&1 || alive_rc=$?
        case "${alive_rc}" in
          0) result="ALIVE" ;;
          1) result="GONE" ;;
          *) result="INDETERMINATE" ;;
        esac
      fi
    fi

    local rec_recommend
    case "${result}" in
      ALIVE)        rec_recommend="investigate_manually" ;;
      GONE)         rec_recommend="safe_to_cleanup" ;;
      *)            rec_recommend="indeterminate" ;;
    esac

    rec="$(jq -c -n --arg w "${wid}" --arg s "${state}" --arg r "${result}" --arg rc "${rec_recommend}" \
      '{worker_id:$w, state:$s, check:"check_alive", result:$r, recommendation:$rc}')"
    results+=("${rec}")
  done

  if [[ "${#results[@]}" -eq 0 ]]; then
    echo '[]'
  else
    printf '%s\n' "${results[@]}" | jq -s -c .
  fi
}

# _doctor_check_worktree <project_root> <snapshot_json> [worker_filter] -> jq array on stdout
_doctor_check_worktree() {
  local pr="$1" snap="$2" filter="${3:-}"
  local workers_json
  if [[ -n "${filter}" ]]; then
    workers_json="$(echo "${snap}" | jq -c --arg w "${filter}" '.workers[$w] // null | if . == null then [] else [. + {id:$w}] end')"
  else
    workers_json="$(echo "${snap}" | jq -c '[.workers | to_entries[] | .value + {id: .key}]')"
  fi

  local results=()
  local count i wid state wt dirty=false unpushed=0 scenario recommendation rec record
  count="$(echo "${workers_json}" | jq 'length')"
  for ((i=0; i<count; i++)); do
    record="$(echo "${workers_json}" | jq -c ".[${i}]")"
    wid="$(echo "${record}" | jq -r '.id // ""')"
    state="$(echo "${record}" | jq -r '.state // ""')"
    wt="$(echo "${record}" | jq -r '.worktree_path // ""')"

    dirty=false; unpushed=0
    if [[ -n "${wt}" && -d "${wt}" ]]; then
      if ! git -C "${wt}" diff --quiet 2>/dev/null \
         || ! git -C "${wt}" diff --cached --quiet 2>/dev/null \
         || [[ -n "$(git -C "${wt}" ls-files --others --exclude-standard 2>/dev/null)" ]]; then
        dirty=true
      fi
      if git -C "${wt}" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        unpushed="$(git -C "${wt}" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
      fi
    fi

    case "${state}" in
      stopped)
        if [[ "${dirty}" == "true" ]]; then scenario="dirty_change"; recommendation="commit_or_discard"
        elif [[ "${unpushed}" -gt 0 ]]; then scenario="unpushed_commits"; recommendation="push_or_override"
        else scenario="normal_stopped"; recommendation="cleanup"
        fi
        ;;
      orphaned)
        # process 검사 결과는 별도 카테고리. 여기서는 worktree 관점만 — 운영자가 두 카테고리 cross-read.
        if [[ "${dirty}" == "true" ]]; then scenario="dirty_change"; recommendation="commit_or_discard"
        elif [[ "${unpushed}" -gt 0 ]]; then scenario="unpushed_commits"; recommendation="push_or_override"
        else scenario="crash_orphan_or_leak"; recommendation="cross_ref_process_check"
        fi
        ;;
      archived) continue ;;  # archived 는 worktree 부재 가정 — 보고 제외
      *) scenario="active"; recommendation="not_applicable" ;;
    esac

    rec="$(jq -c -n --arg w "${wid}" --arg s "${state}" --arg sc "${scenario}" \
      --argjson d "${dirty}" --argjson u "${unpushed}" --arg rc "${recommendation}" \
      '{worker_id:$w, state:$s, scenario:$sc, dirty:$d, unpushed:$u, recommendation:$rc}')"
    results+=("${rec}")
  done

  if [[ "${#results[@]}" -eq 0 ]]; then
    echo '[]'
  else
    printf '%s\n' "${results[@]}" | jq -s -c .
  fi
}

# registry_cmd_doctor <args...>
registry_cmd_doctor() {
  local worker_filter="" checks="integrity,process,worktree" json=0 strict=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help|help)
        cat <<'EOF'
Usage: company workers doctor [--json] [--strict] [--worker=<wid>]
                              [--check=integrity,process,worktree]

  read-only 진단. events.jsonl 추가 0건. snapshot rebuild 는 mutating
  (Phase 4 D2 P1-4 정신 — drift 발견 시점에 자동 보정).

Flags:
  --worker=<wid>   특정 wid 만 검사 (다른 워커 무시).
  --check=<csv>    검사 카테고리 제한 (integrity/process/worktree).
                   integrity: registry 정합성 (idx_drift/lock_leak/schema_version/enum_unknown)
                   process:   orphaned 워커의 실 process 검출 (runner adapter 별)
                   worktree:  worktree 5 시나리오 매트릭스 적용
  --json           stdout 을 JSON. 사람용 메시지 stderr.
  --strict         정합성 결함 1건이라도 있으면 exit 1.

Exit codes:
  0 — 모든 검사 PASS (또는 process/worktree 의 보고는 0)
  1 — integrity 결함 (또는 --strict 시 결함 1건이라도 있으면)
  2 — lock 획득 실패 / jq 부재 등 환경 결함
EOF
        return 0 ;;
      --worker=*)  worker_filter="${1#--worker=}"; shift ;;
      --worker)    [[ $# -ge 2 ]] || _doctor_fail "--worker requires a value"; worker_filter="$2"; shift 2 ;;
      --check=*)   checks="${1#--check=}"; shift ;;
      --check)     [[ $# -ge 2 ]] || _doctor_fail "--check requires a value"; checks="$2"; shift 2 ;;
      --json)      json=1; shift ;;
      --strict)    strict=1; shift ;;
      --) shift; break ;;
      --*) _doctor_fail "unknown flag: $1" ;;
      *) _doctor_fail "doctor does not accept positional args (use --worker=<wid>): $1" ;;
    esac
  done

  : "${PROJECT_ROOT:?PROJECT_ROOT must be exported by scripts/company}"
  command -v jq >/dev/null 2>&1 || _doctor_fail "jq not found" 2

  local do_integrity=0 do_process=0 do_worktree=0
  case ",${checks}," in
    *,integrity,*) do_integrity=1 ;;
  esac
  case ",${checks}," in
    *,process,*) do_process=1 ;;
  esac
  case ",${checks}," in
    *,worktree,*) do_worktree=1 ;;
  esac
  [[ "${do_integrity}" -eq 1 || "${do_process}" -eq 1 || "${do_worktree}" -eq 1 ]] \
    || _doctor_fail "--check must include at least one of integrity/process/worktree"

  local integrity_json='[]' process_json='[]' worktree_json='[]'
  local snap; snap="$(registry_get_snapshot "${PROJECT_ROOT}" 2>/dev/null || echo '{"workers":{}}')"

  [[ "${do_integrity}" -eq 1 ]] && integrity_json="$(_doctor_check_integrity "${PROJECT_ROOT}")"
  [[ "${do_process}"   -eq 1 ]] && process_json="$(_doctor_check_process "${PROJECT_ROOT}" "${snap}" "${worker_filter}")"
  [[ "${do_worktree}"  -eq 1 ]] && worktree_json="$(_doctor_check_worktree "${PROJECT_ROOT}" "${snap}" "${worker_filter}")"

  local issues
  issues="$(jq -n --argjson i "${integrity_json}" --argjson p "${process_json}" --argjson w "${worktree_json}" '
    ([$i[] | select(.status != "PASS")] | length) +
    ([$p[] | select(.result == "ALIVE")] | length) +
    ([$w[] | select(.recommendation == "commit_or_discard" or .recommendation == "push_or_override")] | length)
  ')"

  local workers_count
  workers_count="$(echo "${snap}" | jq '.workers | length')"

  if [[ "${json}" -eq 1 ]]; then
    jq -n \
      --arg ver "1.12.0" \
      --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson summary "$(jq -n --argjson w "${workers_count}" --argjson i "${issues}" '{workers:$w, issues:$i}')" \
      --argjson integrity "${integrity_json}" \
      --argjson process "${process_json}" \
      --argjson worktree "${worktree_json}" \
      '{doctor_version:$ver, checked_at:$checked_at, summary:$summary, integrity:$integrity, process:$process, worktree:$worktree}'
  else
    echo "doctor: workers=${workers_count} issues=${issues}" >&2
    [[ "${do_integrity}" -eq 1 ]] && echo "${integrity_json}" | jq -r '.[] | "  integrity[" + .check + "]: " + .status' >&2 || true
    [[ "${do_process}"   -eq 1 ]] && echo "${process_json}"   | jq -r '.[] | "  process[" + .worker_id + "]: " + .result + " (" + .recommendation + ")"' >&2 || true
    [[ "${do_worktree}"  -eq 1 ]] && echo "${worktree_json}"  | jq -r '.[] | "  worktree[" + .worker_id + "]: " + .scenario + " (" + .recommendation + ")"' >&2 || true
  fi

  # exit code policy (D1):
  #   0  모든 검사 PASS
  #   1  --strict + issues > 0  OR  integrity 결함 1건이라도
  #   2  환경 결함 (jq 부재 등) — 위에서 처리
  local integrity_fail
  integrity_fail="$(echo "${integrity_json}" | jq '[.[] | select(.status != "PASS")] | length')"

  # `--gc` stale guard marker (D2 사전 조건): integrity PASS 일 때만 기록.
  # cleanup CLI 가 직전 N분 안의 PASS 기록 존재 여부 검사.
  if [[ "${integrity_fail}" -eq 0 ]]; then
    _doctor_record_pass "${PROJECT_ROOT}"
  fi

  if [[ "${strict}" -eq 1 && "${issues}" -gt 0 ]]; then exit 1
  elif [[ "${integrity_fail}" -gt 0 ]]; then exit 1
  fi
  exit 0
}

# Phase 5 doctor PASS 기록 — `--gc` stale guard (D2 사전 조건).
# cleanup CLI 가 직전 N분 안의 PASS 기록 존재 여부 검사하기 위한 marker.
_doctor_record_pass() {
  local pr="$1"
  local marker_dir="${pr}/.company-runtime/harness"
  local marker="${marker_dir}/.doctor.last_pass"
  mkdir -p "${marker_dir}" 2>/dev/null || true
  date +%s > "${marker}" 2>/dev/null || true
}
