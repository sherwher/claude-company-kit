#!/usr/bin/env bash
# scripts/runners/tmux.sh (v1.3.7)
#
# tmux runner — 기존 v1.3.6 까지의 암묵적 tmux 결합을 어댑터로 이관했다.
# 실제 pane spawn 은 여전히 리더 Claude 세션이 자체 teammate-mode 로 띄운다.
# 이 어댑터는 탐지/검증/메시지 주입/결과 수집 책임만 진다.
#
# API: detect / spawn_worker / send_worker_message / check_worker_status /
#      collect_worker_outputs / stop_worker / current_session_name

runner_tmux_detect() {
  # "tmux runner 가 available" 의 의미는 "실제로 pane 을 추가할 수 있다" 이다.
  # 따라서 tmux 바이너리 존재 + 현재 TMUX 클라이언트 안에서 실행 중 이어야 한다.
  # 이렇게 해야 `--runner=tmux --no-fallback` 을 tmux 밖에서 실행했을 때 의도대로
  # 실패로 떨어진다. resolve_runner 의 auto 경로는 TMUX env 를 추가로 확인하지만,
  # explicit 경로에서도 detect 가 엄격해야 한다.
  command -v tmux >/dev/null 2>&1 || return 1
  [[ -n "${TMUX:-}" ]] || return 1
  return 0
}

runner_tmux_current_session_name() {
  command -v tmux >/dev/null 2>&1 || return 0
  [[ -n "${TMUX:-}" ]] || return 0
  tmux display-message -p '#S' 2>/dev/null || printf ''
}

_tmux_emit() {
  local project_root="$1"; shift
  local event="$1"; shift
  local session="$1"; shift
  local emit="${RUNNER_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/company-emit.sh"
  [[ -f "${emit}" ]] || return 0
  bash "${emit}" "${event}" "${session}" "${project_root}" "$@" >/dev/null 2>&1 || true
}

runner_tmux_spawn_worker() {
  # tmux 러너에서 'spawn' 은 실제 pane 생성이 아니라 '리더가 pane 을 띄우도록 요청서를
  # 드롭하는 것'에 해당한다. prepare-worker.sh 가 이미 worker-request.md 를 썼고,
  # 이 함수는 canonical 이벤트만 찍고 pane 검증은 verify-worker-spawn.sh 에 맡긴다.
  local session="$1"
  local worker="$2"
  local project_root="${3:-.}"
  local worker_dir="${project_root}/.company-runtime/sessions/${session}/workers/${worker}"
  local started_marker="${worker_dir}/spawn.started"

  [[ -d "${worker_dir}" ]] || {
    echo "tmux runner: worker dir missing (${worker_dir})" >&2
    return 2
  }

  # 멱등: 이미 started 마커가 있으면 재-emit skip
  if [[ -f "${started_marker}" ]]; then
    return 0
  fi

  # ── Phase 2 (2026-05-13): registry preflight + side effect 순서 재정렬 ──
  # 결정문: docs/decisions/2026-05-12-worker-registry-phase2.md v0.5 D1-A
  # 순서: registry append → marker → legacy emit (Phase 1 sequential 패턴 상속).
  local REGISTRY_LIB="${RUNNER_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/worker-registry-lib.sh"
  if [[ -f "${REGISTRY_LIB}" ]]; then
    # shellcheck disable=SC1090
    source "${REGISTRY_LIB}"
    registry_init "${project_root}"

    if ! command -v jq >/dev/null 2>&1; then
      echo "tmux runner: jq is required for worker registry." >&2
      return 3
    fi

    local worker_id="wkr-${session}-${worker}"
    # runner_handle: tmux display-message canonical 계산값 (Phase 2 v0.5 P1-15)
    local runner_handle
    runner_handle="$(tmux display-message -p '#S:#I.#P' 2>/dev/null || echo 'unknown')"

    local started_payload
    started_payload="$(jq -S -c -n \
      --arg rh "${runner_handle}" \
      --arg wt "${worker_dir}" \
      --arg topic "${worker}" \
      --arg role "primary" \
      --arg sid "${session}" \
      '{runner_handle:$rh, worktree_path:$wt, branch:null, topic:$topic, worker_role:$role, session_id:$sid}')"

    # side effect 1: registry append (Phase 2 — marker/legacy 보다 먼저)
    if ! registry_append_event "${project_root}" spawn_started "${worker_id}" tmux "${started_payload}"; then
      echo "tmux runner: registry append (spawn_started) failed — marker/legacy not emitted" >&2
      return 4
    fi
  fi

  # side effect 2: marker file write
  printf 'runner: tmux\nstarted_at: %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${started_marker}"

  # side effect 3: legacy emit
  _tmux_emit "${project_root}" "spawn_started" "${session}" \
    "worker=${worker}" "runner=tmux"
}

runner_tmux_send_worker_message() {
  local session="$1"
  local worker="$2"
  local project_root="${3:-.}"
  local message="${4:-}"

  [[ -n "${message}" ]] || return 0
  command -v tmux >/dev/null 2>&1 || { echo "tmux runner: tmux not found" >&2; return 2; }
  [[ -n "${TMUX:-}" ]] || {
    echo "tmux runner: not inside a tmux session — cannot send keys" >&2
    return 3
  }

  # v1.3.8: 공통 헬퍼로 pane 검색 (cmux/zellij 등과 동일 패턴)
  local target
  target="$(_runner_find_pane_by_proc tmux claude "${worker}" 2>/dev/null)" || target=""
  if [[ -z "${target}" ]]; then
    echo "tmux runner: claude pane not found for worker=${worker}" >&2
    return 4
  fi

  # literal 전송을 강제해 C-c 같은 제어 키 시퀀스가 우발적으로 해석되지 않도록 한다.
  _runner_safe_send_keys tmux "${target}" "${message}"
}

# Interaction Mode (Gemini UX 권고) — 사용자가 세션 pane 을 직접 관찰.
runner_tmux_interaction_mode() {
  printf 'attached\n'
}

runner_tmux_check_worker_status() {
  local session="$1"
  local worker="$2"
  local project_root="${3:-.}"
  local worker_dir="${project_root}/.company-runtime/sessions/${session}/workers/${worker}"

  if [[ -s "${worker_dir}/compact-result.md" ]] \
    && ! grep -qE 'status:[[:space:]]*"?template-example"?' "${worker_dir}/compact-result.md" 2>/dev/null; then
    echo "done"; return 2
  fi
  if [[ -f "${worker_dir}/spawn_succeeded" ]]; then
    echo "ready"; return 0
  fi
  if [[ -f "${worker_dir}/spawn.started" ]]; then
    echo "started"; return 0
  fi
  echo "not-started"; return 1
}

runner_tmux_collect_worker_outputs() {
  local session="$1"
  local project_root="${2:-.}"
  local script_dir
  script_dir="${RUNNER_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  if [[ -f "${script_dir}/result-collector.sh" ]]; then
    bash "${script_dir}/result-collector.sh" "${session}" "${project_root}" --oneshot || true
  fi
}

runner_tmux_stop_worker() {
  # 보수적으로: pane 을 강제 kill 하지 않는다. 리더가 명시 요청할 때만 kill.
  local session="$1"
  local worker="$2"
  local project_root="${3:-.}"
  _tmux_emit "${project_root}" "worker_stopped" "${session}" \
    "worker=${worker}" "runner=tmux" "reason=noop"
}

# Phase 5 D4-B: doctor process check.
# return: 0 = ALIVE, 1 = GONE, 2 = INDETERMINATE.
# tmux: list-panes 로 워커 marker 의 pane id 매칭. 없으면 GONE.
runner_tmux_check_alive() {
  local session="$1"
  local worker="$2"
  local project_root="${3:-.}"
  local marker="${project_root}/.company-runtime/sessions/${session}/workers/${worker}/tmux-target"
  command -v tmux >/dev/null 2>&1 || return 2
  if [[ ! -f "${marker}" ]]; then
    # marker 부재 — sequential/manual 수준의 spawn.started 만 본다.
    local fb="${project_root}/.company-runtime/sessions/${session}/workers/${worker}/spawn.started"
    [[ -f "${fb}" ]] && return 0 || return 1
  fi
  local pane_id
  pane_id="$(grep -E '^pane:' "${marker}" 2>/dev/null | head -1 | sed 's/^pane://')"
  [[ -n "${pane_id}" ]] || return 2
  if tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "${pane_id}"; then
    return 0
  fi
  return 1
}

# v1.4.4 — permission-stall-watchdog 가 호출하는 표준 capture API.
# tmux 의 pane_current_command=claude 인 첫 pane 의 가시 영역을 stdout 으로 출력.
# 발견 실패 / capture 실패 시 빈 출력 + rc != 0.
runner_tmux_capture_worker_pane() {
  local _session="$1"
  local _worker="$2"
  local _project_root="${3:-.}"
  command -v tmux >/dev/null 2>&1 || return 2
  [[ -n "${TMUX:-}" ]] || return 3
  local target
  target="$(_runner_find_pane_by_proc tmux claude "${_worker}" 2>/dev/null)" || target=""
  if [[ -z "${target}" ]]; then
    return 4
  fi
  # -p stdout, -J 줄 합치지 않음 (개행 보존), 가시 영역만 (scrollback 제외).
  tmux capture-pane -p -t "${target}" 2>/dev/null
}
