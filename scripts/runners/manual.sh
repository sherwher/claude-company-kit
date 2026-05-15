#!/usr/bin/env bash
# scripts/runners/manual.sh (v1.3.7)
#
# Manual runner — 사용자가 명시적으로 `--runner manual` 을 요청한 경우에만 쓴다.
# 동작은 "파일만 준비하고, 다음에 실행할 명령을 정확히 한 줄로 출력".
# sequential 과 달리 '자동 다음 단계' 를 띄우지 않고, 사용자 스크립트/문서화
# 워크플로에 끼워 넣기 좋게 설계돼 있다.

runner_manual_detect() {
  # manual 은 의존성 없음. 단, 사용자가 의도적으로 선택해야 하므로 auto 선택 대상은 아님.
  return 0
}

runner_manual_current_session_name() {
  printf ''
}

_manual_emit() {
  local project_root="$1"; shift
  local event="$1"; shift
  local session="$1"; shift
  local emit="${RUNNER_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/company-emit.sh"
  [[ -f "${emit}" ]] || return 0
  bash "${emit}" "${event}" "${session}" "${project_root}" "$@" >/dev/null 2>&1 || true
}

runner_manual_spawn_worker() {
  local session="$1"
  local worker="$2"
  local project_root="${3:-.}"
  local worker_dir="${project_root}/.company-runtime/sessions/${session}/workers/${worker}"
  local req="${worker_dir}/worker-request.md"

  mkdir -p "${worker_dir}"

  # ── Phase 2 (2026-05-13): registry preflight + side effect 순서 재정렬 ──
  # 결정문: docs/decisions/2026-05-12-worker-registry-phase2.md v0.5 D1-C
  local REGISTRY_LIB="${RUNNER_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/worker-registry-lib.sh"
  if [[ -f "${REGISTRY_LIB}" ]]; then
    # shellcheck disable=SC1090
    source "${REGISTRY_LIB}"
    registry_init "${project_root}"

    if ! command -v jq >/dev/null 2>&1; then
      echo "manual runner: jq is required for worker registry." >&2
      return 3
    fi

    local worker_id="wkr-${session}-${worker}"
    local started_payload
    started_payload="$(jq -S -c -n \
      --arg rh "marker:${worker_dir}/spawn.started" \
      --arg wt "${worker_dir}" \
      --arg topic "${worker}" \
      --arg role "primary" \
      --arg sid "${session}" \
      '{runner_handle:$rh, worktree_path:$wt, branch:null, topic:$topic, worker_role:$role, session_id:$sid}')"

    if ! registry_append_event "${project_root}" spawn_started "${worker_id}" manual "${started_payload}"; then
      echo "manual runner: registry append (spawn_started) failed — marker/legacy not emitted" >&2
      return 4
    fi
  fi

  printf 'runner: manual\nstarted_at: %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${worker_dir}/spawn.started"
  _manual_emit "${project_root}" "spawn_started" "${session}" \
    "worker=${worker}" "runner=manual"

  # Gemini UX 권고 문구
  cat <<EOF

──────────────────────────────────────────────────
  [MANUAL MODE] 실행 준비가 완료되었습니다.
  아래 경로의 요청서를 직접 워커 Claude 세션에 투입하세요.
──────────────────────────────────────────────────
  ${req}
──────────────────────────────────────────────────
  다음에 실행할 명령 예:
    claude --model sonnet --permission-mode acceptEdits \\
           --add-dir ${project_root} \\
           --append-system-prompt-file <assembled-prompt-path>

  💡 실행 후 'company status' 로 결과를 확인하십시오.
EOF
}

runner_manual_send_worker_message() {
  # manual 러너는 메시지를 보낼 수 없다. 파일에만 기록.
  local session="$1"
  local worker="$2"
  local project_root="${3:-.}"
  local message="${4:-}"
  local inbox="${project_root}/.company-runtime/sessions/${session}/workers/${worker}/inbox.log"
  mkdir -p "$(dirname "${inbox}")"
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${message}" >> "${inbox}"
  cat >&2 <<EOF
[manual] 아래 문구를 워커 Claude 에 직접 전달해 주세요:

  ${message}

EOF
}

runner_manual_check_worker_status() {
  local session="$1"
  local worker="$2"
  local project_root="${3:-.}"
  local worker_dir="${project_root}/.company-runtime/sessions/${session}/workers/${worker}"
  if [[ -s "${worker_dir}/compact-result.md" ]] \
    && ! grep -qE 'status:[[:space:]]*"?template-example"?' "${worker_dir}/compact-result.md" 2>/dev/null; then echo "done"; return 2; fi
  if [[ -s "${worker_dir}/compact-plan.md" ]]; then echo "plan-ready"; return 0; fi
  if [[ -f "${worker_dir}/spawn.started" ]]; then echo "started"; return 0; fi
  echo "not-started"; return 1
}

runner_manual_collect_worker_outputs() {
  local session="$1"
  local project_root="${2:-.}"
  local script_dir
  script_dir="${RUNNER_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  [[ -f "${script_dir}/result-collector.sh" ]] || return 0
  bash "${script_dir}/result-collector.sh" "${session}" "${project_root}" --oneshot || true
}

runner_manual_interaction_mode() {
  # v1.3.8: 사용자가 선호하는 방식으로 직접 실행
  printf 'manual\n'
}

runner_manual_stop_worker() {
  local session="$1"
  local worker="$2"
  local project_root="${3:-.}"
  rm -f "${project_root}/.company-runtime/sessions/${session}/workers/${worker}/spawn.started" 2>/dev/null || true
  _manual_emit "${project_root}" "worker_stopped" "${session}" "worker=${worker}" "runner=manual"
}

# Phase 5 D4-B: doctor process check.
# return: 0 = ALIVE (marker 존재), 1 = GONE, 2 = INDETERMINATE.
# manual runner 는 사용자 책임 영역 — marker 만 본다.
runner_manual_check_alive() {
  local session="$1"
  local worker="$2"
  local project_root="${3:-.}"
  local marker="${project_root}/.company-runtime/sessions/${session}/workers/${worker}/spawn.started"
  [[ -f "${marker}" ]] && return 0 || return 1
}
