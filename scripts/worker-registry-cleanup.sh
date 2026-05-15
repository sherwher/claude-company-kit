#!/usr/bin/env bash
# scripts/worker-registry-cleanup.sh
#
# Phase 5 (2026-05-15): registry SSOT 위 destructive CLI — `company workers cleanup`.
#
# 결정문: docs/decisions/2026-05-14-worker-registry-phase5.md v0.4 (accepted)
#         docs/decisions/2026-05-14-phase0-schema-v2-archived.md v0.4 (accepted)
#
# D2 단일 wid cleanup + --gc 일괄. 5 시나리오 분기 (D4-C):
#   normal_stopped / dirty_change / unpushed_commits / crash_orphan / force_stop_assumed_leak
#
# D5 ordering:
#   1. doctor 결과 기준 사전 분기 (state/dirty/unpushed)
#   2. 토큰 검증 destructive_local:worker_cleanup:<wid> (or worker_gc_all)
#   3. worktree 삭제 (git worktree remove --force)
#   4. branch 삭제 (default ON, --keep-branch opt-out)
#   5. worker_archived emit (atomic helper, schema bump D2 invariant 발효)
#   6. JSON / human 출력
#
# 의존: worker-registry-lib.sh, check-destructive-local-approval.sh
# 호출: scripts/company workers cleanup ... → registry_cmd_cleanup

set -euo pipefail

_CLEANUP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./worker-registry-lib.sh
source "${_CLEANUP_SCRIPT_DIR}/worker-registry-lib.sh"

_cleanup_fail() { echo "company workers cleanup: $*" >&2; exit "${2:-1}"; }
_cleanup_warn() { echo "company workers cleanup: $*" >&2; }

# _cleanup_check_token <session_id> <scope> <project_root> -> rc=0/1
_cleanup_check_token() {
  local session="$1" scope="$2" pr="$3"
  if [[ -z "${session}" ]]; then return 1; fi
  bash "${_CLEANUP_SCRIPT_DIR}/check-destructive-local-approval.sh" \
    "${session}" "${scope}" "${pr}" --quiet
}

# _cleanup_detect_scenario <wt_path> <state> -> echoes scenario + dirty + unpushed (csv)
_cleanup_detect_scenario() {
  local wt="$1" state="$2"
  local dirty=false unpushed=0 scenario

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
      if [[ "${dirty}" == "true" ]]; then scenario="dirty_change"
      elif [[ "${unpushed}" -gt 0 ]]; then scenario="unpushed_commits"
      else scenario="normal_stopped"
      fi ;;
    orphaned)
      if [[ "${dirty}" == "true" ]]; then scenario="dirty_change"
      elif [[ "${unpushed}" -gt 0 ]]; then scenario="unpushed_commits"
      else scenario="crash_orphan"  # process 카테고리에서 ALIVE 면 force_stop_assumed_leak — caller 가 결합
      fi ;;
    *) scenario="invalid_state" ;;
  esac

  printf '%s,%s,%s' "${scenario}" "${dirty}" "${unpushed}"
}

# _cleanup_one <wid> <runner> <session> <worker> <wt> <branch> <state> <reason>
#              <allow_dirty> <allow_unpushed> <keep_branch> <json>
# return: 0 정상 / 1 pre-condition reject / 3 worktree fail / 4 registry fail
_cleanup_one() {
  local wid="$1" runner="$2" session="$3" worker="$4" wt="$5" branch="$6" state="$7" reason="$8"
  local allow_dirty="$9" allow_unpushed="${10}" keep_branch="${11}" json="${12}"

  local scenario_csv scenario dirty unpushed
  scenario_csv="$(_cleanup_detect_scenario "${wt}" "${state}")"
  IFS=',' read -r scenario dirty unpushed <<< "${scenario_csv}"

  # state pre-check
  case "${state}" in
    stopped|orphaned) ;;
    *)
      if [[ "${json}" -eq 1 ]]; then
        jq -c -n --arg w "${wid}" --arg s "${state}" \
          '{action:"error", worker_id:$w, reason:"invalid_state", state:$s}'
      else
        _cleanup_warn "worker ${wid}: state=${state} — cleanup requires stopped or orphaned"
      fi
      return 1 ;;
  esac

  # dirty / unpushed override
  if [[ "${scenario}" == "dirty_change" && "${allow_dirty}" -eq 0 ]]; then
    if [[ "${json}" -eq 1 ]]; then
      jq -c -n --arg w "${wid}" --arg sc "${scenario}" \
        '{action:"error", worker_id:$w, reason:"dirty_change", scenario:$sc, hint:"--allow-dirty"}'
    else
      _cleanup_warn "worker ${wid}: dirty worktree — use --allow-dirty to override"
    fi
    return 1
  fi
  if [[ "${scenario}" == "unpushed_commits" && "${allow_unpushed}" -eq 0 ]]; then
    if [[ "${json}" -eq 1 ]]; then
      jq -c -n --arg w "${wid}" --arg sc "${scenario}" --argjson u "${unpushed}" \
        '{action:"error", worker_id:$w, reason:"unpushed_commits", scenario:$sc, unpushed:$u, hint:"--allow-unpushed"}'
    else
      _cleanup_warn "worker ${wid}: ${unpushed} unpushed commit(s) — use --allow-unpushed to override"
    fi
    return 1
  fi

  # worktree 삭제
  local wt_removed=false
  if [[ -n "${wt}" && -d "${wt}" ]]; then
    local repo_root
    repo_root="$(git -C "${wt}" rev-parse --show-toplevel 2>/dev/null || echo "")"
    if [[ -n "${repo_root}" ]]; then
      local main_repo
      main_repo="$(cd "${PROJECT_ROOT}" && git rev-parse --show-toplevel 2>/dev/null || echo "${PROJECT_ROOT}")"
      if git -C "${main_repo}" worktree remove "${wt}" --force >/dev/null 2>&1; then
        wt_removed=true
      else
        # fallback — git 이 worktree 로 인식 안 하면 디렉터리만 제거 (best effort, .company-runtime 하위 한정)
        case "${wt}" in
          */.company-runtime/sessions/*)
            rm -rf "${wt}" 2>/dev/null && wt_removed=true || true ;;
        esac
      fi
    fi
  elif [[ -z "${wt}" || ! -d "${wt}" ]]; then
    # worktree 가 이미 없음 — partial state recovery (Open Q3). 정리 정상 진행.
    wt_removed=true
  fi

  if [[ "${wt_removed}" != "true" ]]; then
    if [[ "${json}" -eq 1 ]]; then
      jq -c -n --arg w "${wid}" --arg wt "${wt}" \
        '{action:"error", worker_id:$w, reason:"worktree_remove_failed", worktree_path:$wt}'
    else
      _cleanup_warn "worker ${wid}: worktree remove failed (${wt})"
    fi
    return 3
  fi

  # branch 삭제 (best effort, unpushed 면 git -D 가 실패하므로 자연 보호)
  local branch_removed=false
  if [[ "${keep_branch}" -eq 0 && -n "${branch}" ]]; then
    local main_repo
    main_repo="$(cd "${PROJECT_ROOT}" && git rev-parse --show-toplevel 2>/dev/null || echo "${PROJECT_ROOT}")"
    if git -C "${main_repo}" branch -D "${branch}" >/dev/null 2>&1; then
      branch_removed=true
    fi
  fi

  # worker_archived emit — atomic helper (schema bump D2 invariant 발효).
  # terminal_states_csv 5종 — 중복 호출 race 시 두 번째는 no-op.
  local payload
  payload="$(jq -c -n --arg actor "user" --arg r "${reason}" --arg sc "${scenario}" \
    '{actor:$actor, reason:$r, scenario:$sc}')"

  # terminal_csv = "archived" 만 — schema bump D2 invariant (worker_archived 의
  # archived 진입 단일성). stopped/orphaned 는 archived 로의 정상 transition 이므로
  # 차단 대상 아님. archived 일 때만 multi-leader race 차단 (Phase 4 stop_confirmed
  # 의 stopped 측 invariant 와 대칭).
  local emit_log="${PROJECT_ROOT}/.company-runtime/harness/.cleanup-emit.stderr"
  : > "${emit_log}" 2>/dev/null || true
  if ! registry_append_event_with_terminal_check "${PROJECT_ROOT}" worker_archived \
    "${wid}" "${runner}" "${payload}" \
    "archived" 2>"${emit_log}"; then
    if [[ "${json}" -eq 1 ]]; then
      jq -c -n --arg w "${wid}" '{action:"error", worker_id:$w, reason:"registry_append_failed"}'
    else
      _cleanup_warn "worker ${wid}: worker_archived emit failed (worktree=${wt_removed})"
    fi
    return 4
  fi

  # multi-leader race: 두 번째 호출은 atomic helper 가 archived 인식 → no-op
  if grep -q "terminal guard: already" "${emit_log}" 2>/dev/null; then
    local guard_state
    guard_state="$(grep "terminal guard: already" "${emit_log}" | head -1 | sed -n 's/.*terminal guard: already \([a-z]*\).*/\1/p')"
    [[ -n "${guard_state}" ]] || guard_state="archived"
    rm -f "${emit_log}" 2>/dev/null || true
    if [[ "${json}" -eq 1 ]]; then
      jq -c -n --arg w "${wid}" --arg s "${guard_state}" \
        '{action:"noop", worker_id:$w, reason:"already_terminal", state:$s}'
    else
      _cleanup_warn "worker ${wid}: already ${guard_state} — no-op (multi-leader race)"
    fi
    return 0
  fi
  rm -f "${emit_log}" 2>/dev/null || true

  if [[ "${json}" -eq 1 ]]; then
    jq -c -n --arg w "${wid}" --arg sc "${scenario}" --arg r "${reason}" \
      --argjson wt "${wt_removed}" --argjson br "${branch_removed}" \
      '{action:"archived", worker_id:$w, scenario:$sc, reason:$r,
        worktree_removed:$wt, branch_removed:$br}'
  else
    local msg="worker ${wid}: ${scenario} → archived"
    [[ "${branch_removed}" == "true" ]] && msg="${msg} (branch removed)"
    echo "${msg}" >&2
  fi
  return 0
}

# _cleanup_gc_stale_check <project_root> <max_age_seconds> -> rc=0/1
_cleanup_gc_stale_check() {
  local pr="$1" max_age="${2:-300}"
  local marker="${pr}/.company-runtime/harness/.doctor.last_pass"
  [[ -f "${marker}" ]] || return 1
  local ts now
  ts="$(cat "${marker}" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  [[ -n "${ts}" && "${ts}" -gt 0 ]] || return 1
  [[ $(( now - ts )) -le "${max_age}" ]]
}

# registry_cmd_cleanup <args...>
registry_cmd_cleanup() {
  local wid="" reason="user" allow_unpushed=0 allow_dirty=0 keep_branch=0 json=0 gc=0
  local session_id="${COMPANY_SESSION_ID:-${SESSION_ID:-}}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help|help)
        cat <<'EOF'
Usage: company workers cleanup <worker_id> [--reason=<text>]
                                            [--allow-unpushed] [--allow-dirty]
                                            [--keep-branch] [--json]

       company workers cleanup --gc [--json]

  state 가 stopped/orphaned 만 허용. active → exit 1.
  worktree 5 시나리오 분기:
    dirty (변경 있음)       → reject (--allow-dirty override)
    unpushed commit         → reject (--allow-unpushed override)
    crash_orphan            → 정상 정리
    normal_stopped          → 정상 정리

  --gc: stopped/orphaned 모든 워커 일괄. 직전 5분 안 doctor PASS 기록 필수.

Flags:
  --reason=<text>          archived 사유 (기본 "user")
  --allow-unpushed         unpushed commit 있어도 진행 (single wid 만)
  --allow-dirty            uncommitted change 있어도 진행 (single wid 만)
  --keep-branch            branch 삭제 skip
  --json                   stdout JSON

Exit codes:
  0  정상 archived (또는 중복 호출 noop)
  1  pre-condition 실패 (active state / dirty / unpushed / --gc stale)
  2  worker_id not found
  3  worktree 삭제 실패
  4  registry append 실패
  5  토큰 미보유

Token (필수):
  single wid: destructive_local:worker_cleanup:<wid>
  --gc:       destructive_local:worker_gc_all
EOF
        return 0 ;;
      --reason=*)      reason="${1#--reason=}"; shift ;;
      --reason)        [[ $# -ge 2 ]] || _cleanup_fail "--reason requires a value"; reason="$2"; shift 2 ;;
      --allow-unpushed) allow_unpushed=1; shift ;;
      --allow-dirty)    allow_dirty=1; shift ;;
      --keep-branch)    keep_branch=1; shift ;;
      --json)           json=1; shift ;;
      --gc)             gc=1; shift ;;
      --) shift; break ;;
      --*) _cleanup_fail "unknown flag: $1" ;;
      *)
        if [[ -z "${wid}" ]]; then wid="$1"; shift
        else _cleanup_fail "cleanup accepts exactly one <worker_id>"
        fi ;;
    esac
  done

  : "${PROJECT_ROOT:?PROJECT_ROOT must be exported by scripts/company}"
  command -v jq >/dev/null 2>&1 || _cleanup_fail "jq not found" 2

  if [[ "${gc}" -eq 1 && -n "${wid}" ]]; then
    _cleanup_fail "--gc와 <worker_id>는 동시에 사용할 수 없습니다"
  fi
  if [[ "${gc}" -eq 0 && -z "${wid}" ]]; then
    _cleanup_fail "cleanup requires <worker_id> or --gc"
  fi

  registry_rebuild_index "${PROJECT_ROOT}" >/dev/null 2>&1 || _cleanup_fail "registry rebuild failed (run doctor)" 3
  local snap; snap="$(registry_get_snapshot "${PROJECT_ROOT}")" || _cleanup_fail "snapshot read failed" 3

  if [[ "${gc}" -eq 1 ]]; then
    # --gc stale guard: 직전 5분 안 doctor PASS 기록 필수
    if ! _cleanup_gc_stale_check "${PROJECT_ROOT}" 300; then
      if [[ "${json}" -eq 1 ]]; then
        jq -c -n '{action:"error", reason:"gc_stale", hint:"run company workers doctor first"}'
      else
        _cleanup_warn "--gc 직전 5분 안 doctor PASS 기록 없음. 'company workers doctor' 실행 후 재시도."
      fi
      exit 1
    fi

    # 토큰 검증 (gc)
    if ! _cleanup_check_token "${session_id}" "destructive_local:worker_gc_all" "${PROJECT_ROOT}"; then
      if [[ "${json}" -eq 1 ]]; then
        jq -c -n '{action:"error", reason:"approval_token_missing", scope:"destructive_local:worker_gc_all"}'
      else
        _cleanup_warn "토큰 부재: destructive_local:worker_gc_all"
      fi
      exit 5
    fi

    local archived_count=0 skipped_count=0 fail_count=0
    local results=()
    local workers_json count i record state wid_i runner_i session_i worker_i wt_i branch_i rc
    workers_json="$(echo "${snap}" | jq -c '[.workers | to_entries[] | .value + {id: .key}]')"
    count="$(echo "${workers_json}" | jq 'length')"
    for ((i=0; i<count; i++)); do
      record="$(echo "${workers_json}" | jq -c ".[${i}]")"
      state="$(echo "${record}" | jq -r '.state // ""')"
      case "${state}" in stopped|orphaned) ;; *) continue ;; esac

      wid_i="$(echo "${record}" | jq -r '.id // ""')"
      runner_i="$(echo "${record}" | jq -r '.runner // ""')"
      session_i="$(echo "${record}" | jq -r '.session_id // ""')"
      worker_i="$(echo "${record}" | jq -r '(.worktree_path // "") | split("/") | .[-1]')"
      wt_i="$(echo "${record}" | jq -r '.worktree_path // ""')"
      branch_i="$(echo "${record}" | jq -r '.branch // .branch_name // ""')"

      # --gc 보수: dirty/unpushed 자동 skip (override 불가)
      local pre_scenario; pre_scenario="$(_cleanup_detect_scenario "${wt_i}" "${state}" | cut -d, -f1)"
      if [[ "${pre_scenario}" == "dirty_change" || "${pre_scenario}" == "unpushed_commits" ]]; then
        skipped_count=$(( skipped_count + 1 ))
        results+=("$(jq -c -n --arg w "${wid_i}" --arg sc "${pre_scenario}" \
          '{action:"skip", worker_id:$w, scenario:$sc}')")
        continue
      fi

      rc=0
      local one_json
      one_json="$(_cleanup_one "${wid_i}" "${runner_i}" "${session_i}" "${worker_i}" "${wt_i}" \
        "${branch_i}" "${state}" "${reason}" "${allow_dirty}" "${allow_unpushed}" "${keep_branch}" 1 2>/dev/null)" || rc=$?
      if [[ "${rc}" -eq 0 ]]; then
        archived_count=$(( archived_count + 1 ))
      else
        fail_count=$(( fail_count + 1 ))
      fi
      [[ -n "${one_json}" ]] && results+=("${one_json}")
    done

    local results_arr
    if [[ "${#results[@]}" -eq 0 ]]; then results_arr='[]'
    else results_arr="$(printf '%s\n' "${results[@]}" | jq -s -c .)"
    fi

    if [[ "${json}" -eq 1 ]]; then
      jq -c -n --argjson a "${archived_count}" --argjson s "${skipped_count}" \
        --argjson f "${fail_count}" --argjson r "${results_arr}" \
        '{action:"gc", archived:$a, skipped:$s, failed:$f, results:$r}'
    else
      echo "gc: archived=${archived_count} skipped=${skipped_count} failed=${fail_count}" >&2
    fi
    [[ "${fail_count}" -eq 0 ]] && exit 0 || exit 4
  fi

  # single wid
  local record state runner session worker wt branch
  record="$(echo "${snap}" | jq -c --arg w "${wid}" '.workers[$w] // null')"
  if [[ "${record}" == "null" ]]; then
    if [[ "${json}" -eq 1 ]]; then
      jq -c -n --arg w "${wid}" '{action:"error", worker_id:$w, reason:"not_found"}'
    else
      _cleanup_warn "worker not found: ${wid}"
    fi
    exit 2
  fi

  # 토큰 검증
  if ! _cleanup_check_token "${session_id}" "destructive_local:worker_cleanup:${wid}" "${PROJECT_ROOT}"; then
    if [[ "${json}" -eq 1 ]]; then
      jq -c -n --arg w "${wid}" \
        '{action:"error", worker_id:$w, reason:"approval_token_missing",
          scope:("destructive_local:worker_cleanup:" + $w)}'
    else
      _cleanup_warn "토큰 부재: destructive_local:worker_cleanup:${wid}"
    fi
    exit 5
  fi

  state="$(echo "${record}" | jq -r '.state // ""')"
  runner="$(echo "${record}" | jq -r '.runner // ""')"
  session="$(echo "${record}" | jq -r '.session_id // ""')"
  worker="$(echo "${record}" | jq -r '(.worktree_path // "") | split("/") | .[-1]')"
  wt="$(echo "${record}" | jq -r '.worktree_path // ""')"
  branch="$(echo "${record}" | jq -r '.branch // .branch_name // ""')"

  local rc=0
  _cleanup_one "${wid}" "${runner}" "${session}" "${worker}" "${wt}" "${branch}" \
    "${state}" "${reason}" "${allow_dirty}" "${allow_unpushed}" "${keep_branch}" "${json}" || rc=$?
  exit "${rc}"
}
