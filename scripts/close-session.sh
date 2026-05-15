#!/usr/bin/env bash
set -euo pipefail

SESSION_ID="${1:-}"
ROOT="${2:-.}"
CLEANUP_WORKTREE="${3:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${SESSION_ID}" ]]; then
  echo "Usage: $0 <session-id> [project-root] [--cleanup-worktree]"
  exit 1
fi

# shellcheck source=./git-worktree-lib.sh
source "${SCRIPT_DIR}/git-worktree-lib.sh"
# shellcheck source=./cost-mode-lib.sh
source "${SCRIPT_DIR}/cost-mode-lib.sh"

PROJECT_ROOT="$(resolve_shared_project_root "${ROOT}")"
load_session_metadata "${PROJECT_ROOT}" "${SESSION_ID}" || true
SESSION_INFO="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/session-info.env"
HISTORY_DIR="${PROJECT_ROOT}/.company-runtime/pattern-memory"
HISTORY_FILE="${HISTORY_DIR}/session-history.tsv"
SESSION_REPORT="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/session-report.md"
TELEMETRY_FILE="${PROJECT_ROOT}/.company-runtime/telemetry/spawn-telemetry.tsv"
ROUTING_FEEDBACK_FILE="${PROJECT_ROOT}/.company-project/routing-feedback.md"
APPROVAL_LOG="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/approval-log.md"
PROMOTION_LOG="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/promotion-log.md"

TOPIC="n/a"
COST_MODE="$(resolve_cost_mode "${PROJECT_ROOT}")"
if [[ -f "${SESSION_INFO}" ]]; then
  # shellcheck disable=SC1090
  source "${SESSION_INFO}"
fi

check_session_outputs() {
  local session_id="$1"
  local project_root="$2"
  local artifacts_dir="${project_root}/.company-artifacts/${session_id}"
  local exports_dir="${project_root}/.company-exports/${session_id}"
  local telemetry_file="${project_root}/.company-runtime/telemetry/spawn-telemetry.tsv"

  local has_worker_success=0
  local has_approved=0
  local has_artifacts=0
  local has_exports=0

  # worker success 표시 (spawn-telemetry에서 해당 세션의 success 레코드 확인)
  if [[ -f "${telemetry_file}" ]]; then
    if grep -q "	${session_id}	" "${telemetry_file}" 2>/dev/null && \
       grep "	${session_id}	" "${telemetry_file}" 2>/dev/null | grep -q "	success"; then
      has_worker_success=1
    fi
  fi

  # v1.1.0 (C2): approved 마커 활성화. company-approve.sh가 생성.
  [[ -f "${project_root}/.company-runtime/sessions/${session_id}/approved" ]] && has_approved=1

  # artifacts 공백 여부
  if [[ -d "${artifacts_dir}" ]] && [[ -n "$(find "${artifacts_dir}" -type f 2>/dev/null | head -n1)" ]]; then
    has_artifacts=1
  fi

  # exports 공백 여부
  if [[ -d "${exports_dir}" ]] && [[ -n "$(find "${exports_dir}" -type f 2>/dev/null | head -n1)" ]]; then
    has_exports=1
  fi

  # severity 판정
  local exit_code=0
  if (( has_worker_success == 1 && has_artifacts == 0 )); then
    echo "FAIL: 워커가 성공했지만 artifacts가 비어있습니다 (${artifacts_dir})" >&2
    exit_code=1
  fi
  if (( has_approved == 1 && has_exports == 0 )); then
    echo "FAIL: 승인된 세션인데 exports가 비어있습니다 (${exports_dir})" >&2
    exit_code=1
  fi
  if (( has_worker_success == 0 && has_artifacts == 0 )); then
    echo "WARN: 워커 실행 기록 없음 + artifacts 공백 — 세션이 prepared 단계에서만 끝났을 수 있습니다" >&2
  fi
  if (( has_artifacts == 1 && has_exports == 0 )); then
    echo "WARN: artifacts는 있지만 exports가 비어있습니다 — 승격(promotion) 단계 미실행" >&2
  fi
  return "${exit_code}"
}

workers="none"
if [[ -d "${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers" ]]; then
  workers="$(find "${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | paste -sd ',' -)"
  [[ -n "${workers}" ]] || workers="none"
fi

collect_worker_compact_results() {
  local runtime_root="$1"
  if [[ ! -d "${runtime_root}" ]]; then
    return 0
  fi

  while IFS= read -r result_file; do
    local worker_name summary_line
    worker_name="$(basename "$(dirname "${result_file}")")"
    summary_line="$(awk '/^## Summary/{flag=1; next} /^## /{flag=0} flag && /^- /{sub(/^- /, "", $0); print; exit}' "${result_file}")"
    if [[ -n "${summary_line}" ]]; then
      printf '%s: %s\n' "${worker_name}" "${summary_line}"
    fi
  done < <(find "${runtime_root}" -mindepth 2 -maxdepth 2 -path "*/compact-result.md" -type f | sort)
}

collect_worker_compact_section() {
  local runtime_root="$1"
  local section_title="$2"
  if [[ ! -d "${runtime_root}" ]]; then
    return 0
  fi

  while IFS= read -r result_file; do
    local worker_name section_line
    worker_name="$(basename "$(dirname "${result_file}")")"
    section_line="$(awk -v title="${section_title}" '
      $0 == "## " title {flag=1; next}
      /^## / {flag=0}
      flag && /^- / {sub(/^- /, "", $0); print; exit}
    ' "${result_file}")"
    if [[ -n "${section_line}" ]]; then
      printf '%s: %s\n' "${worker_name}" "${section_line}"
    fi
  done < <(find "${runtime_root}" -mindepth 2 -maxdepth 2 -path "*/compact-result.md" -type f | sort)
}

routing_feedback="not-recorded"
if [[ -f "${ROUTING_FEEDBACK_FILE}" ]]; then
  routing_feedback="$(awk -v topic="${TOPIC:-}" '
    /^- / {
      if (topic != "" && index($0, topic) > 0) line=$0
      last=$0
    }
    END {
      if (line != "") print line
      else if (last != "") print last
    }' "${ROUTING_FEEDBACK_FILE}")"
  [[ -n "${routing_feedback}" ]] || routing_feedback="not-recorded"
fi

mkdir -p "${HISTORY_DIR}"
timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z' | sed 's/\(..\)$/:\1/')"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${timestamp}" "${SESSION_ID}" "${COST_MODE}" "${workers}" "${TOPIC:-n/a}" "${routing_feedback}" >> "${HISTORY_FILE}"

if [[ -f "${SESSION_REPORT}" ]]; then
  approvals="pending"
  approval_summary="not-recorded"
  promotion_status="not-recorded"
  outputs="none"
  open_risks="n/a"
  next_actions="review artifacts and promote confirmed outputs"
  spawn_notes="no-telemetry"
  spawn_success_rate="n/a"
  compact_results="none"
  compact_outputs="none"
  compact_risks="n/a"
  worker_runtime_root="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers"

  if [[ -d "${PROJECT_ROOT}/.company-artifacts/${SESSION_ID}" ]]; then
    outputs="$(find "${PROJECT_ROOT}/.company-artifacts/${SESSION_ID}" -mindepth 1 -maxdepth 2 -type f | sed "s#${PROJECT_ROOT}/##" | head -n 10 | paste -sd ', ' -)"
    [[ -n "${outputs}" ]] || outputs=".company-artifacts/${SESSION_ID}/"
  fi

  if [[ -f "${APPROVAL_LOG}" ]]; then
    approvals="$(awk -F'`' '/final_status=/{print $2; exit}' "${APPROVAL_LOG}")"
    [[ -n "${approvals}" ]] || approvals="pending"
    approval_summary="$(awk -F'`' '
      /approved_workers=/{approved=$2}
      /blocked_workers=/{blocked=$2}
      /leader_note=/{note=$2}
      END {
        if (approved == "") approved = "none"
        if (blocked == "") blocked = "none"
        if (note == "") note = "none"
        printf "approved=%s | blocked=%s | note=%s", approved, blocked, note
      }
    ' "${APPROVAL_LOG}")"
  fi

  if [[ -f "${PROMOTION_LOG}" ]]; then
    promotion_status="$(awk -F'`' '
      /promoted_to_project_work=/{promoted=$2}
      /promoted_paths=/{paths=$2}
      /exports_updated=/{exports=$2}
      /followup_session=/{followup=$2}
      END {
        if (promoted == "") promoted = "pending"
        if (paths == "") paths = "none"
        if (exports == "") exports = "pending"
        if (followup == "") followup = "none"
        printf "promoted=%s | paths=%s | exports=%s | followup=%s", promoted, paths, exports, followup
      }
    ' "${PROMOTION_LOG}")"
  fi

  compact_results="$(collect_worker_compact_results "${worker_runtime_root}" | paste -sd ' | ' -)"
  [[ -n "${compact_results}" ]] || compact_results="none"
  compact_outputs="$(collect_worker_compact_section "${worker_runtime_root}" "Outputs" | paste -sd ' | ' -)"
  [[ -n "${compact_outputs}" ]] || compact_outputs="none"
  compact_risks="$(collect_worker_compact_section "${worker_runtime_root}" "Risks" | paste -sd ' | ' -)"
  [[ -n "${compact_risks}" ]] || compact_risks="n/a"

  if [[ "${routing_feedback}" == *"feedback=\`good\`"* ]]; then
    next_actions="promote confirmed outputs to project-work"
  elif [[ "${routing_feedback}" == *"feedback=\`insufficient\`"* ]]; then
    next_actions="consider deep mode or add one supporting worker before rerun"
  elif [[ "${routing_feedback}" == *"feedback=\`overkill\`"* ]]; then
    next_actions="consider cheap mode or fewer workers next time"
  elif [[ "${routing_feedback}" == *"feedback=\`wrong-worker\`"* ]]; then
    next_actions="reroute topic before next execution"
  fi

  if [[ -f "${TELEMETRY_FILE}" ]]; then
    spawn_notes="$(awk -F'\t' -v sid="${SESSION_ID}" '$2 == sid {print $0}' "${TELEMETRY_FILE}" | tail -n 3 | paste -sd ' | ' -)"
    [[ -n "${spawn_notes}" ]] || spawn_notes="no-telemetry"
    spawn_success_rate="$(awk -F'\t' -v sid="${SESSION_ID}" '
      $2 == sid {
        if ($7 == "success") success++
        else if ($7 == "failure") failure++
      }
      END {
        total = success + failure
        if (total == 0) {
          print "n/a"
        } else {
          rate = int((success * 100) / total)
          printf "%d%% (%d/%d)", rate, success, total
        }
      }
    ' "${TELEMETRY_FILE}")"
  fi

  cat > "${SESSION_REPORT}" <<EOF
# Session Report

- Session ID: ${SESSION_ID}
- Topic: ${TOPIC:-n/a}
- Cost Mode: ${COST_MODE}
- Workers: ${workers}
- Worktree: ${WORKTREE_ROOT:-shared-root}
- Approvals: ${approvals}
- Approval Summary: ${approval_summary}
- Outputs: ${outputs}
- Compact Results: ${compact_results}
- Worker Outputs: ${compact_outputs}
- Open Risks: ${compact_risks}
- Next Actions: ${next_actions}
- Routing Feedback: ${routing_feedback}
- Promotion Status: ${promotion_status}
- Spawn Success Rate: ${spawn_success_rate}
- Spawn Notes: ${spawn_notes}

## Close Checklist

- [ ] artifact 초안을 검토했다
- [ ] 확정본을 project-work로 승격할지 결정했다
- [ ] routing feedback을 기록했다
- [ ] 다음 session 필요 여부를 판단했다
EOF
fi

if [[ "${CLEANUP_WORKTREE}" == "--cleanup-worktree" ]]; then
  bash "${SCRIPT_DIR}/git-worktree-remove.sh" "${SESSION_ID}" "${PROJECT_ROOT}"
fi

# v1.3.6: result-collector daemon 이 이 세션에 붙어 있으면 graceful stop
if [[ -x "${SCRIPT_DIR}/result-collector.sh" ]]; then
  bash "${SCRIPT_DIR}/result-collector.sh" "${SESSION_ID}" "${PROJECT_ROOT}" --stop >/dev/null 2>&1 || true
fi

echo ""
echo "👉 NEXT: .company-artifacts/${SESSION_ID}/ 검토 후 확정본만 project-work/ 로 승격하세요."
echo "  - 전체 리포트: .company-runtime/sessions/${SESSION_ID}/session-report.md"
echo "  - 다음 세션: /rw <topic> 또는 company run \"<topic>\""

SEVERITY_RESULT="ok"
check_session_outputs "${SESSION_ID}" "${PROJECT_ROOT}" || SEVERITY_RESULT="fail"

# v1.1.0 (C3): 이벤트 로거 — session_closed 기록
bash "${SCRIPT_DIR}/company-emit.sh" "session_closed" "${SESSION_ID}" "${PROJECT_ROOT}" "result=${SEVERITY_RESULT}" >/dev/null 2>&1 || true

# v1.3.4 Shadow Tracking (warn-only) — 워커가 EnterPlanMode/Agent/Task 를 자가 호출했는지
# transcript 스캐너로 집계. permissions.deny 도입 전 근거 수집 단계이므로 best-effort.
bash "${SCRIPT_DIR}/shadow-tool-scan.sh" "${SESSION_ID}" "${PROJECT_ROOT}" >/dev/null 2>&1 || true

# Runtime quality probes (warn/event only).
# close-session 의 본질은 세션 메타데이터를 보존하는 것이므로, 품질 프로브 실패가
# 종료 자체를 막지는 않는다. sentinel-scan 은 sentinel_detected 이벤트를 남기고,
# compact schema validator 는 frontmatter/스키마 drift 를 리더가 볼 수 있게 출력한다.
QUALITY_NOTES=()
if [[ -x "${SCRIPT_DIR}/sentinel-scan.sh" ]]; then
  if _sentinel_out="$(bash "${SCRIPT_DIR}/sentinel-scan.sh" "${SESSION_ID}" "${PROJECT_ROOT}" 2>&1)"; then
    QUALITY_NOTES+=("${_sentinel_out}")
  else
    QUALITY_NOTES+=("sentinel-scan failed: ${_sentinel_out}")
  fi
fi
if [[ -x "${SCRIPT_DIR}/validate-compact-schemas.sh" ]]; then
  if _compact_out="$(bash "${SCRIPT_DIR}/validate-compact-schemas.sh" "${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}" 2>&1)"; then
    QUALITY_NOTES+=("${_compact_out}")
  else
    QUALITY_NOTES+=("validate-compact-schemas failed: ${_compact_out}")
  fi
fi

echo "Closed session metadata flow: ${SESSION_ID}"
echo "Runtime kept at: ${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}"
echo "Artifacts kept at: ${PROJECT_ROOT}/.company-artifacts/${SESSION_ID}"
echo "If a tmux leader session is still open, close it manually."

# v1.1.0 (C4): 10초 세션 요약 — events.jsonl + artifacts/exports 카운트 기반.
# (HARNESS_V0 §4.6)
EVENTS_FILE="${PROJECT_ROOT}/.company-runtime/harness/events.jsonl"
ARTIFACTS_DIR="${PROJECT_ROOT}/.company-artifacts/${SESSION_ID}"
EXPORTS_DIR="${PROJECT_ROOT}/.company-exports/${SESSION_ID}"
APPROVED_MARKER="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/approved"

session_event_count=0
if [[ -f "${EVENTS_FILE}" ]]; then
  session_event_count=$(grep -c "\"session_id\":\"${SESSION_ID}\"" "${EVENTS_FILE}" 2>/dev/null) || session_event_count=0
fi
artifact_files=0
if [[ -d "${ARTIFACTS_DIR}" ]]; then
  artifact_files=$(find "${ARTIFACTS_DIR}" -type f 2>/dev/null | wc -l | tr -d ' ')
fi
export_files=0
if [[ -d "${EXPORTS_DIR}" ]]; then
  export_files=$(find "${EXPORTS_DIR}" -type f 2>/dev/null | wc -l | tr -d ' ')
fi
approved_status="❌"
[[ -f "${APPROVED_MARKER}" ]] && approved_status="✅"
promotion_status_line="⏸  미승격"
if [[ "${export_files}" -gt 0 ]]; then
  promotion_status_line="✅ .company-exports/${SESSION_ID}/ (${export_files} files)"
fi

# R25 Phase 4a (축 2): export_promoted emit — exports 디렉토리에 파일이 실존하면 canonical 이벤트 발화
# severity=P3 (정상 승격). 회귀 시에는 리더 판단으로 P2 격상 (notification-policy §1 각주 ² 참조).
# silent skip 정책: company-emit.sh 자체가 slack.enabled=false 일 때 무동작 → 여기서는 조건만 판단.
if [[ "${export_files}" -gt 0 ]]; then
  bash "${SCRIPT_DIR}/company-emit.sh" "export_promoted" "${SESSION_ID}" "${PROJECT_ROOT}" \
    "export_files=${export_files}" "severity=P3" >/dev/null 2>&1 || true
fi

echo ""
echo "📊 세션 요약 (${SESSION_ID})"
echo "  워커:     ${workers}"
echo "  이벤트:   ${session_event_count}건 (events.jsonl)"
echo "  artifacts: ${artifact_files} files"
echo "  승인:     ${approved_status}"
echo "  승격:     ${promotion_status_line}"
echo "  severity: ${SEVERITY_RESULT}"
if [[ "${#QUALITY_NOTES[@]}" -gt 0 ]]; then
  echo "  quality:  probes ran (${#QUALITY_NOTES[@]})"
  for _quality_note in "${QUALITY_NOTES[@]}"; do
    while IFS= read -r _quality_line; do
      [[ -z "${_quality_line}" ]] && continue
      echo "            ${_quality_line}"
    done <<< "${_quality_note}"
  done
fi
