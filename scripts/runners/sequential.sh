#!/usr/bin/env bash
# scripts/runners/sequential.sh (v1.3.7)
#
# Sequential runner — 항상 사용 가능한 폴백 러너.
# 병렬 pane 을 띄우지 않고, 현재 터미널에서 워커 요청서(worker-request.md) 경로와
# "다음 단계" 안내만 출력한다. 리더/워커가 같은 쉘 컨텍스트에 있는 상황을 가정한다.
#
# 이 러너에서 '워커가 reachable' 의 의미는 "사용자가 이 터미널에서 실행할 수 있다"
# 이므로 spawn_worker 직후 spawn_started + spawn_ready 를 즉시 emit 한다.
#
# API:
#   runner_sequential_detect
#   runner_sequential_spawn_worker    <session> <worker> <project_root>
#   runner_sequential_send_worker_message <session> <worker> <project_root> <message>
#   runner_sequential_check_worker_status <session> <worker> <project_root>
#   runner_sequential_collect_worker_outputs <session> <project_root>
#   runner_sequential_stop_worker     <session> <worker> <project_root>
#   runner_sequential_current_session_name (빈 값)

runner_sequential_detect() {
  # 순차 러너는 특별한 의존성이 없다. 항상 available.
  return 0
}

runner_sequential_current_session_name() {
  # 세션 이름 개념이 없음 (호출자가 알고 있어야 함)
  printf ''
}

_sequential_emit() {
  local project_root="$1"; shift
  local event="$1"; shift
  local session="$1"; shift
  local emit="${RUNNER_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/company-emit.sh"
  [[ -f "${emit}" ]] || return 0
  bash "${emit}" "${event}" "${session}" "${project_root}" "$@" >/dev/null 2>&1 || true
}

runner_sequential_spawn_worker() {
  local session="$1"
  local worker="$2"
  local project_root="${3:-.}"

  local worker_dir="${project_root}/.company-runtime/sessions/${session}/workers/${worker}"
  local req="${worker_dir}/worker-request.md"
  local started_marker="${worker_dir}/spawn.started"
  local ready_marker="${worker_dir}/spawn_succeeded"

  mkdir -p "${worker_dir}"

  # 멱등: 이미 시작된 워커면 재-emit 없이 OK 반환
  if [[ -f "${started_marker}" ]] && [[ -f "${ready_marker}" ]]; then
    return 0
  fi

  # 요청서 부재 시 실패 — prepare-worker.sh 가 이미 생성했어야 함
  if [[ ! -f "${req}" ]]; then
    echo "sequential: worker-request.md not found for ${worker} — run prepare-worker first" >&2
    return 2
  fi

  # ── Phase 1 (2026-05-12): registry preflight + side effect 순서 재정렬 ──
  # 결정문: docs/decisions/2026-05-12-worker-registry-phase1.md v0.3 D3
  # 순서: registry append → marker → legacy emit (SSOT 우선).
  # registry preflight 실패 시 marker/legacy 미발행 (partial state 0건).
  local REGISTRY_LIB="${RUNNER_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/worker-registry-lib.sh"
  if [[ -f "${REGISTRY_LIB}" ]]; then
    # shellcheck disable=SC1090
    source "${REGISTRY_LIB}"

    # preflight 1: registry_init (디렉터리 보장)
    registry_init "${project_root}"

    # preflight 2: jq hard check (registry_append_event 내부에서도 검사하지만 조기 실패 최적화)
    if ! command -v jq >/dev/null 2>&1; then
      echo "sequential: jq is required for worker registry (Phase 1 hard dependency)." >&2
      echo "  install: brew install jq  /  apt install jq  /  yum install jq" >&2
      return 3
    fi

    local worker_id="wkr-${session}-${worker}"
    local started_ts ready_ts
    started_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local started_payload ready_payload
    started_payload="$(jq -S -c -n \
      --arg rh "inline:${session}" \
      --arg wt "${worker_dir}" \
      --arg topic "${worker}" \
      --arg role "primary" \
      --arg sid "${session}" \
      '{runner_handle:$rh, worktree_path:$wt, branch:null, topic:$topic, worker_role:$role, session_id:$sid}')"
    ready_payload="$(jq -S -c -n \
      --arg rh "inline:${session}" \
      '{runner_handle:$rh}')"

    # side effect 단계 1/2: registry append (lock 내부 authoritative duplicate guard 포함)
    if ! registry_append_event "${project_root}" spawn_started "${worker_id}" sequential "${started_payload}"; then
      echo "sequential: registry append (spawn_started) failed — marker/legacy not emitted" >&2
      return 4
    fi
  fi

  # side effect 단계 3: marker file write
  printf 'runner: sequential\nstarted_at: %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${started_marker}"
  printf 'mode: sequential\nts: %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${ready_marker}"

  # side effect 단계 4: legacy emit (events.jsonl)
  _sequential_emit "${project_root}" "spawn_started" "${session}" \
    "worker=${worker}" "runner=sequential"

  # side effect 단계 5/6: registry append spawn_ready + legacy
  if [[ -f "${REGISTRY_LIB}" ]]; then
    registry_append_event "${project_root}" spawn_ready "wkr-${session}-${worker}" sequential \
      "$(jq -S -c -n --arg rh "inline:${session}" '{runner_handle:$rh}')" || \
      echo "sequential: registry append (spawn_ready) failed (legacy already emitted)" >&2
  fi
  _sequential_emit "${project_root}" "spawn_ready" "${session}" \
    "worker=${worker}" "runner=sequential"

  # 사용자 친화적 다음 단계 안내
  cat >&2 <<EOF

────────────────────────────────────────────
  순차 실행 — 다음 단계
────────────────────────────────────────────
  워커 요청서가 준비됐습니다. 현재 터미널에서 Claude 워커로 진입하거나
  새 창에서 아래 파일을 시스템 프롬프트/컨텍스트로 투입하세요.

    ${req}

  승인까지의 흐름:
    1) compact-plan.md 가 워커에 의해 작성됩니다.
    2) 리더가 'company approve ${session}' 로 승인합니다.
    3) 'bash .company-kit/scripts/resume-worker.sh ${session} ${worker}' 로 실행 단계 진입.
────────────────────────────────────────────
EOF
}

runner_sequential_send_worker_message() {
  local session="$1"
  local worker="$2"
  local project_root="${3:-.}"
  local message="${4:-}"

  local worker_dir="${project_root}/.company-runtime/sessions/${session}/workers/${worker}"
  local inbox="${worker_dir}/inbox.log"
  mkdir -p "${worker_dir}"
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${message}" >> "${inbox}"

  cat >&2 <<EOF
[sequential] 워커 메시지를 ${inbox} 에 기록했습니다.
  → 현재 실행 중인 워커 쉘에 직접 아래 문구를 붙여넣으세요:

  ${message}

EOF
}

runner_sequential_check_worker_status() {
  # 0 = running/ready, 1 = unknown/not-started, 2 = done (result 있음)
  local session="$1"
  local worker="$2"
  local project_root="${3:-.}"
  local worker_dir="${project_root}/.company-runtime/sessions/${session}/workers/${worker}"

  if [[ -s "${worker_dir}/compact-result.md" ]] \
    && ! grep -qE 'status:[[:space:]]*"?template-example"?' "${worker_dir}/compact-result.md" 2>/dev/null; then
    echo "done"
    return 2
  fi
  if [[ -s "${worker_dir}/compact-plan.md" ]]; then
    echo "plan-ready"
    return 0
  fi
  if [[ -f "${worker_dir}/spawn.started" ]]; then
    echo "started"
    return 0
  fi
  echo "not-started"
  return 1
}

runner_sequential_collect_worker_outputs() {
  # 단일 터미널 러너이므로 "폴링이 아닌 파일 확인"이면 충분.
  local session="$1"
  local project_root="${2:-.}"
  local script_dir
  script_dir="${RUNNER_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  # 기존 result-collector.sh 의 oneshot 을 재사용
  if [[ -f "${script_dir}/result-collector.sh" ]]; then
    bash "${script_dir}/result-collector.sh" "${session}" "${project_root}" --oneshot || true
  fi
}

runner_sequential_interaction_mode() {
  # v1.3.8: Gemini UX 권고 — 사용자가 같은 쉘 컨텍스트에서 직접 진행
  printf 'detached\n'
}

runner_sequential_stop_worker() {
  # sequential 에서 '멈춘다' 의 의미는 사용자가 해당 쉘에서 Ctrl+C 하는 것.
  # 여기서는 marker 정리만.
  local session="$1"
  local worker="$2"
  local project_root="${3:-.}"
  local worker_dir="${project_root}/.company-runtime/sessions/${session}/workers/${worker}"
  rm -f "${worker_dir}/spawn.started" 2>/dev/null || true
  _sequential_emit "${project_root}" "worker_stopped" "${session}" \
    "worker=${worker}" "runner=sequential" "reason=manual"
}

# Phase 5 D4-B: doctor 의 process check 용 runner adapter.
# return: 0 = ALIVE, 1 = GONE, 2 = INDETERMINATE.
runner_sequential_check_alive() {
  local session="$1"
  local worker="$2"
  local project_root="${3:-.}"
  local marker="${project_root}/.company-runtime/sessions/${session}/workers/${worker}/spawn.started"
  [[ -f "${marker}" ]] && return 0 || return 1
}
