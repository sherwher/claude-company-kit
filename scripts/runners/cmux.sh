#!/usr/bin/env bash
# scripts/runners/cmux.sh (v1.4.1 — experimental, contract-aligned to cmux 0.63.x)
#
# cmux runner — cmux 0.63.x 의 실제 CLI surface 에 정합. v1.3.8 어댑터는 tmux-shaped
# 가상 계약(`$CMUX` env, `cmux send-keys`, `display-message -p '#S'`, `list-sessions`)을
# 가정해 detect 가 항상 실패했다. 이번 버전은 다음 원칙을 따른다:
#   - env 가드: `$CMUX_PANEL_ID` 또는 `$CMUX_WORKSPACE_ID` 만 신뢰 (단독 `$CMUX` 없음).
#   - session id: `cmux current-workspace` 1순위 → `$CMUX_WORKSPACE_ID` (UUID) fallback.
#                 `cmux display-message -p '#S'` 는 literal 문자열 출력이므로 사용 금지.
#   - send 분리: `cmux send` (텍스트, tmux send-keys -l 등가) + `cmux send-key Enter`
#                (tmux send-keys Enter 등가). target 이 panel:* 이면 send-panel/send-key-panel.
#   - pane 자동 탐색 제한: cmux 는 process info 를 노출하지 않는다. 대신 prepare 시점의
#                list-panes snapshot 과 현재 snapshot 을 비교해 신규 surface/panel id 가
#                1개로 특정될 때 `cmux-target` 마커를 자동 등록한다. 특정 불가 시 leader 가
#                surface/panel id 를 마커에 명시 등록해야 한다.
#
# 참고: docs/design/runners/cmux.md (스펙 / 제약 / 버전 호환 표)

runner_cmux_detect() {
  # 1) cmux 바이너리 + CMUX_* env (CMUX 단독은 cmux 가 export 하지 않음)
  command -v cmux >/dev/null 2>&1 || return 1
  [[ -n "${CMUX_PANEL_ID:-}" || -n "${CMUX_WORKSPACE_ID:-}" ]] || return 1
  # 2) 실제 daemon/socket 도달성 — current-workspace 가 비-empty 면 정상.
  [[ -n "$(cmux current-workspace 2>/dev/null | head -n1)" ]] || return 1
  # 3) 어댑터가 의존하는 서브커맨드 존재 확인 (계약 회귀 차단)
  cmux list-panes --help >/dev/null 2>&1 || cmux list-panes -h >/dev/null 2>&1 || return 1
  cmux send       --help >/dev/null 2>&1 || cmux send       -h >/dev/null 2>&1 || return 1
  cmux send-key   --help >/dev/null 2>&1 || cmux send-key   -h >/dev/null 2>&1 || return 1
  return 0
}

# v1.5.6: cmux runner 는 git worktree 기반이므로 PROJECT_ROOT 가 git repo 가
# 아니면 detect 단계에서는 통과하더라도 spawn 단계에서 silent fail 한다. 이를
# 피하기 위해 명시 precheck 함수를 도입. cmux-start-worker.sh / spawn_worker
# 양쪽에서 호출. 실패 시 actionable hint 를 stderr 에 출력.
runner_cmux_precheck_git_repo() {
  local project_root="${1:-.}"
  if ! git -C "${project_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    cat >&2 <<EOF
[ERROR] cmux 러너는 git 저장소가 필요합니다 (worktree 기반 격리).
        대상 경로: ${project_root}

💡 해결:
  1) 새 저장소로 초기화:
     cd ${project_root} && git init && git add -A && git commit -m "chore: 초기 커밋"
  2) 서브 폴더에 자체 .git 이 있으면 메인 .gitignore 에 등록하거나 그대로 둡니다
     (cmux runner 는 메인 저장소만 worktree 로 만들고 서브 git 은 건드리지 않음).
  3) git 사용을 원하지 않으면 sequential 또는 tmux 러너를 사용하세요:
     company run "<topic>" --runner=sequential
EOF
    return 1
  fi
  return 0
}

runner_cmux_current_session_name() {
  command -v cmux >/dev/null 2>&1 || return 0
  [[ -n "${CMUX_PANEL_ID:-}" || -n "${CMUX_WORKSPACE_ID:-}" ]] || return 0
  # 1순위: cmux current-workspace (사람이 읽는 workspace 이름)
  local ws
  ws="$(cmux current-workspace 2>/dev/null | head -n1 | tr -d '\r' || true)"
  if [[ -n "${ws}" ]]; then
    printf '%s\n' "${ws}"
    return 0
  fi
  # fallback: workspace UUID (디렉토리는 #S 같은 가짜 슬러그보다 안전)
  printf '%s\n' "${CMUX_WORKSPACE_ID:-}"
}

_cmux_emit() {
  local project_root="$1"; shift
  local event="$1"; shift
  local session="$1"; shift
  local emit="${RUNNER_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/company-emit.sh"
  [[ -f "${emit}" ]] || return 0
  bash "${emit}" "${event}" "${session}" "${project_root}" "$@" >/dev/null 2>&1 || true
}

_cmux_list_panes_both() {
  command -v cmux >/dev/null 2>&1 || return 1
  local workspace="${CMUX_WORKSPACE_ID:-current}"
  cmux list-panes --workspace "${workspace}" --id-format both 2>/dev/null \
    || cmux list-panes --workspace "${workspace}" 2>/dev/null
}

_cmux_extract_targets() {
  awk '
    {
      for (i = 1; i <= NF; i++) {
        token = $i
        gsub(/[,;(){}"'\''\[\]]/, "", token)
        if (token ~ /^surface:[A-Za-z0-9._:-]+$/) print token
        else if (token ~ /^panel:[A-Za-z0-9._:-]+$/) print token
        else if (token ~ /^surface[A-Za-z_-]*=/) { sub(/^surface[A-Za-z_-]*=/, "surface:", token); print token }
        else if (token ~ /^panel[A-Za-z_-]*=/) { sub(/^panel[A-Za-z_-]*=/, "panel:", token); print token }
      }
    }
  ' | sed '/^surface:$/d;/^panel:$/d' | sort -u
}

_cmux_read_target_file() {
  local target_file="$1"
  [[ -f "${target_file}" ]] || return 1
  awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    /^[[:space:]]*(surface|panel):[^[:space:]]+[[:space:]]*$/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      print $0
      exit
    }
  ' "${target_file}"
}

_cmux_try_register_target() {
  local worker_dir="$1"
  local target_file="${worker_dir}/cmux-target"
  local before_file="${worker_dir}/cmux-panes.before"
  local before_targets current_targets new_targets new_surfaces count target

  command -v cmux >/dev/null 2>&1 || return 1
  [[ -n "${CMUX_PANEL_ID:-}" || -n "${CMUX_WORKSPACE_ID:-}" ]] || return 1
  current_targets="$(_cmux_list_panes_both | _cmux_extract_targets || true)"
  [[ -n "${current_targets}" ]] || return 1

  if [[ -f "${before_file}" ]]; then
    before_targets="$(_cmux_extract_targets < "${before_file}" || true)"
    new_targets="$(comm -13 \
      <(printf '%s\n' "${before_targets}" | sed '/^$/d' | sort -u) \
      <(printf '%s\n' "${current_targets}" | sed '/^$/d' | sort -u) || true)"
  else
    new_targets="${current_targets}"
  fi

  new_surfaces="$(printf '%s\n' "${new_targets}" | grep '^surface:' || true)"
  count="$(printf '%s\n' "${new_surfaces}" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "${count}" == "1" ]]; then
    target="$(printf '%s\n' "${new_surfaces}" | sed -n '1p')"
    printf '%s\n' "${target}" > "${target_file}"
    return 0
  fi

  count="$(printf '%s\n' "${new_targets}" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "${count}" == "1" ]]; then
    target="$(printf '%s\n' "${new_targets}" | sed -n '1p')"
    printf '%s\n' "${target}" > "${target_file}"
    return 0
  fi
  return 1
}

runner_cmux_spawn_worker() {
  # cmux 러너에서 'spawn' 은 실제 pane 생성이 아니라 '리더가 pane 을 띄우도록 요청서를
  # 드롭한 상태를 canonical 이벤트로 확정 짓는 것' 이다. 실제 pane 검증은
  # verify-worker-spawn.sh 가 담당한다 (tmux 와 동일).
  #
  # v1.5.4 운영 노트 — 리더가 pane 을 띄울 때 흔히 빠뜨리는 단계:
  #   1) `cmux new-split <dir>` 후 surface id 를 cmux-target 마커에 기록.
  #   2) pane 안에서 `cd <worktree> && claude` 로 워커 기동.
  #   3) `runner_cmux_send_worker_message` 로 worker-request.md 를 첫 메시지로 전송
  #      (이 함수가 _runner_safe_send_keys 를 거쳐 자동으로 Enter 까지 발송).
  # 리더가 직접 `cmux send "..."` 만 호출하면 prompt 박스에 입력만 되고 submit 이
  # 안 되거나, plan-mode interview 메뉴에 갇혀 compact-plan 작성으로 넘어가지 않는다.
  # 항상 send_worker_message API 를 거쳐야 Enter + literal-send 정합화가 보장된다.
  local session="$1"
  local worker="$2"
  local project_root="${3:-.}"
  local worker_dir="${project_root}/.company-runtime/sessions/${session}/workers/${worker}"
  local started_marker="${worker_dir}/spawn.started"

  # Phase 2 (2026-05-13) D1-B: pre-spawn failure (worker dir missing / git precheck) 는
  # registry record 가 아직 없으므로 registry ignore (pre-registry signal).
  # legacy events.jsonl 의 spawn_failed 만 유지.
  [[ -d "${worker_dir}" ]] || {
    echo "cmux runner: worker dir missing (${worker_dir})" >&2
    _cmux_emit "${project_root}" "spawn_failed" "${session}" \
      "worker=${worker}" "runner=cmux" "reason=worker-dir-missing"
    return 2
  }

  # v1.5.6: git repo precheck — 실패 시 명확한 메시지 + spawn_failed emit
  if ! runner_cmux_precheck_git_repo "${project_root}" 2>&1; then
    _cmux_emit "${project_root}" "spawn_failed" "${session}" \
      "worker=${worker}" "runner=cmux" "reason=not-a-git-repo"
    return 6
  fi

  # 멱등: 이미 started 마커가 있으면 재-emit skip
  if [[ -f "${started_marker}" ]]; then
    return 0
  fi

  _cmux_emit "${project_root}" "spawn_attempted" "${session}" \
    "worker=${worker}" "runner=cmux"

  _cmux_try_register_target "${worker_dir}" >/dev/null 2>&1 || true

  # ── Phase 2 (2026-05-13): registry preflight + side effect 순서 재정렬 ──
  # 결정문: docs/decisions/2026-05-12-worker-registry-phase2.md v0.5 D1-B
  local REGISTRY_LIB="${RUNNER_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/worker-registry-lib.sh"
  if [[ -f "${REGISTRY_LIB}" ]]; then
    # shellcheck disable=SC1090
    source "${REGISTRY_LIB}"
    registry_init "${project_root}"

    if ! command -v jq >/dev/null 2>&1; then
      echo "cmux runner: jq is required for worker registry." >&2
      return 3
    fi

    local worker_id="wkr-${session}-${worker}"
    # runner_handle: surface:<id> (Phase 0 D3-B 동결값, prefix 없음)
    # surface_id 는 cmux 의 preflight.json 또는 cmux-target marker 에서 추출.
    local surface_id="unknown"
    local preflight="${project_root}/.company-runtime/sessions/${session}/preflight.json"
    if [[ -f "${preflight}" ]]; then
      surface_id="$(jq -r '.cmux_surface_id // empty' "${preflight}" 2>/dev/null || true)"
      [[ -n "${surface_id}" ]] || surface_id="unknown"
    fi

    local started_payload
    started_payload="$(jq -S -c -n \
      --arg rh "surface:${surface_id}" \
      --arg wt "${worker_dir}" \
      --arg topic "${worker}" \
      --arg role "primary" \
      --arg sid "${session}" \
      '{runner_handle:$rh, worktree_path:$wt, branch:null, topic:$topic, worker_role:$role, session_id:$sid}')"

    # side effect 1: registry append spawn_started (post-spawn 영역 진입점)
    if ! registry_append_event "${project_root}" spawn_started "${worker_id}" cmux "${started_payload}"; then
      echo "cmux runner: registry append (spawn_started) failed — marker/legacy not emitted" >&2
      return 4
    fi
  fi

  # side effect 2: marker file write
  printf 'runner: cmux\nstarted_at: %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${started_marker}"

  # side effect 3: legacy emit
  _cmux_emit "${project_root}" "spawn_started" "${session}" \
    "worker=${worker}" "runner=cmux"
}

runner_cmux_send_worker_message() {
  local session="$1"
  local worker="$2"
  local project_root="${3:-.}"
  local message="${4:-}"

  [[ -n "${message}" ]] || return 0
  command -v cmux >/dev/null 2>&1 || { echo "cmux runner: cmux not found" >&2; return 2; }
  [[ -n "${CMUX_PANEL_ID:-}" || -n "${CMUX_WORKSPACE_ID:-}" ]] || {
    echo "cmux runner: not inside a cmux workspace — cannot send keys" >&2
    return 3
  }

  # cmux 는 process 기반 자동 탐색을 지원하지 않는다 (tmux 의 pane_current_command 등가
  # API 미존재). leader 가 spawn 시점에 surface/panel id 를 cmux-target 마커에 기록해야 한다.
  local target_file="${project_root}/.company-runtime/sessions/${session}/workers/${worker}/cmux-target"
  local target=""
  target="$(_cmux_read_target_file "${target_file}" 2>/dev/null | tr -d '\r' || true)"
  if [[ -z "${target}" ]]; then
    _cmux_try_register_target "$(dirname "${target_file}")" >/dev/null 2>&1 || true
    target="$(_cmux_read_target_file "${target_file}" 2>/dev/null | tr -d '\r' || true)"
  fi
  if [[ -z "${target}" ]]; then
    echo "cmux runner: no cmux target recorded for worker=${worker}" >&2
    echo "             expected ${target_file} containing 'surface:<id>' or 'panel:<id>'" >&2
    return 4
  fi

  # literal 전송 강제 — C-c 등 제어 시퀀스 오해석 방지
  _runner_safe_send_keys cmux "${target}" "${message}"
}

runner_cmux_check_worker_status() {
  local session="$1"
  local worker="$2"
  local project_root="${3:-.}"
  local worker_dir="${project_root}/.company-runtime/sessions/${session}/workers/${worker}"

  if [[ -s "${worker_dir}/compact-result.md" ]] \
    && ! grep -qE 'status:[[:space:]]*"?template-example"?' "${worker_dir}/compact-result.md" 2>/dev/null; then
    echo "done"; return 2
  fi
  if [[ -s "${worker_dir}/compact-plan.md" ]]; then
    echo "plan-ready"; return 0
  fi
  if [[ -f "${worker_dir}/spawn_succeeded" ]]; then
    echo "ready"; return 0
  fi
  if [[ -f "${worker_dir}/spawn.started" ]]; then
    echo "started"; return 0
  fi
  echo "not-started"; return 1
}

runner_cmux_collect_worker_outputs() {
  local session="$1"
  local project_root="${2:-.}"
  local script_dir
  script_dir="${RUNNER_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  if [[ -f "${script_dir}/result-collector.sh" ]]; then
    bash "${script_dir}/result-collector.sh" "${session}" "${project_root}" --oneshot || true
  fi
}

runner_cmux_stop_worker() {
  # 보수적: pane 을 강제 kill 하지 않는다. 리더가 명시 요청할 때만 kill.
  local session="$1"
  local worker="$2"
  local project_root="${3:-.}"
  _cmux_emit "${project_root}" "worker_stopped" "${session}" \
    "worker=${worker}" "runner=cmux" "reason=noop"
}

# Phase 5 D4-B: doctor process check.
# return: 0 = ALIVE, 1 = GONE, 2 = INDETERMINATE.
# cmux: cmux-target 의 surface id → cmux list-surfaces 매칭. 없으면 GONE.
runner_cmux_check_alive() {
  local session="$1"
  local worker="$2"
  local project_root="${3:-.}"
  local target_file="${project_root}/.company-runtime/sessions/${session}/workers/${worker}/cmux-target"
  command -v cmux >/dev/null 2>&1 || return 2
  [[ -f "${target_file}" ]] || return 1
  local target
  target="$(grep -E '^(surface|panel):' "${target_file}" 2>/dev/null | head -1)"
  [[ -n "${target}" ]] || return 2
  local sid="${target#surface:}"
  sid="${sid#panel:}"
  if cmux list-surfaces 2>/dev/null | grep -qE "(^|[^[:alnum:]])${sid}([^[:alnum:]]|$)"; then
    return 0
  fi
  return 1
}

# Interaction Mode — Gemini UX 권고.
# tmux 와 동일하게 "사용자가 cmux 창을 동시에 보고 있다" 전제.
runner_cmux_interaction_mode() {
  printf 'attached\n'
}

# v1.4.4 — permission-stall-watchdog 가 호출하는 표준 capture API.
# cmux 의 worker pane (cmux-target 마커에 기록된 surface/panel id) 의 가시 영역을
# stdout 으로 출력. cmux 0.63.x 의 tmux compatibility command `capture-pane` 사용.
# 발견 실패 / capture 실패 시 빈 출력 + rc != 0.
runner_cmux_capture_worker_pane() {
  local _session="$1"
  local _worker="$2"
  local _project_root="${3:-.}"
  command -v cmux >/dev/null 2>&1 || return 2
  [[ -n "${CMUX_PANEL_ID:-}" || -n "${CMUX_WORKSPACE_ID:-}" ]] || return 3
  local target_file="${_project_root}/.company-runtime/sessions/${_session}/workers/${_worker}/cmux-target"
  local target
  target="$(_cmux_read_target_file "${target_file}" 2>/dev/null | tr -d '\r' || true)"
  if [[ -z "${target}" ]]; then
    _cmux_try_register_target "$(dirname "${target_file}")" >/dev/null 2>&1 || true
    target="$(_cmux_read_target_file "${target_file}" 2>/dev/null | tr -d '\r' || true)"
  fi
  [[ -n "${target}" ]] || return 4
  case "${target}" in
    surface:*)
      cmux capture-pane --surface "${target#surface:}" 2>/dev/null
      ;;
    panel:*)
      # cmux capture-pane 는 surface 단위. panel 인 경우 첫 surface 추정.
      cmux capture-pane --workspace "${CMUX_WORKSPACE_ID:-current}" 2>/dev/null
      ;;
    *) return 5 ;;
  esac
}
