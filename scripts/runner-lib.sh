#!/usr/bin/env bash
# scripts/runner-lib.sh (v1.3.7 신규)
#
# 목적: company 템플릿의 워커 실행 환경을 러너(runner) 단위로 추상화한다.
#       기존에는 tmux 가 사실상 핵심 운영 모델이어서 tmux 밖에서 `company run`
#       을 실행하면 조용히 멈추거나 pane 감시 로직이 타임아웃되는 문제가 있었다.
#       이제 tmux 는 한 어댑터일 뿐이며, 기본 동작은 "사용 가능한 러너 자동 선택,
#       불가 시 sequential 로 폴백"이다.
#
# 용어:
#   - 러너(runner): 워커 pane/프로세스를 실제로 띄우고 메시지를 주고받는 실행기.
#                   adapter file: scripts/runners/<name>.sh
#   - 어댑터(adapter): 러너 구현체. runner-lib 가 6 개의 공용 API 를 dispatch 한다.
#                      API: detect / spawn_worker / send_worker_message
#                           check_worker_status / collect_worker_outputs / stop_worker
#
# 계약 (bash 3.2 호환):
#   - 어댑터는 `runner_<name>_<op>` 형식의 shell 함수를 정의한다.
#     예: runner_tmux_detect, runner_sequential_spawn_worker ...
#   - 이 스크립트를 source 하면 resolve_runner / runner_call 두 진입점이 제공된다.
#   - 어댑터 로드는 runner_load <name> 으로 명시 호출한다 (idempotent).
#
# 비목표:
#   - subprocess fork 기반 dispatch (성능/상태 공유 비용 증가).
#   - 기존 events.jsonl 포맷 변경 (호환 유지).
#
# 관련 설계 문서: docs/design/RUNNER_ABSTRACTION.md

set -euo pipefail

# 이중 source 방지
if [[ "${_COMPANY_RUNNER_LIB_LOADED:-0}" == "1" ]]; then
  return 0 2>/dev/null || true
fi
_COMPANY_RUNNER_LIB_LOADED=1

RUNNER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_ADAPTERS_DIR="${RUNNER_LIB_DIR}/runners"
if [[ -f "${RUNNER_LIB_DIR}/cmux-lib.sh" ]]; then
  # shellcheck disable=SC1090
  source "${RUNNER_LIB_DIR}/cmux-lib.sh"
fi

# 알려진 어댑터 목록. 'unavailable' 으로 표시된 것은 detect 스켈레톤만 있고
# 실제 spawn/send/status 는 구현되지 않았음을 명시한다.
RUNNER_KNOWN="sequential tmux manual cmux codex-native"

# v1.3.7: 단순 implemented/slot 2-state 모델.
# v1.3.8: 상태 3-state 모델 도입 (stable | experimental | slot).
#   - stable       : auto 선택/폴백 대상. 기본 사용 러너.
#   - experimental : 어댑터 구현은 완료됐으나 로컬 환경에 따라 계약이 흔들릴 수 있어
#                    사용자가 --allow-experimental 로 '명시 opt-in' 해야만 실제 선택된다.
#   - slot         : 어댑터 슬롯만 있고 spawn/send 미구현. detect=1 이므로 폴백 경로로만 관찰된다.
# RUNNER_IMPLEMENTED 는 v1.3.7 호환을 위해 stable+experimental 합집합으로 남긴다.
RUNNER_STATES_stable="sequential tmux manual"
RUNNER_STATES_experimental="cmux"
RUNNER_STATES_slot="codex-native"
RUNNER_IMPLEMENTED="${RUNNER_STATES_stable}${RUNNER_STATES_experimental:+ ${RUNNER_STATES_experimental}}"

# ─────────────────────────────────────────────────────────────────────────────
# runner_load <name>
#   어댑터 파일을 source 한다. 실패 시 stderr 에 이유 기록 후 비 0 반환.
# ─────────────────────────────────────────────────────────────────────────────
runner_load() {
  local name="$1"
  local adapter="${RUNNER_ADAPTERS_DIR}/${name}.sh"
  if [[ ! -f "${adapter}" ]]; then
    echo "runner-lib: unknown runner adapter '${name}' (file missing: ${adapter})" >&2
    return 2
  fi
  # shellcheck disable=SC1090
  source "${adapter}"
}

# ─────────────────────────────────────────────────────────────────────────────
# runner_has_fn <runner> <op>
#   해당 어댑터가 op 함수를 정의했는지 확인. 0 = yes, 1 = no.
# ─────────────────────────────────────────────────────────────────────────────
runner_has_fn() {
  local runner="$1"
  local op="$2"
  local fn="runner_${runner//-/_}_${op}"
  declare -f "${fn}" >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# runner_call <runner> <op> [args...]
#   dispatcher. 어댑터 함수를 호출한다. 미구현 op 는 비 0 반환 + 메시지.
# ─────────────────────────────────────────────────────────────────────────────
runner_call() {
  local runner="$1"
  local op="$2"
  shift 2
  local fn="runner_${runner//-/_}_${op}"
  if ! declare -f "${fn}" >/dev/null 2>&1; then
    echo "runner-lib: '${runner}' does not implement '${op}'" >&2
    return 64
  fi
  "${fn}" "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# runner_detect <runner>
#   어댑터가 사용 가능한지 판정. 0 = available, 1 = unavailable.
#   detect 함수가 없으면 unavailable 취급.
# ─────────────────────────────────────────────────────────────────────────────
runner_detect() {
  local runner="$1"
  runner_load "${runner}" 2>/dev/null || return 1
  runner_has_fn "${runner}" detect || return 1
  runner_call "${runner}" detect >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# runner_state <name>
#   러너의 lifecycle 상태를 stable / experimental / slot / unknown 중 하나로 반환.
#   stdout 에 상태 문자열을 출력하고, 미지의 러너면 "unknown".
# ─────────────────────────────────────────────────────────────────────────────
runner_state() {
  local name="$1"
  if echo " ${RUNNER_STATES_stable} " | grep -q " ${name} "; then
    printf 'stable\n'; return 0
  fi
  if [[ -n "${RUNNER_STATES_experimental}" ]] \
     && echo " ${RUNNER_STATES_experimental} " | grep -q " ${name} "; then
    printf 'experimental\n'; return 0
  fi
  if echo " ${RUNNER_STATES_slot} " | grep -q " ${name} "; then
    printf 'slot\n'; return 0
  fi
  printf 'unknown\n'
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# resolve_runner [--runner=<name>] [--no-fallback] [--allow-experimental]
#   반환: RUNNER_SELECTED, RUNNER_SOURCE, RUNNER_FALLBACK_REASON,
#         RUNNER_SELECTED_STATE, RUNNER_ALLOW_EXPERIMENTAL 전역 세팅.
#
#   우선순위:
#     1) --runner=<name>  (flag explicit)
#     2) COMPANY_RUNNER   (env explicit)
#     3) auto-detect      (tmux in TMUX → tmux, else → sequential)
#     4) fallback         (explicit 실패 시 sequential 로 강등, --no-fallback 이면 실패)
#
#   상태별 추가 규칙:
#     - slot 러너를 명시 선택 시 → detect 는 항상 실패하므로 기존과 동일한 폴백 경로.
#       (사용자가 오타/미구현 러너를 가리켰을 때 graceful 폴백을 유지해 UX 를 보호.)
#     - experimental 러너를 명시 선택 시 → --allow-experimental (또는
#       COMPANY_ALLOW_EXPERIMENTAL=1) 없으면 hard fail (rc=5). 자동 폴백 하지 않는다.
#       '실험적' 이라는 정보가 로그에 남기 전에 사용자가 의도를 드러내도록 강제한다.
#     - stable 러너는 v1.3.7 과 완전히 동일하게 동작한다.
#
#   RUNNER_SOURCE 값: flag | env | auto | fallback
#   RUNNER_SELECTED_STATE: stable | experimental (실제 선택된 러너의 상태)
#   RUNNER_ALLOW_EXPERIMENTAL: 0/1 (사용자가 명시 opt-in 했는지)
# ─────────────────────────────────────────────────────────────────────────────
resolve_runner() {
  local requested=""
  local no_fallback=0
  local allow_experimental=0

  # env 기반 opt-in 도 허용 (CI / 스크립트 친화)
  if [[ "${COMPANY_ALLOW_EXPERIMENTAL:-0}" == "1" ]]; then
    allow_experimental=1
  fi

  while (( $# > 0 )); do
    case "$1" in
      --runner=*)             requested="${1#*=}" ;;
      --runner)               shift; requested="${1:-}" ;;
      --no-fallback)          no_fallback=1 ;;
      --allow-experimental)   allow_experimental=1 ;;
      *)                      ;;
    esac
    shift || true
  done

  RUNNER_SELECTED=""
  RUNNER_SOURCE=""
  RUNNER_FALLBACK_REASON=""
  RUNNER_SELECTED_STATE=""
  RUNNER_ALLOW_EXPERIMENTAL="${allow_experimental}"
  # v1.4.4: experimental_grant — opt-in 신호의 출처를 기록. stable 승격 판단에서
  # 'flag/env (의식적 opt-in)' vs 'inside-context (사용자가 이미 그 컨텍스트
  # 안에 있음)' 를 구분하기 위함. 자동 set과 명시 동의의 신호를 섞지 않는다.
  # 값: flag | env | inside-context | "" (해당 없음)
  RUNNER_EXPERIMENTAL_GRANT=""
  if [[ "${allow_experimental}" == "1" ]]; then
    if [[ "${COMPANY_ALLOW_EXPERIMENTAL:-0}" == "1" ]]; then
      RUNNER_EXPERIMENTAL_GRANT="env"
    else
      RUNNER_EXPERIMENTAL_GRANT="flag"
    fi
  fi

  local candidate=""
  local source=""

  if [[ -n "${requested}" ]]; then
    candidate="${requested}"
    source="flag"
  elif [[ -n "${COMPANY_RUNNER:-}" ]]; then
    candidate="${COMPANY_RUNNER}"
    source="env"
  fi

  if [[ -n "${candidate}" ]]; then
    # 1·2) explicit 경로
    if ! echo " ${RUNNER_KNOWN} " | grep -q " ${candidate} "; then
      echo "resolve_runner: unknown runner '${candidate}' (known: ${RUNNER_KNOWN})" >&2
      return 2
    fi

    local _state
    _state="$(runner_state "${candidate}")"

    # experimental 러너는 명시 opt-in 이 없으면 detect 를 시도하지 않고 즉시 실패.
    # (detect 가 우연히 succeeded 되더라도 사용자 동의 없이 실행되지 않도록)
    if [[ "${_state}" == "experimental" && "${allow_experimental}" != "1" ]]; then
      cat >&2 <<EOF
resolve_runner: '${candidate}' 러너는 현재 **실험 단계(experimental)** 입니다.
  → 사용하려면 '--allow-experimental' 플래그 또는
    COMPANY_ALLOW_EXPERIMENTAL=1 환경 변수로 opt-in 해 주세요.
  → 안정 러너 (${RUNNER_STATES_stable}) 는 플래그 없이 그대로 사용할 수 있습니다.
EOF
      RUNNER_SELECTED=""
      RUNNER_SOURCE="${source}"
      RUNNER_FALLBACK_REASON="${candidate}-experimental-without-optin"
      RUNNER_EXPERIMENTAL_GRANT=""
      return 5
    fi

    if runner_detect "${candidate}"; then
      RUNNER_SELECTED="${candidate}"
      RUNNER_SOURCE="${source}"
      RUNNER_SELECTED_STATE="${_state}"
      return 0
    fi
    # explicit 인데 detect 실패
    if [[ "${no_fallback}" == "1" ]]; then
      echo "resolve_runner: runner '${candidate}' not available and --no-fallback set" >&2
      RUNNER_SELECTED=""
      RUNNER_SOURCE="${source}"
      RUNNER_FALLBACK_REASON="${candidate}-not-available"
      return 3
    fi
    # fallback → sequential. grant 는 sequential 에 무의미하므로 클리어.
    RUNNER_SELECTED="sequential"
    RUNNER_SOURCE="fallback"
    RUNNER_FALLBACK_REASON="${candidate}-not-available"
    RUNNER_SELECTED_STATE="stable"
    RUNNER_EXPERIMENTAL_GRANT=""
    # sequential 이 항상 사용 가능하다고 믿지만 안전하게 한 번 더 확인
    runner_detect "sequential" || {
      echo "resolve_runner: sequential runner itself unavailable — environment broken" >&2
      return 4
    }
    return 0
  fi

  # 3) auto-detect
  # 우선순위:
  #   a) tmux 안 ($TMUX) + tmux detect ok → tmux 자동 선택 (변동 없음)
  #   b) cmux workspace 안 ($CMUX_PANEL_ID|$CMUX_WORKSPACE_ID) + cmux detect ok →
  #      cmux 자동 선택 (v1.4.4 신규). 사용자가 이미 cmux 컨텍스트 안에서 명령을
  #      친 시점이 의식적 opt-in 신호이므로 --allow-experimental 게이트는 면제하되,
  #      experimental_grant=inside-context 로 자동 set 과 명시 opt-in 을 구분 기록.
  #      "사용자에게 다른 워크스페이스/세션 열라"고 강요하지 않고 컨텍스트 안에서
  #      그대로 동작시키는 게 본 분기의 목적이다.
  #   c) 둘 다 밖 → sequential 폴백. 컨텍스트 변경을 강요하지 않고 환경별 actionable
  #      hint 만 banner 에 노출.
  if runner_detect "tmux" && [[ -n "${TMUX:-}" ]]; then
    RUNNER_SELECTED="tmux"
    RUNNER_SOURCE="auto"
    RUNNER_SELECTED_STATE="stable"
    return 0
  fi
  if [[ -n "${CMUX_PANEL_ID:-}${CMUX_WORKSPACE_ID:-}" ]] && runner_detect "cmux"; then
    RUNNER_SELECTED="cmux"
    RUNNER_SOURCE="auto"
    RUNNER_SELECTED_STATE="experimental"
    RUNNER_ALLOW_EXPERIMENTAL="1"
    RUNNER_EXPERIMENTAL_GRANT="inside-context"
    return 0
  fi
  RUNNER_SELECTED="sequential"
  RUNNER_SOURCE="auto"
  RUNNER_SELECTED_STATE="stable"
  # cmux env 는 있으나 detect 실패 (daemon down 등) — opt-in 강제하지 말고 진단 hint
  if [[ -n "${CMUX_PANEL_ID:-}${CMUX_WORKSPACE_ID:-}" ]] && command -v cmux >/dev/null 2>&1; then
    RUNNER_FALLBACK_REASON="cmux-detected-but-unhealthy"
  elif command -v tmux >/dev/null 2>&1; then
    RUNNER_FALLBACK_REASON="tmux-installed-but-not-attached"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# runner_is_implemented <name>
#   '알려진' 과 '구현된' 을 구분. v1.3.8 에서 stable/experimental 은 구현, slot 은 미구현.
# ─────────────────────────────────────────────────────────────────────────────
runner_is_implemented() {
  local name="$1"
  echo " ${RUNNER_IMPLEMENTED} " | grep -q " ${name} "
}

# ─────────────────────────────────────────────────────────────────────────────
# runner_is_experimental <name>  →  rc 0/1
# ─────────────────────────────────────────────────────────────────────────────
runner_is_experimental() {
  local name="$1"
  [[ -z "${RUNNER_STATES_experimental}" ]] && return 1
  echo " ${RUNNER_STATES_experimental} " | grep -q " ${name} "
}

# ─────────────────────────────────────────────────────────────────────────────
# runner_parallel_available <name>
#   true/false 문자열 반환 (JSON 에 그대로 싣기 위함).
# ─────────────────────────────────────────────────────────────────────────────
runner_parallel_available() {
  case "$1" in
    tmux|cmux) echo "true" ;;
    *)         echo "false" ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# runner_current_session_name
#   현재 러너 컨텍스트에서 세션명을 추론한다. tmux 면 tmux session name,
#   그 외면 빈 문자열. 기존 스크립트들이 `tmux display-message -p '#S'` 를
#   직접 호출하던 것을 이 함수로 대체하기 위함.
# ─────────────────────────────────────────────────────────────────────────────
runner_current_session_name() {
  local runner="${1:-${RUNNER_SELECTED:-}}"
  if [[ -z "${runner}" ]]; then
    return 0
  fi
  if runner_has_fn "${runner}" current_session_name; then
    runner_call "${runner}" current_session_name
    return 0
  fi
  # default: tmux fallback (compat with legacy scripts)
  if [[ "${runner}" == "tmux" ]] && command -v tmux >/dev/null 2>&1 && [[ -n "${TMUX:-}" ]]; then
    tmux display-message -p '#S' 2>/dev/null || printf ''
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# runner_probe_session_name
#   resolve_runner *이전* 단계에서 SESSION_ID 자동 감지를 위해 호출한다.
#   stable + experimental 러너 중 'attached 류' (세션명 개념이 있는 어댑터) 만
#   순차로 detect → current_session_name 폴링하고, 첫 비-빈 결과를 반환한다.
#
#   왜 필요한가:
#     - prepare-session.sh / prepare-worker.sh / run-session.sh 는 SESSION_ID 가
#       정해져야 .company-runtime/sessions/<sid>/ 경로를 만들 수 있고, 그 안에
#       preflight.json 이 쓰여져 비로소 RUNNER_SELECTED 가 확정된다.
#     - 즉 SESSION_ID 자동 감지는 resolve_runner 의 *입력*이지 *출력*이 아니다.
#     - v1.3.7~v1.3.8 까지는 이 단계에서 $TMUX 만 직접 폴링했고, cmux 안에서
#       실행해도 SESSION_ID 가 안 잡혀 사용자에게 tmux-only 안내가 노출됐다.
#
#   출력 (성공 시 stdout 두 줄):
#     line 1: runner name (tmux | cmux | …)
#     line 2: session name
#   반환:
#     0 = success, 1 = no probe matched
#
#   실험 러너(cmux 등) 는 detect 가 통과하면 폴링 후보에 포함된다. 'opt-in 검증'
#   은 resolve_runner 가 별도로 책임지므로 여기서는 건드리지 않는다 — 단지
#   '세션명 자동 감지' 만 제공할 뿐, 실제 실행 러너 결정은 resolve_runner 가 한다.
# ─────────────────────────────────────────────────────────────────────────────
runner_probe_session_name() {
  local r name
  for r in ${RUNNER_STATES_stable} ${RUNNER_STATES_experimental}; do
    case "${r}" in
      sequential|manual) continue ;;  # 세션명 개념 없음
    esac
    runner_load "${r}" 2>/dev/null || continue
    runner_has_fn "${r}" detect || continue
    runner_call "${r}" detect >/dev/null 2>&1 || continue
    runner_has_fn "${r}" current_session_name || continue
    name="$(runner_call "${r}" current_session_name 2>/dev/null || true)"
    if [[ -n "${name}" ]]; then
      printf '%s\n%s\n' "${r}" "${name}"
      return 0
    fi
  done
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# runner_write_preflight <project_root> <session_id>
#   resolve_runner 직후 호출. preflight.json 을 기록한다.
# ─────────────────────────────────────────────────────────────────────────────
runner_write_preflight() {
  local project_root="$1"
  local session_id="$2"
  local dir="${project_root}/.company-runtime/sessions/${session_id}"
  local out="${dir}/preflight.json"
  mkdir -p "${dir}"

  local parallel
  parallel="$(runner_parallel_available "${RUNNER_SELECTED:-sequential}")"
  local impl="false"
  if runner_is_implemented "${RUNNER_SELECTED:-}"; then impl="true"; fi
  local state="${RUNNER_SELECTED_STATE:-}"
  if [[ -z "${state}" ]]; then
    state="$(runner_state "${RUNNER_SELECTED:-sequential}" 2>/dev/null || echo unknown)"
  fi
  local allow_exp="${RUNNER_ALLOW_EXPERIMENTAL:-0}"
  local grant="${RUNNER_EXPERIMENTAL_GRANT:-}"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # v1.4.5: leader-wake 가시성 — watchdog 와 UserPromptSubmit hook 의 설치 상태.
  local kit_root="${RUNNER_LIB_DIR}"
  local lww_state="absent"
  if [[ -x "${kit_root}/leader-wake-watchdog.sh" ]]; then
    lww_state="present"
  fi
  local hook_state="missing"
  # hook 은 user 가 .claude/settings.json 에 등록해야 활성. 스크립트 존재 자체만 보고.
  if [[ -x "${kit_root}/hooks/claude-userpromptsubmit-leader-wake.sh" ]]; then
    hook_state="installed"
  fi

  # schema: version=4 (v1.4.5) — leader_wake_watchdog / claude_userpromptsubmit_hook 추가 (additive).
  # v3 (v1.4.4): experimental_grant.
  # v2 (v1.3.8): state / allow_experimental.
  # v1: runner / runner_source / fallback_reason / parallel_available /
  #     runner_implemented / capabilities / warnings / created_at.
  # 기존 파서는 상위 필드가 늘어나도 깨지지 않는다 (v4 도 v2/v3 와 호환).
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg v "4" \
      --arg runner "${RUNNER_SELECTED:-sequential}" \
      --arg src "${RUNNER_SOURCE:-auto}" \
      --arg reason "${RUNNER_FALLBACK_REASON:-}" \
      --arg parallel "${parallel}" \
      --arg impl "${impl}" \
      --arg state "${state}" \
      --arg allow_exp "${allow_exp}" \
      --arg grant "${grant}" \
      --arg lww "${lww_state}" \
      --arg hook "${hook_state}" \
      --arg ts "${now}" \
      '{
        version: ($v | tonumber),
        runner: $runner,
        runner_source: $src,
        fallback_reason: (if $reason == "" then null else $reason end),
        parallel_available: ($parallel == "true"),
        runner_implemented: ($impl == "true"),
        state: $state,
        allow_experimental: ($allow_exp == "1"),
        experimental_grant: (if $grant == "" then null else $grant end),
        leader_wake_watchdog: $lww,
        claude_userpromptsubmit_hook: $hook,
        capabilities: ["detect","spawn_worker","send_worker_message","check_worker_status","collect_worker_outputs","stop_worker"],
        warnings: [],
        created_at: $ts
      }' > "${out}"
  else
    cat > "${out}" <<EOF
{
  "version": 4,
  "runner": "${RUNNER_SELECTED:-sequential}",
  "runner_source": "${RUNNER_SOURCE:-auto}",
  "fallback_reason": $(if [[ -n "${RUNNER_FALLBACK_REASON:-}" ]]; then printf '"%s"' "${RUNNER_FALLBACK_REASON}"; else printf 'null'; fi),
  "parallel_available": ${parallel},
  "runner_implemented": ${impl},
  "state": "${state}",
  "allow_experimental": $(if [[ "${allow_exp}" == "1" ]]; then printf 'true'; else printf 'false'; fi),
  "experimental_grant": $(if [[ -n "${grant}" ]]; then printf '"%s"' "${grant}"; else printf 'null'; fi),
  "leader_wake_watchdog": "${lww_state}",
  "claude_userpromptsubmit_hook": "${hook_state}",
  "capabilities": ["detect","spawn_worker","send_worker_message","check_worker_status","collect_worker_outputs","stop_worker"],
  "warnings": [],
  "created_at": "${now}"
}
EOF
  fi

  printf '%s\n' "${out}"
}

# ─────────────────────────────────────────────────────────────────────────────
# runner_banner
#   stdout 에 사용자 친화적 러너 알림을 1–2 줄로 출력. Gemini UX 권고 반영.
# ─────────────────────────────────────────────────────────────────────────────
runner_banner() {
  local runner="${RUNNER_SELECTED:-sequential}"
  local src="${RUNNER_SOURCE:-auto}"
  local reason="${RUNNER_FALLBACK_REASON:-}"
  local state="${RUNNER_SELECTED_STATE:-}"
  [[ -n "${state}" ]] || state="$(runner_state "${runner}" 2>/dev/null || echo stable)"

  local grant="${RUNNER_EXPERIMENTAL_GRANT:-}"

  case "${runner}" in
    sequential)
      if [[ "${src}" == "fallback" ]]; then
        echo "[WARN] 요청한 러너를 감지하지 못해 '순차 실행(Sequential)' 으로 전환합니다. (원인: ${reason})" >&2
      elif [[ "${src}" == "auto" ]]; then
        echo "[INFO] 현재 환경에서 병렬 러너가 자동 선택되지 않아 '순차 실행(Sequential)' 모드로 시작합니다." >&2
        case "${reason}" in
          cmux-detected-but-unhealthy)
            echo "       cmux env 는 감지됐지만 cmux daemon 응답 또는 서브커맨드 계약이 깨져 자동 선택을 보류했습니다." >&2
            echo "       복구: 'cmux ping' 으로 daemon 도달성 확인 → 안 되면 cmux 재기동, 그 뒤 동일 명령 재실행." >&2
            ;;
          tmux-installed-but-not-attached)
            echo "       tmux 가 설치돼 있지만 세션 안이 아닙니다. 'tmux new -s company' 로 진입한 뒤 동일 명령을 다시 실행하세요." >&2
            ;;
          *)
            echo "       병렬 워커가 필요하면 tmux 세션 또는 cmux workspace 안에서 동일 명령을 실행하세요 (자동으로 병렬 모드 활성화)." >&2
            ;;
        esac
      else
        echo "[INFO] '순차 실행(Sequential)' 러너로 진행합니다. (${src})" >&2
      fi
      ;;
    tmux)
      echo "[INFO] tmux 러너 선택 — 기존 pane 기반 병렬 워커 흐름을 사용합니다. (${src})" >&2
      ;;
    cmux)
      if [[ "${grant}" == "inside-context" ]]; then
        echo "[INFO] cmux 러너 자동 감지 — 현재 workspace 안에서 하위 panel 로 워커를 실행합니다. (opt-in 환경변수 불필요)" >&2
      else
        echo "[INFO] cmux 러너 선택 — experimental 병렬 워커 흐름을 사용합니다. (${src})" >&2
      fi
      ;;
    manual)
      echo "[INFO] 'manual' 러너 — 준비만 하고 다음 명령을 사용자가 직접 실행합니다. (${src})" >&2
      ;;
    *)
      echo "[INFO] 러너: ${runner} (${src})" >&2
      ;;
  esac

  # v1.5.6: 워커 실행 모드 1행 — 사용자가 "워커가 어디서 도는지" 한눈에 파악.
  # tmux/cmux 구분은 내부 디테일이므로 "별도 pane (멀티플렉서)" 로 통일.
  case "${runner}" in
    tmux|cmux)
      echo "[워커 실행 모드] 별도 pane (멀티플렉서 attached) — 새 pane/surface 에서 워커 Claude 가 동작합니다." >&2
      ;;
    sequential)
      echo "[워커 실행 모드] 같은 셸 (sequential) — 현재 Claude 세션이 워커 페르소나로 전환되어 동작합니다." >&2
      ;;
    manual)
      echo "[워커 실행 모드] 사용자 직접 (manual) — 준비된 worker-request.md 를 사용자가 원하는 CLI 로 직접 실행합니다." >&2
      ;;
  esac

  # experimental 선택 시 추가 경고 1줄. 로그에 확실히 남도록 banner 끝에 붙인다.
  # inside-context auto-select 는 사용자가 컨텍스트 안에 있다는 점이 의식적 선택
  # 신호이므로 경고 톤을 약화한다 (자동 set 과 명시 opt-in 의 신뢰도 차이를 톤으로 반영).
  if [[ "${state}" == "experimental" ]]; then
    if [[ "${grant}" == "inside-context" ]]; then
      echo "[NOTE] '${runner}' 는 experimental 러너입니다. inside-context 자동 감지로 활성화됐습니다 (grant=inside-context)." >&2
    else
      echo "[WARN] '${runner}' 는 실험적(experimental) 러너입니다 — 계약이 변동될 수 있으니 결과를 주의해서 확인하세요." >&2
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# v1.5.7: company_resolve_override_path <project_root> <kit-relative-path>
#   .company-overrides/<rel> 가 있으면 그 절대경로, 없으면 .company-kit/<rel>
#   절대경로를 stdout 에 출력. 둘 다 없으면 빈 문자열 + rc=1.
#   사용 예 — config 파일 로딩, 템플릿 탐색.
# ─────────────────────────────────────────────────────────────────────────────
company_resolve_override_path() {
  local project_root="$1"
  local rel="$2"
  if [[ -z "${project_root}" || -z "${rel}" ]]; then return 2; fi
  if [[ -e "${project_root}/.company-overrides/${rel}" ]]; then
    printf '%s\n' "${project_root}/.company-overrides/${rel}"
    return 0
  fi
  if [[ -e "${project_root}/.company-kit/${rel}" ]]; then
    printf '%s\n' "${project_root}/.company-kit/${rel}"
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# runner_emit_selected <project_root> <session_id>
#   canonical 이벤트 runner_selected 를 emit. company-emit.sh 를 재사용.
# ─────────────────────────────────────────────────────────────────────────────
runner_emit_selected() {
  local project_root="$1"
  local session_id="$2"
  local emit="${RUNNER_LIB_DIR}/company-emit.sh"
  if [[ ! -x "${emit}" ]] && [[ ! -f "${emit}" ]]; then return 0; fi
  local _state="${RUNNER_SELECTED_STATE:-}"
  [[ -n "${_state}" ]] || _state="$(runner_state "${RUNNER_SELECTED:-sequential}" 2>/dev/null || echo unknown)"
  bash "${emit}" "runner_selected" "${session_id}" "${project_root}" \
    "runner=${RUNNER_SELECTED:-sequential}" \
    "runner_source=${RUNNER_SOURCE:-auto}" \
    "fallback_reason=${RUNNER_FALLBACK_REASON:-}" \
    "parallel_available=$(runner_parallel_available "${RUNNER_SELECTED:-sequential}")" \
    "state=${_state}" \
    "allow_experimental=${RUNNER_ALLOW_EXPERIMENTAL:-0}" \
    "experimental_grant=${RUNNER_EXPERIMENTAL_GRANT:-}" \
    >/dev/null 2>&1 || true
}

# ═════════════════════════════════════════════════════════════════════════════
# Shared helpers (v1.3.8) — 여러 tmux-like 어댑터에서 반복 사용되는 기본 블록.
# 새 어댑터가 동일한 패턴 (pane 검색 / literal send-keys / env 누수 차단) 을
# 그대로 쓸 수 있도록 뽑아두었다.
# ═════════════════════════════════════════════════════════════════════════════

# _runner_sanitize_env
#   리더 쉘에 남아 있는 다른 멀티플렉서 env (TMUX / CMUX / ZELLIJ / WEZTERM_*)
#   가 자식 프로세스에 새어 들어가 '이미 세션 안' 으로 오탐되지 않도록 차단한다.
#   선택된 러너에 맞는 env 만 유지.
#
#   용례:
#     _runner_sanitize_env "tmux"    # CMUX/ZELLIJ/WEZTERM_* 만 unset
#     _runner_sanitize_env "cmux"    # TMUX/ZELLIJ/WEZTERM_* 만 unset
#     _runner_sanitize_env ""        # 모든 멀티플렉서 env 제거 (sequential 등)
_runner_sanitize_env() {
  local keep="${1:-}"
  # 주의: cmux 는 단독 $CMUX 가 아니라 CMUX_PANEL_ID/CMUX_WORKSPACE_ID/CMUX_TAB_ID/
  # CMUX_SOCKET 등의 prefixed env 를 사용한다. 따라서 cmux 모드에서는 그것들을 보존해야
  # detect/current-workspace 가 정상 동작한다. 반대로 tmux 모드에서는 CMUX_* 가 새어들면
  # 다른 멀티플렉서 안으로 오탐될 수 있어 일괄 unset.
  case "${keep}" in
    tmux)
      unset CMUX CMUX_PANEL_ID CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_SOCKET CMUX_PORT \
            CMUX_SHELL_INTEGRATION CMUX_BUNDLE_ID ZELLIJ WEZTERM_PANE WEZTERM_UNIX_SOCKET STY
      ;;
    cmux)
      unset TMUX TMUX_PANE ZELLIJ WEZTERM_PANE WEZTERM_UNIX_SOCKET STY
      ;;
    zellij)
      unset TMUX TMUX_PANE CMUX CMUX_PANEL_ID CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_SOCKET CMUX_PORT \
            CMUX_SHELL_INTEGRATION CMUX_BUNDLE_ID WEZTERM_PANE WEZTERM_UNIX_SOCKET STY
      ;;
    *)
      unset TMUX TMUX_PANE CMUX CMUX_PANEL_ID CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_SOCKET CMUX_PORT \
            CMUX_SHELL_INTEGRATION CMUX_BUNDLE_ID ZELLIJ WEZTERM_PANE WEZTERM_UNIX_SOCKET STY
      ;;
  esac
}

# runner_display_name <runner>
#   사용자 노출 메시지에 쓸 라벨. RUNNER_SELECTED 또는 인자 기반.
#   "${RUNNER_DISPLAY_NAME:-tmux}" 패턴으로 스크립트 메시지에서 동적 주입한다.
runner_display_name() {
  local r="${1:-${RUNNER_SELECTED:-${COMPANY_RUNNER:-}}}"
  case "${r}" in
    tmux)       printf 'tmux\n' ;;
    cmux)       printf 'cmux\n' ;;
    sequential) printf 'sequential\n' ;;
    manual)     printf 'manual\n' ;;
    "")         printf 'tmux\n' ;;  # detect 이전 단계의 안전한 기본값
    *)          printf '%s\n' "${r}" ;;
  esac
}

# _runner_find_pane_by_proc <multiplexer> <proc_name> [<window_name>]
#   현재 실행 중 pane/tab 중에서 pane_current_command == proc_name 인 첫 번째
#   타겟의 식별자를 stdout 으로 돌려준다. 각 멀티플렉서마다 listing API 가 달라
#   여기서 정규화해둔다. window_name 을 함께 주면 우선 매칭.
#   발견 실패 시 빈 문자열 + rc 1.
_runner_find_pane_by_proc() {
  local mux="$1"
  local proc="$2"
  local window="${3:-}"
  local target=""

  case "${mux}" in
    tmux)
      command -v tmux >/dev/null 2>&1 || { printf ''; return 1; }
      target="$(tmux list-panes -a -F '#{pane_id}|#{window_name}|#{pane_current_command}' 2>/dev/null \
        | awk -F'|' -v p="${proc}" -v w="${window}" \
            '($2 == w && $3 == p) {print $1; exit}')"
      if [[ -z "${target}" ]]; then
        target="$(tmux list-panes -a -F '#{pane_id}|#{pane_current_command}' 2>/dev/null \
          | awk -F'|' -v p="${proc}" '$2 == p {print $1; exit}')"
      fi
      ;;
    cmux)
      # cmux 0.63.x 는 process info 를 노출하지 않는다 (`list-panes` 가 -F/format 미지원,
      # pane_current_command 등가 필드 없음). pane 자동 탐색은 설계상 불가하므로 always
      # not-found 로 명시 반환한다. cmux send_worker_message 는 cmux-target 마커
      # (surface:<id> 또는 panel:<id>) 를 직접 읽도록 별도 경로를 사용한다.
      command -v cmux >/dev/null 2>&1 || { printf ''; return 1; }
      printf ''
      return 1
      ;;
    *) printf ''; return 1 ;;
  esac

  if [[ -n "${target}" ]]; then
    printf '%s\n' "${target}"
    return 0
  fi
  printf ''
  return 1
}

# _runner_safe_send_keys <multiplexer> <target> <message>
#   stdin 인젝션이 의도치 않은 키 조합으로 해석되지 않도록 literal 전송을 강제한다.
#   (tmux 는 `-l`, cmux 는 `-l` 또는 `--literal` 를 기대)
#   마지막에 개행(Enter) 을 한 번 보낸다.
#   실패 시 rc != 0. 메시지가 빈 문자열이면 no-op 으로 0 반환.
_runner_safe_send_keys() {
  local mux="$1"
  local target="$2"
  local message="${3:-}"
  [[ -n "${message}" ]] || return 0

  case "${mux}" in
    tmux)
      command -v tmux >/dev/null 2>&1 || return 2
      [[ -n "${target}" ]] || return 3
      tmux send-keys -l -t "${target}" -- "${message}" 2>/dev/null || return 4
      tmux send-keys -t "${target}" Enter 2>/dev/null || true
      ;;
    cmux)
      command -v cmux >/dev/null 2>&1 || return 2
      [[ -n "${target}" ]] || return 3
      # cmux 0.63.x: send-keys 미존재. send (text) + send-key Enter 분리.
      # target 표기는 type prefix 강제: surface:<id> 또는 panel:<id>.
      case "${target}" in
        surface:*)
          if declare -f cmux_submit_text >/dev/null 2>&1; then
            cmux_submit_text "${target}" "${message}" || return 4
          else
            cmux send --surface "${target}" -- "${message}" 2>/dev/null \
              || cmux send --surface "${target#surface:}" -- "${message}" 2>/dev/null \
              || return 4
            cmux send-key --surface "${target}" enter 2>/dev/null \
              || cmux send-key --surface "${target#surface:}" enter 2>/dev/null \
              || cmux send-key --surface "${target}" Enter 2>/dev/null \
              || cmux send-key --surface "${target#surface:}" Enter 2>/dev/null \
              || return 4
          fi
          ;;
        panel:*)
          if declare -f cmux_submit_text >/dev/null 2>&1; then
            cmux_submit_text "${target}" "${message}" || return 4
          else
            cmux send-panel --panel "${target}" -- "${message}" 2>/dev/null \
              || cmux send-panel --panel "${target#panel:}" -- "${message}" 2>/dev/null \
              || return 4
            cmux send-key-panel --panel "${target}" enter 2>/dev/null \
              || cmux send-key-panel --panel "${target#panel:}" enter 2>/dev/null \
              || cmux send-key-panel --panel "${target}" Enter 2>/dev/null \
              || cmux send-key-panel --panel "${target#panel:}" Enter 2>/dev/null \
              || return 4
          fi
          ;;
        *)
          echo "_runner_safe_send_keys cmux: target must be 'surface:<id>' or 'panel:<id>' (got: ${target})" >&2
          return 3
          ;;
      esac
      ;;
    *) return 9 ;;
  esac
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 편의: runner-lib 가 load 되면 sequential 어댑터는 항상 로드 (fallback 안전망).
# 실제 사용될 러너는 resolve_runner 이후 추가로 load 한다.
# ─────────────────────────────────────────────────────────────────────────────
runner_load sequential 2>/dev/null || true
