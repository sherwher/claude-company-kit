#!/usr/bin/env bash
set -euo pipefail

# v1.5.11: --topic <text> / COMPANY_WORKER_TOPIC 입력 경로 추가.
# worker-request.md 에 토픽이 박혀있지 않으면 워커가 잔여 컨텍스트로 표류한다
# (R-2026-05-08 회귀). 토픽은 인자/환경변수 어느 쪽이든 받아서 worker-request.md
# 상단에 '## 🎯 세션 토픽' 섹션으로 inject 한다.
WORKER_TOPIC="${COMPANY_WORKER_TOPIC:-}"
POSITIONAL=()
while (($# > 0)); do
  case "$1" in
    --topic)
      WORKER_TOPIC="${2:-}"
      shift 2
      ;;
    --topic=*)
      WORKER_TOPIC="${1#--topic=}"
      shift
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

ARG1="${1:-}"
ARG2="${2:-}"
ROOT="${3:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# R23 (축 2): spawn_failure trap — set -e 하에서 비정상 종료 시 자동 emit
# spawn_success 는 worker-request.md 생성 완료 직후 명시 emit (성공 경로 끝)
# trap 이 등록된 후 spawn_success emit 전에 성공하면 trap - EXIT 로 해제
_R23_spawn_failure_trap() {
  local _exit_code=$?
  # exit 0 (정상 종료) 은 spawn_success 가 이미 emit 됐으므로 failure trap 불필요
  if [[ "${_exit_code}" -ne 0 ]] && [[ -n "${SESSION_ID:-}" ]] && [[ -n "${WORKER_NAME:-}" ]]; then
    bash "${SCRIPT_DIR}/company-emit.sh" "spawn_failure" "${SESSION_ID}" "${PROJECT_ROOT:-.}" \
      "worker=${WORKER_NAME}" "exit_code=${_exit_code}" >/dev/null 2>&1 || true
  fi
}
trap '_R23_spawn_failure_trap' EXIT

# shellcheck source=./worker-definition-lib.sh
source "${SCRIPT_DIR}/worker-definition-lib.sh"
# shellcheck source=./git-worktree-lib.sh
source "${SCRIPT_DIR}/git-worktree-lib.sh"
# shellcheck source=./integration-env-lib.sh
source "${SCRIPT_DIR}/integration-env-lib.sh"
# shellcheck source=./worker-role-lib.sh
source "${SCRIPT_DIR}/worker-role-lib.sh"
# shellcheck source=./cost-mode-lib.sh
source "${SCRIPT_DIR}/cost-mode-lib.sh"
# shellcheck source=./runner-lib.sh
source "${SCRIPT_DIR}/runner-lib.sh" 2>/dev/null || true

# v1.3.9 P1: pre-resolve 단계 SESSION_ID 자동 감지를 attached 러너 매트릭스로
# 일반화 (tmux/cmux 둘 다 폴링).
_probe_session_name() {
  declare -f runner_probe_session_name >/dev/null 2>&1 || { printf ''; return 1; }
  local out
  out="$(runner_probe_session_name 2>/dev/null || true)"
  [[ -z "${out}" ]] && return 1
  printf '%s' "${out}" | sed -n '2p'
}

PROJECT_ROOT="$(resolve_shared_project_root "${ROOT}")"
WORKER_CONFIG_PATH="${PROJECT_ROOT}/.company-kit/config/worker-definitions.tsv"
WORKER_ROLE_CONFIG_PATH="${PROJECT_ROOT}/.company-kit/config/worker-role-briefs.tsv"
COST_MODE="$(resolve_cost_mode "${PROJECT_ROOT}")"
WORKER_LIMIT="$(cost_mode_worker_limit "${COST_MODE}")"

is_known_worker() {
  local candidate="$1"
  [[ -n "${candidate}" ]] || return 1
  find_worker_definition "${WORKER_CONFIG_PATH}" "${candidate}" >/dev/null 2>&1
}

SESSION_ID=""
WORKER_NAME=""

if [[ -n "${ARG1}" && -n "${ARG2}" ]]; then
  if is_known_worker "${ARG1}" && ! is_known_worker "${ARG2}"; then
    WORKER_NAME="${ARG1}"
    SESSION_ID="${ARG2}"
  else
    SESSION_ID="${ARG1}"
    WORKER_NAME="${ARG2}"
  fi
elif [[ -n "${ARG1}" ]]; then
  if is_known_worker "${ARG1}"; then
    WORKER_NAME="${ARG1}"
    SESSION_ID="$(_probe_session_name 2>/dev/null || printf '')"
  else
    SESSION_ID="${ARG1}"
  fi
fi

if [[ -z "${SESSION_ID}" ]]; then
  SESSION_ID="$(_probe_session_name 2>/dev/null || printf '')"
fi

if [[ -z "${SESSION_ID}" || -z "${WORKER_NAME}" ]]; then
  echo "Usage: $0 <worker-name> [session-id] [project-root]"
  echo "   or: $0 <session-id> <worker-name> [project-root]"
  echo "If run inside an attached runner (tmux/cmux), current session name is used automatically."
  exit 1
fi

if ! load_session_metadata "${PROJECT_ROOT}" "${SESSION_ID}" && [[ ! -f "${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/session.env" ]]; then
  bash "${SCRIPT_DIR}/prepare-session.sh" "${SESSION_ID}" "${PROJECT_ROOT}" >/dev/null
  load_session_metadata "${PROJECT_ROOT}" "${SESSION_ID}" || true
fi

WORKER_DEFINITION="$(find_worker_definition "${WORKER_CONFIG_PATH}" "${WORKER_NAME}" || true)"
if [[ -z "${WORKER_DEFINITION}" ]]; then
  echo "Unknown worker: ${WORKER_NAME}"
  echo "Check .company-kit/config/worker-definitions.tsv for supported workers."
  exit 1
fi

IFS=$'\t' read -r WORKER_NAME PROFILE_DOC STARTER_TEMPLATE WORK_HINTS <<< "${WORKER_DEFINITION}"

WORKER_ROLE_BRIEF="$(find_worker_role_brief "${WORKER_ROLE_CONFIG_PATH}" "${WORKER_NAME}" || true)"
if [[ -z "${WORKER_ROLE_BRIEF}" ]]; then
  echo "Missing worker role brief: ${WORKER_NAME}"
  echo "Check .company-kit/config/worker-role-briefs.tsv for supported workers."
  exit 1
fi

WORKER_DISPLAY_NAME="$(get_worker_brief_field "${WORKER_ROLE_CONFIG_PATH}" "${WORKER_NAME}" 2)"
INTERNAL_AGENTS="$(get_worker_brief_field "${WORKER_ROLE_CONFIG_PATH}" "${WORKER_NAME}" 3)"
WORKER_MISSION="$(get_worker_brief_field "${WORKER_ROLE_CONFIG_PATH}" "${WORKER_NAME}" 4)"
WORKER_OUTPUTS="$(get_worker_brief_field "${WORKER_ROLE_CONFIG_PATH}" "${WORKER_NAME}" 5)"
WORKER_QUESTIONS="$(get_worker_brief_field "${WORKER_ROLE_CONFIG_PATH}" "${WORKER_NAME}" 6)"

if [[ -z "${WORKER_MISSION}" || "${WORKER_MISSION}" == "-" ]]; then
  echo "ERROR: Worker '${WORKER_NAME}' has empty mission in worker-role-briefs.tsv" >&2
  echo "Check config/company.yaml → workers.${WORKER_NAME}.brief.mission and re-run scripts/generate-tsv-from-yaml.sh" >&2
  exit 1
fi

[[ "${INTERNAL_AGENTS}" == "-" ]] && INTERNAL_AGENTS=""
[[ "${WORKER_OUTPUTS}" == "-" ]] && WORKER_OUTPUTS=""
[[ "${WORKER_QUESTIONS}" == "-" ]] && WORKER_QUESTIONS=""

PROJECT_ENABLED_PACKS="$(read_project_enabled_packs_csv "${PROJECT_ROOT}")"
WORKER_PACKS="$(resolve_team_packs_csv "${PROJECT_ROOT}" "${WORKER_NAME}")"
WORKER_SKILLS="$(resolve_team_skills_csv "${PROJECT_ROOT}" "${WORKER_NAME}")"
SESSION_WORK_ROOT="${PROJECT_ROOT}"
WORKTREE_BRANCH_LABEL="shared-root"
SHARED_PREFIX="."

if load_session_metadata "${PROJECT_ROOT}" "${SESSION_ID}" && [[ "${WORKTREE_ENABLED:-0}" == "1" ]] && [[ -d "${WORKTREE_ROOT:-}" ]]; then
  SESSION_WORK_ROOT="${WORKTREE_ROOT}"
  WORKTREE_BRANCH_LABEL="${WORKTREE_BRANCH}"
  SHARED_PREFIX=".company-shared"
fi

write_session_env_loader "${PROJECT_ROOT}" "${SESSION_ID}"
bash "${SCRIPT_DIR}/spawn-telemetry-log.sh" "${SESSION_ID}" "${WORKER_NAME}" "${PROJECT_ROOT}" "prepared" "worker-request-generated" >/dev/null
# v1.1.0 (C3): 이벤트 로거 — spawn_attempt 기록 (jq 없으면 silent skip)
bash "${SCRIPT_DIR}/company-emit.sh" "spawn_attempt" "${SESSION_ID}" "${PROJECT_ROOT}" "worker=${WORKER_NAME}" >/dev/null 2>&1 || true

# v1.3.7: 신규 canonical 이벤트 — spawn_prepared (요청서 드롭 완료)
# 기존 spawn_attempt 는 호환성을 위해 유지 (timeout-watchdog 등 파서가 참조).
# 이후 runner 가 실제 spawn 명령을 수락하면 spawn_started 를 어댑터가 emit 한다.
_RUNNER_HINT="${COMPANY_RUNNER:-}"
if [[ -z "${_RUNNER_HINT}" ]]; then
  _pf="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/preflight.json"
  if [[ -f "${_pf}" ]] && command -v jq >/dev/null 2>&1; then
    _RUNNER_HINT="$(jq -r '.runner // empty' "${_pf}" 2>/dev/null || printf '')"
  fi
fi
[[ -n "${_RUNNER_HINT}" ]] || _RUNNER_HINT="unknown"
bash "${SCRIPT_DIR}/company-emit.sh" "spawn_prepared" "${SESSION_ID}" "${PROJECT_ROOT}" \
  "worker=${WORKER_NAME}" "runner=${_RUNNER_HINT}" >/dev/null 2>&1 || true

mkdir -p \
  "${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}" \
  "${PROJECT_ROOT}/.company-artifacts/${SESSION_ID}/${WORKER_NAME}/code" \
  "${PROJECT_ROOT}/.company-artifacts/${SESSION_ID}/${WORKER_NAME}/docs" \
  "${PROJECT_ROOT}/.company-artifacts/${SESSION_ID}/${WORKER_NAME}/assets"

WORKER_RUNTIME_DIR="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}"
if [[ "${_RUNNER_HINT}" == "cmux" ]]; then
  if [[ ! -f "${WORKER_RUNTIME_DIR}/cmux-target" ]]; then
    cat > "${WORKER_RUNTIME_DIR}/cmux-target" <<EOF
# cmux target marker placeholder.
# After spawning the worker pane, replace this file with one line:
#   surface:<id>
# or:
#   panel:<id>
EOF
  fi
  if command -v cmux >/dev/null 2>&1 && [[ -n "${CMUX_PANEL_ID:-}" || -n "${CMUX_WORKSPACE_ID:-}" ]]; then
    cmux list-panes --workspace "${CMUX_WORKSPACE_ID:-current}" --id-format both \
      > "${WORKER_RUNTIME_DIR}/cmux-panes.before" 2>/dev/null \
      || cmux list-panes --workspace "${CMUX_WORKSPACE_ID:-current}" \
        > "${WORKER_RUNTIME_DIR}/cmux-panes.before" 2>/dev/null \
      || true
  fi
fi

# R18 (축 1 / Phase 1 injection): 페르소나 카드를 base worker-system-prompt 위에
# concat 하여 세션 스코프 assembled 파일을 생성한다. 이후 worker-request.md 가
# claude --append-system-prompt-file 로 이 파일을 가리키므로, 워커 서브프로세스는
# R17 에서 작성된 docs/profiles/personas/<worker>.md 카드를 시스템 프롬프트로
# 주입받는다.
# - persona 카드가 누락되면 assemble 스크립트는 warn-only 로 base 만 주입 (회귀 0).
# - assembled 파일이 stdout 으로 반환되지 않으면 fatal — injection 경로가
#   끊겼다는 뜻이므로 prepare 자체를 실패시킨다 (silent drift 방지).
ASSEMBLED_PROMPT_PATH="$(bash "${SCRIPT_DIR}/assemble-worker-prompt.sh" \
  "${WORKER_NAME}" "${SESSION_ID}" "${PROJECT_ROOT}")"
if [[ -z "${ASSEMBLED_PROMPT_PATH}" || ! -f "${ASSEMBLED_PROMPT_PATH}" ]]; then
  echo "ERROR: assemble-worker-prompt.sh 가 assembled 파일 경로를 반환하지 못했습니다." >&2
  echo "       worker=${WORKER_NAME} session=${SESSION_ID} root=${PROJECT_ROOT}" >&2
  exit 1
fi

# v0.3-alpha B3: expected-evidence.json drop
# 왜: validator(shadow→primary)가 yq 의존 없이 must_provide_evidence를 비교할 수 있도록
#     워커 진입점에 매핑 JSON을 미리 떨어뜨려둔다. 옵션 (ii) — R6 권고 채택.
# 안전: python3 또는 company.yaml 부재 시 silent skip (warn-only 정책 일관성).
EXPECTED_EVIDENCE_FILE="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}/expected-evidence.json"
COMPANY_YAML_PATH=""
for candidate in \
  "${PROJECT_ROOT}/.company-kit/config/company.yaml" \
  "${PROJECT_ROOT}/config/company.yaml"; do
  if [[ -f "${candidate}" ]]; then
    COMPANY_YAML_PATH="${candidate}"
    break
  fi
done
EXTRACT_HELPER=""
for helper_candidate in \
  "${SCRIPT_DIR}/extract-expected-evidence.py" \
  "${PROJECT_ROOT}/.company-kit/scripts/extract-expected-evidence.py"; do
  if [[ -f "${helper_candidate}" ]]; then
    EXTRACT_HELPER="${helper_candidate}"
    break
  fi
done
if [[ -n "${COMPANY_YAML_PATH}" && -n "${EXTRACT_HELPER}" ]] && command -v python3 >/dev/null 2>&1; then
  if ! python3 "${EXTRACT_HELPER}" "${COMPANY_YAML_PATH}" "${WORKER_NAME}" \
        > "${EXPECTED_EVIDENCE_FILE}" 2>/dev/null; then
    rm -f "${EXPECTED_EVIDENCE_FILE}"
    echo "[evidence] WARN: expected-evidence.json 생성 실패 (worker=${WORKER_NAME}) — validator는 manifest 단독 검사로 fallback" >&2
  fi
fi

cp -n "${PROJECT_ROOT}/.company-kit/templates/handoff-summary.md" \
  "${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}/handoff-summary.md" 2>/dev/null || true
# v1.1.0: compact-plan.md 미리 복사 폐지 (HARNESS_V0 §4.1A).
# 워커가 첫 Write 호출로 직접 생성해야 하므로 스켈레톤 파일을 사전 생성하지 않는다.
# v1.5.6: compact-result.md 도 미리 복사하지 않는다.
# compact-result.md 템플릿은 예시 frontmatter(status: template-example)를 포함한다.
# 런타임 워커 디렉토리에 복사하면 leader-wake/status 판정이 실제 완료로 오인되므로,
# 워커가 실행 종료 시 직접 Write 로 생성해야 한다.

# compact-plan 행동 지시문 inline 주입용 경로 계산
COMPACT_PLAN_REL="${SHARED_PREFIX}/.company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}/compact-plan.md"
COMPACT_PLAN_PROMPT_FILE="${PROJECT_ROOT}/.company-kit/templates/compact-plan-prompt.md"
if [[ -f "${COMPACT_PLAN_PROMPT_FILE}" ]]; then
  COMPACT_PLAN_PROMPT_BODY="$(sed "s|{{COMPACT_PLAN_PATH}}|${COMPACT_PLAN_REL}|g" "${COMPACT_PLAN_PROMPT_FILE}")"
else
  COMPACT_PLAN_PROMPT_BODY="(WARN) compact-plan-prompt.md 템플릿이 누락되었습니다. ${COMPACT_PLAN_REL} 를 첫 Write 툴 호출로 생성하세요."
fi

LITE_PROFILE_DOC="$(printf '%s' "${PROFILE_DOC}" | sed 's#docs/profiles#docs/profiles-lite#')"

# v1.6.0: vault (Obsidian SSOT) 메타 로딩 — .company-project/project-context.md 의
# YAML-style 'vault:' 블록을 단순 파서로 읽어 vault.enabled=true 면 context.md 에
# 본문 위치 가이드를 inject 한다. 미설정/비활성 시에는 빈 문자열로 유지되어
# 기존 출력과 동일 (회귀 없음).
_VAULT_CONTEXT_BLOCK=""
_VAULT_META_FILE="${SHARED_PREFIX}/.company-project/project-context.md"
if [[ -f "${_VAULT_META_FILE}" ]]; then
  # awk 로 vault: 블록의 키-값을 추출. 2-space 들여쓴 라인만 vault 블록으로 인식.
  _vault_kv="$(awk '
    /^vault:[[:space:]]*$/ { in_block=1; next }
    in_block && /^[^[:space:]]/ { in_block=0 }
    in_block && /^  [a-z_]+:/ {
      key=$1; sub(/:$/, "", key)
      $1=""; sub(/^[[:space:]]+/, "")
      val=$0
      gsub(/^"|"$/, "", val)
      gsub(/^[[:space:]]+|[[:space:]]+#.*$/, "", val)
      print key "\t" val
    }
  ' "${_VAULT_META_FILE}" 2>/dev/null || true)"

  _vault_enabled="$(printf '%s\n' "${_vault_kv}" | awk -F'\t' '$1=="enabled"{print $2}')"
  _vault_root="$(printf '%s\n'    "${_vault_kv}" | awk -F'\t' '$1=="root"{print $2}')"
  if [[ "${_vault_enabled}" == "true" && -n "${_vault_root}" ]]; then
    _vault_proj="$(printf '%s\n'      "${_vault_kv}" | awk -F'\t' '$1=="project_dir"{print $2}')"
    _vault_hub="$(printf '%s\n'       "${_vault_kv}" | awk -F'\t' '$1=="company_hub"{print $2}')"
    _vault_dec="$(printf '%s\n'       "${_vault_kv}" | awk -F'\t' '$1=="decisions_dir"{print $2}')"
    _vault_notes="$(printf '%s\n'     "${_vault_kv}" | awk -F'\t' '$1=="notes_dir"{print $2}')"
    _vault_meet="$(printf '%s\n'      "${_vault_kv}" | awk -F'\t' '$1=="meetings_dir"{print $2}')"
    _VAULT_CONTEXT_BLOCK=$(cat <<VAULT_BLOCK

Vault (Obsidian SSOT) — 활성:
- Root: ${_vault_root}
- Project Dir: ${_vault_proj:-(미설정)}
- Company Hub: ${_vault_hub:-(미설정)}
- Decisions Dir: ${_vault_dec:-(미설정)}
- Notes Dir: ${_vault_notes:-(미설정)}
- Meetings Dir: ${_vault_meet:-(미설정)}

본문 위치 규칙 (v1.6.0+):
- ADR/PRD/회의록 본문은 vault 의 해당 디렉토리에 작성한다.
- repo \`project-work/09-decisions/\` 등에는 한 줄 요약 + vault 영구경로 링크 + 갱신일만 두는 stub 만 둔다.
- 같은 결정/PRD/회의록을 vault·repo 양쪽에 본문으로 두지 않는다 (이중 SSOT 금지).
- PR/CHANGELOG/리뷰 본문은 vault 노트로 링크만 둔다.

가이드: ${SHARED_PREFIX}/.company-kit/docs/guides/OBSIDIAN_VAULT_SETUP.md
VAULT_BLOCK
    )
  fi
fi

cat > "${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}/context.md" <<EOF
Session: ${SESSION_ID}
Worker: ${WORKER_NAME}
Worker Display Name: ${WORKER_DISPLAY_NAME}
Shared Project Root: ${PROJECT_ROOT}
Worktree Root: ${SESSION_WORK_ROOT}
Worktree Branch: ${WORKTREE_BRANCH_LABEL}
Shared Prefix: ${SHARED_PREFIX}
Leader Model: Opus
Worker Model: Sonnet
Execution Mode: company leader -> worker
Artifacts Root: ${SHARED_PREFIX}/.company-artifacts/${SESSION_ID}/${WORKER_NAME}/
Env Loader: ${SHARED_PREFIX}/.company-runtime/sessions/${SESSION_ID}/load-env.sh
Cost Mode: ${COST_MODE}
Worker Limit: ${WORKER_LIMIT}
Main Rules:
- 리더는 직접 실무하지 않는다.
- 워커는 먼저 compact plan만 제출한다.
- 승인 전에는 코드 수정, 파일 생성, 외부 write를 하지 않는다.
- 워커는 자신의 내부에서 추가 sub-agent를 기본적으로 스폰하지 않는다.
- 정말 필요할 때만 리더 승인 후 최대 2개까지, 모두 plan mode로만 시작한다.

Workload Budget (한 워커 turn 한도):
- 코드 수정: ≤ 8 파일 또는 ≤ 400 LOC.
- 다국어/콘텐츠 정품화: ≤ 12 항목.
- 리서치/문서: ≤ 1 결정문 또는 ≤ 1 PRD 섹션.
- Mission 이 위 한도를 초과한다면 plan 단계에서 batch 분할안을 제시하고
  리더 승인 받기. batch 1개 끝마다 commit + compact-result emit, 다음
  batch 는 새 spawn (한 워커가 mega-batch 를 연속 처리하지 않는다 —
  컨텍스트 누적이 stall 의 직접 원인).

Mission:

${WORKER_MISSION}

Default Outputs:

${WORKER_OUTPUTS}

First Questions:

${WORKER_QUESTIONS}

Read First:
- ${SHARED_PREFIX}/.company-project/project-standards.md
- ${SHARED_PREFIX}/.company-project/cost-mode.md
- ${SHARED_PREFIX}/project-work/00-project/working-agreements.md
- ${WORK_HINTS}

Read Only If Blocked:
- ${LITE_PROFILE_DOC}
- ${PROFILE_DOC}
- ${STARTER_TEMPLATE}
${_VAULT_CONTEXT_BLOCK}

---

${COMPACT_PLAN_PROMPT_BODY}
EOF

# v1.3.7: worker-request.md 는 러너별로 다르게 렌더링된다.
# v1.3.8: Gemini UX 권고 — '상호작용 모드(Interaction Mode)' 3-대역 으로 일반화
#          (attached / detached / manual). 러너가 늘어나도 사용자가 받는 문구가
#          동일한 틀을 유지하도록 RUNNER_HINT 를 mode 로 먼저 매핑한다.
case "${_RUNNER_HINT}" in
  tmux|cmux|zellij|wezterm) _INTERACTION_MODE="attached" ;;
  sequential)               _INTERACTION_MODE="detached" ;;
  manual)                   _INTERACTION_MODE="manual" ;;
  *)                        _INTERACTION_MODE="unknown" ;;
esac

# 러너별 세부 지시 (기존 문구 유지). 동일 러너 계열은 핵심 공통 템플릿을 공유한다.
case "${_RUNNER_HINT}" in
  tmux)
    _WORKER_REQ_RUNNER_BLOCK=$(cat <<WRB
[Interaction Mode: attached — tmux]
현재 tmux 리더 세션에서 ${WORKER_DISPLAY_NAME} 워커를 Sonnet worker pane 으로 스폰해 주세요.
반드시 현재 tmux 세션에 teammate pane 이 추가되는 방식으로 실행해 주세요.
pane 이 추가되지 않으면 아직 워커가 스폰되지 않은 것으로 간주합니다.
pane 이 추가되지 않거나 현재 tmux 세션 이름이 ${SESSION_ID} 와 다르면 현재 pane 에서 작업을 계속하지 말고, 스폰 실패를 먼저 보고해 주세요.
먼저 \`bash .company-kit/scripts/spawn-readiness-check.sh leader ${SESSION_ID}\` 로 현재 tmux 리더 세션 상태를 확인해 주세요.
WRB
    )
    ;;
  cmux)
    _WORKER_REQ_RUNNER_BLOCK=$(cat <<WRB
[Interaction Mode: attached — cmux (experimental)]
현재 cmux 리더 세션에서 ${WORKER_DISPLAY_NAME} 워커를 Sonnet worker pane 으로 스폰해 주세요.
tmux 운영 모델과 동형입니다: cmux 세션 안에 teammate pane 이 추가되는 방식으로 실행하세요.
pane 추가 여부와 세션명 (${SESSION_ID}) 을 먼저 확인하세요. 일치하지 않으면 스폰 실패로 간주합니다.
스폰 후 bash .company-kit/scripts/verify-worker-spawn.sh ${SESSION_ID} ${WORKER_NAME} 를 실행해 cmux target 자동 등록을 시도하세요.
자동 등록이 실패하면 .company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}/cmux-target 첫 줄에 surface:<id> 또는 panel:<id> 를 직접 적고 다시 검증하세요.
권장 자동화:
  Step 1: bash .company-kit/scripts/cmux-start-worker.sh ${SESSION_ID} ${WORKER_NAME} ${PROJECT_ROOT} right
  Step 2: 워커 pane 에 Claude 입력창이 보이면 bash .company-kit/scripts/cmux-submit-worker-message.sh ${SESSION_ID} ${WORKER_NAME} ${PROJECT_ROOT}
저수준 cmux send ... --press Enter 는 사용하지 마세요. cmux 에서는 --press Enter 가 literal 텍스트로 들어갈 수 있습니다.
experimental 러너이므로 cmux CLI 버전/옵션 차이로 계약이 어긋날 수 있습니다.
이상 징후가 있으면 --runner=sequential 또는 --runner=tmux 로 재실행해 주세요.
WRB
    )
    ;;
  sequential)
    _WORKER_REQ_RUNNER_BLOCK=$(cat <<WRB
[Interaction Mode: detached — sequential]
순차 실행 러너입니다. 새 pane 대신 **현재 터미널 또는 별도 Claude 창에 이 워커를 투입**해 주세요.
진행 상태는 \`bash .company-kit/scripts/spawn-readiness-check.sh leader ${SESSION_ID}\` 로 확인할 수 있고,
러너에 맞춰 soft-ready 로 보고될 것입니다. 병렬 워커는 없으므로 한 번에 하나의 워커만 진행합니다.
WRB
    )
    ;;
  manual)
    _WORKER_REQ_RUNNER_BLOCK=$(cat <<WRB
[Interaction Mode: manual]
Manual 러너입니다. 이 요청서는 '준비만' 완료된 상태이며, 사용자가 선호하는 방식으로 직접 워커를 띄우게 됩니다.
pane 여부는 검증하지 않으므로, 아래 CLI 를 그대로 실행하거나 본인 에디터에 맞게 조정해 사용하세요.
WRB
    )
    ;;
  *)
    _WORKER_REQ_RUNNER_BLOCK=$(cat <<WRB
[Interaction Mode: ${_INTERACTION_MODE}]
러너가 아직 확정되지 않았습니다 (${_RUNNER_HINT}). 가능한 경우 attached 러너 (tmux 또는 cmux) 세션에서 재실행하거나
\`company run <topic> --runner=sequential\` 로 명시적으로 지정해 주세요.
WRB
    )
    ;;
esac

# v1.5.11: 토픽 주입 블록 — 토픽이 명시된 경우에만 강제 섹션을 inject 한다.
# 토픽이 비어있으면 'Topic: (not provided)' 마커를 남겨 잔여 컨텍스트 표류 시
# 디버깅 단서가 되도록 한다.
if [[ -n "${WORKER_TOPIC}" ]]; then
  _TOPIC_BLOCK=$(cat <<TOPIC_BLOCK

## 🎯 세션 토픽

${WORKER_TOPIC}

이 토픽이 본 워커가 실제로 작업해야 할 내용입니다. context.md 의 Mission
(역할 정의) 과 충돌할 경우 **본 토픽이 우선**합니다. 잔여/이전 세션 컨텍스트로
표류하지 마세요.
TOPIC_BLOCK
  )
  _TOPIC_MARKER="Topic: ${WORKER_TOPIC}"
else
  _TOPIC_BLOCK=""
  _TOPIC_MARKER="Topic: (not provided — 워커가 mission 만 보고 작업할 가능성이 있습니다.)"
fi

cat > "${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}/worker-request.md" <<EOF
# Worker Request

<!-- v1.5.6: Self-locating headers — 워커가 worktree 에서 실행되어 상대경로로
     이 파일을 못 찾을 때, 아래 절대경로로 직접 Read 할 수 있도록 명시. -->
Request-Path: ${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}/worker-request.md
Project-Root: ${PROJECT_ROOT}
Worker-Dir:   ${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}
Context-Path: ${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}/context.md
Runner: ${_RUNNER_HINT}
${_TOPIC_MARKER}
${_TOPIC_BLOCK}

권장 요청:

\`\`\`
${_WORKER_REQ_RUNNER_BLOCK}

워커 스폰 시 반드시 아래 CLI 플래그 전부를 사용해 주세요:
  claude --model sonnet \\
         --permission-mode acceptEdits \\
         --add-dir ${PROJECT_ROOT} \\
         --append-system-prompt-file ${ASSEMBLED_PROMPT_PATH}

(세 플래그 모두 필수. 근거는 docs/design/SMOKE_2026-04-07.md 참조.)

승인 게이트는 권한 모드가 아니라 .company-runtime/sessions/${SESSION_ID}/approved 파일로 관리합니다.

먼저 아래 파일만 읽고 시작해 주세요. 다른 문서는 막힐 때만 추가합니다.

${SHARED_PREFIX}/.company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}/context.md
${SHARED_PREFIX}/.company-project/project-standards.md
${SHARED_PREFIX}/project-work/00-project/working-agreements.md

[필독: 첫 도구 호출 절대 조건]
context.md 하단의 'Compact Plan 작성 프로토콜' 섹션을 정확히 따르세요.
당신의 첫 도구 호출은 채팅이 아니라 \`Write\`여야 합니다.
대상 경로: ${SHARED_PREFIX}/.company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}/compact-plan.md
이 파일은 아직 존재하지 않습니다. 직접 생성하세요.
필수 5섹션(한 글자도 변형 금지): ## Goal / ## Steps / ## Outputs / ## Risks / ## Questions

승인 전 금지:
- compact-plan.md 외 다른 파일 생성/수정
- **EnterPlanMode / ExitPlanMode 툴 호출** (approval gate는 CLI 플래그가 아니라 compact-plan.md 파일. Write 차단 시 파일 게이트가 깨집니다.)
- **Agent 툴 / Task 툴 / oh-my-claudecode:* subagent 호출** (워커당 100k 토큰 즉시 소비 → 4회 호출 시 세션 예산 고갈로 강제 종료)
- 채팅으로 계획만 설명하고 파일을 비워두기
- 5섹션 헤더 변형 (### Goal, ## 목표 등)
- 추가 문서 3개 이상 동시 요청 (리더 승인 먼저)

추가로 읽을 문서는 최대 2개까지만 제안해 주세요.
워커 내부에서 추가 sub-agent를 기본적으로 스폰하지 마세요.
정말 필요할 때만 리더 승인 후 최대 2개까지 추가하고, 모두 plan mode로만 시작해 주세요.
리더 승인 후 실행 단계로 넘어가면 결과는 \`compact-result.md\` 형식으로 정리해 주세요.
최종 승인, 외부 write, 최종 의사결정은 하지 마세요.
\`\`\`
EOF

# R23 (축 2): 워커 준비 성공 — spawn_success emit + failure trap 해제
bash "${SCRIPT_DIR}/company-emit.sh" "spawn_success" "${SESSION_ID}" "${PROJECT_ROOT}" \
  "worker=${WORKER_NAME}" "context=prepared" >/dev/null 2>&1 || true
trap - EXIT

echo "Prepared worker: ${WORKER_NAME}"
echo "Session: ${SESSION_ID}"
echo "Shared Root: ${PROJECT_ROOT}"
echo "Worktree: ${SESSION_WORK_ROOT}"
echo "Worker Context: ${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}/context.md"
echo "Worker Request: ${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}/worker-request.md"
echo "Compact Plan: ${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}/compact-plan.md"
echo "Compact Result: ${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}/compact-result.md"
echo "Artifacts: ${PROJECT_ROOT}/.company-artifacts/${SESSION_ID}/${WORKER_NAME}"
echo "Recommended Claude request: /spawn-worker ${WORKER_NAME}"
echo ""
echo "👉 NEXT: 워커 pane 을 띄운 뒤 아래 명령으로 기동을 확인하세요 (stuck 감지 전제)"
echo "  bash .company-kit/scripts/verify-worker-spawn.sh ${SESSION_ID} ${WORKER_NAME}"
