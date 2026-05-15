#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# v1.5.3: `--topic <X>` / `--root <DIR>` / `--session <ID>` 명시 플래그 지원.
# 이전에는 포지셔널 3개만 받아서 `prepare-session.sh --topic "..."` 호출 시
# `--topic` 이 SESSION_ID 로, "..." 이 ROOT 로 잘못 매핑되어 worktree-create 가
# 존재하지 않는 디렉토리로 cd 하려다 실패했다. 호환성을 위해 포지셔널 사용도
# 그대로 유지한다.
_FLAG_SESSION_ID=""
_FLAG_TOPIC=""
_FLAG_ROOT=""
_POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --topic=*)   _FLAG_TOPIC="${1#--topic=}"; shift ;;
    --topic)     [[ $# -ge 2 ]] || { echo "ERROR: --topic requires a value." >&2; exit 1; }
                 _FLAG_TOPIC="$2"; shift 2 ;;
    --root=*)    _FLAG_ROOT="${1#--root=}"; shift ;;
    --root)      [[ $# -ge 2 ]] || { echo "ERROR: --root requires a value." >&2; exit 1; }
                 _FLAG_ROOT="$2"; shift 2 ;;
    --session=*) _FLAG_SESSION_ID="${1#--session=}"; shift ;;
    --session)   [[ $# -ge 2 ]] || { echo "ERROR: --session requires a value." >&2; exit 1; }
                 _FLAG_SESSION_ID="$2"; shift 2 ;;
    --runner=*|--no-fallback|--allow-experimental)
                 # run-session.sh 에서 처리되는 플래그 — 여기로 잘못 흘러들어와도 무해하게 무시
                 shift ;;
    --) shift; while [[ $# -gt 0 ]]; do _POSITIONAL+=("$1"); shift; done ;;
    --*) echo "ERROR: Unknown flag for prepare-session.sh: $1" >&2; exit 1 ;;
    *)   _POSITIONAL+=("$1"); shift ;;
  esac
done

SESSION_ID="${_FLAG_SESSION_ID:-${_POSITIONAL[0]:-}}"
ARG2="${_POSITIONAL[1]:-}"
ARG3="${_POSITIONAL[2]:-}"
# 명시 플래그가 있으면 포지셔널보다 우선
if [[ -n "${_FLAG_TOPIC}" ]]; then
  if [[ -n "${_FLAG_ROOT}" ]]; then
    ARG2="${_FLAG_ROOT}"
    ARG3="${_FLAG_TOPIC}"
  else
    ARG2="${_FLAG_TOPIC}"
    ARG3=""
  fi
elif [[ -n "${_FLAG_ROOT}" ]]; then
  ARG2="${_FLAG_ROOT}"
fi

# shellcheck source=./git-worktree-lib.sh
source "${SCRIPT_DIR}/git-worktree-lib.sh"
# shellcheck source=./runner-lib.sh
source "${SCRIPT_DIR}/runner-lib.sh" 2>/dev/null || true
# generate_session_id 는 R14 cleanup 으로 git-worktree-lib.sh 에 통합 (SSOT).

# v1.3.9 P1: pre-resolve 단계 SESSION_ID 자동 감지를 attached 러너 매트릭스로
# 일반화. tmux/cmux 둘 다 폴링하며, probe 결과 (_PROBE_RUNNER) 는 ARG 휴리스틱
# 에서도 'attached 러너 안에 있는가' 의 신호로 재사용한다.
_PROBE_RUNNER=""
_PROBE_SESSION=""
if declare -f runner_probe_session_name >/dev/null 2>&1; then
  _PROBE_OUT="$(runner_probe_session_name 2>/dev/null || true)"
  if [[ -n "${_PROBE_OUT}" ]]; then
    _PROBE_RUNNER="$(printf '%s' "${_PROBE_OUT}" | sed -n '1p')"
    _PROBE_SESSION="$(printf '%s' "${_PROBE_OUT}" | sed -n '2p')"
  fi
  unset _PROBE_OUT
fi

if [[ -z "${SESSION_ID}" && -n "${_PROBE_SESSION}" ]]; then
  SESSION_ID="${_PROBE_SESSION}"
fi

# shellcheck source=./integration-env-lib.sh
source "${SCRIPT_DIR}/integration-env-lib.sh"
# shellcheck source=./cost-mode-lib.sh
source "${SCRIPT_DIR}/cost-mode-lib.sh"

ROOT="."
TOPIC=""

if [[ -z "${ARG3}" && -n "${ARG2}" && -d "${ARG2}" && -z "${_PROBE_RUNNER}" && "${SESSION_ID}" == *" "* ]]; then
  TOPIC="${SESSION_ID}"
  SESSION_ID=""
  ROOT="${ARG2}"
fi

if [[ -n "${ARG3}" ]]; then
  ROOT="${ARG2}"
  TOPIC="${ARG3}"
elif [[ -n "${ARG2}" ]]; then
  if [[ -d "${ARG2}" ]]; then
    ROOT="${ARG2}"
  else
    TOPIC="${ARG2}"
    if [[ -z "${SESSION_ID}" ]]; then
      SESSION_ID="$(generate_session_id "${TOPIC}" "${ROOT}")"
    fi
  fi
fi

if [[ -z "${SESSION_ID}" ]]; then
  SESSION_ID="$(generate_session_id "${TOPIC}" "${ROOT}")"
fi

# SESSION_ID가 직접 주어진 경우에도 generic blacklist 검사
_BLACKLISTED_SLUGS="init planning plannning brainstorm design engineering worker-request test-update feature phase default session"
if echo " ${_BLACKLISTED_SLUGS} " | grep -q " ${SESSION_ID} "; then
  echo "ERROR: Session slug '${SESSION_ID}' is too generic. Please provide a more specific topic." >&2
  echo "Example: '${SESSION_ID}-canvas-crop', '${SESSION_ID}-onboarding-v2'" >&2
  exit 1
fi

PROJECT_ROOT="$(resolve_shared_project_root "${ROOT}")"
COST_MODE="$(resolve_cost_mode "${PROJECT_ROOT}")"
WORKER_LIMIT="$(cost_mode_worker_limit "${COST_MODE}")"

mkdir -p \
  "${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers" \
  "${PROJECT_ROOT}/.company-artifacts/${SESSION_ID}/code" \
  "${PROJECT_ROOT}/.company-artifacts/${SESSION_ID}/docs" \
  "${PROJECT_ROOT}/.company-artifacts/${SESSION_ID}/assets" \
  "${PROJECT_ROOT}/.company-artifacts/${SESSION_ID}/decisions" \
  "${PROJECT_ROOT}/.company-artifacts/${SESSION_ID}/reviews"

cp -n "${PROJECT_ROOT}/.company-kit/templates/session-report.md" \
  "${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/session-report.md" 2>/dev/null || true
cp -n "${PROJECT_ROOT}/.company-kit/templates/approval-log.md" \
  "${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/approval-log.md" 2>/dev/null || true
cp -n "${PROJECT_ROOT}/.company-kit/templates/promotion-log.md" \
  "${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/promotion-log.md" 2>/dev/null || true

SESSION_WORK_ROOT="${PROJECT_ROOT}"
BRANCH_NAME=""
BASE_REF=""
SHARED_PREFIX="."

if command -v git >/dev/null 2>&1 && is_git_repo "${PROJECT_ROOT}"; then
  SESSION_WORK_ROOT="$(session_worktree_path "${PROJECT_ROOT}" "${SESSION_ID}")"
  if ! load_session_metadata "${PROJECT_ROOT}" "${SESSION_ID}" || [[ "${WORKTREE_ENABLED:-0}" != "1" ]] || [[ ! -d "${WORKTREE_ROOT:-}" ]]; then
    bash "${SCRIPT_DIR}/git-worktree-create.sh" "${SESSION_ID}" "${PROJECT_ROOT}" >/dev/null
    load_session_metadata "${PROJECT_ROOT}" "${SESSION_ID}"
  fi
  SESSION_WORK_ROOT="${WORKTREE_ROOT}"
  BRANCH_NAME="${WORKTREE_BRANCH}"
  BASE_REF="${WORKTREE_BASE_REF}"
  SHARED_PREFIX=".company-shared"
else
  write_session_metadata "${PROJECT_ROOT}" "${SESSION_ID}" "0" "${PROJECT_ROOT}" "" ""
fi

write_session_env_loader "${PROJECT_ROOT}" "${SESSION_ID}"

# session-info.env는 source로 읽히므로 TOPIC의 작은따옴표를 escape 처리
_topic_escaped="${TOPIC//\'/\'\\\'\'}"
{
  printf 'SESSION_ID=%s\n' "${SESSION_ID}"
  printf "TOPIC='%s'\n" "${_topic_escaped}"
  printf 'COST_MODE=%s\n' "${COST_MODE}"
  printf 'WORKER_LIMIT=%s\n' "${WORKER_LIMIT}"
} > "${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/session-info.env"

cat > "${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/session-banner.txt" <<EOF
Session: ${SESSION_ID}
Topic: ${TOPIC:-n/a}
Cost Mode: ${COST_MODE}
Shared Root: ${PROJECT_ROOT}
Shared Prefix: ${SHARED_PREFIX}
Worktree: ${SESSION_WORK_ROOT}
Branch: ${BRANCH_NAME:-shared-root}
Base Ref: ${BASE_REF:-n/a}
Runtime: ${SHARED_PREFIX}/.company-runtime/sessions/${SESSION_ID}
Artifacts: ${SHARED_PREFIX}/.company-artifacts/${SESSION_ID}
Integrations: ${SHARED_PREFIX}/.company-project/integrations/
Env Loader: ${SHARED_PREFIX}/.company-runtime/sessions/${SESSION_ID}/load-env.sh
Next Step: prepare-worker.sh <worker>
Leader Role: orchestration only
Leader Model: Opus
Worker Model: Sonnet
Active Worker Limit: ${WORKER_LIMIT}
EOF

cat > "${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/leader-session.md" <<EOF
# Leader Session Guide

이 세션은 리더 전용 세션입니다. 리더는 판단, 승인, 통합만 담당하고 직접 실무하지 않습니다.

## 시작

\`\`\`bash
cd ${SESSION_WORK_ROOT}
source ${SHARED_PREFIX}/.company-runtime/sessions/${SESSION_ID}/load-env.sh >/dev/null 2>&1 || true
cat ${SHARED_PREFIX}/.company-runtime/sessions/${SESSION_ID}/session-banner.txt
cat ${SHARED_PREFIX}/.company-project/model-policy.md
\`\`\`

## 리더 규칙

- 기본 모델은 Opus입니다.
- 직접 코드 작성, 장문 초안 작성, 상세 구현을 하지 않습니다.
- 현재 cost mode는 ${COST_MODE}이며, 활성 워커는 최대 ${WORKER_LIMIT}개까지만 유지합니다.
- 기본은 primary worker 1개만 먼저 띄웁니다.

## 다음 준비 명령

\`\`\`bash
bash .company-kit/scripts/prepare-worker.sh ${SESSION_ID} <worker>
\`\`\`

## Claude 요청 예시

- \`/route-topic ${SESSION_ID} topic routing\`
- \`/start-workstream ${SESSION_ID}\`
- \`/spawn-worker ${SESSION_ID} frontend-engineer\`

자연어 예시:

- "${SESSION_ID} session 열어줘."
- "${SESSION_ID}에 frontend-engineer 워커 준비해줘."

## 기본 흐름

1. topic 정리
2. 필요한 worker 선택
3. worker 준비
4. 활성 러너(Runner)에 따라 Sonnet worker 스폰
   - attached (tmux / cmux): 현재 세션에 새 pane 추가
   - detached (sequential): 현재 또는 별도 터미널/창에 직접 투입
   - manual: 본인 환경에서 자유롭게 실행
   - 러너는 \`company doctor\` 로 확인하거나 \`.company-runtime/sessions/${SESSION_ID}/preflight.json\` 에서 조회합니다.
5. worker가 compact plan을 리더에게 보고
6. 리더가 승인 또는 반려
7. 승인된 worker만 draft 또는 execution 진행
8. 워커 내부 sub-agent는 정말 필요할 때만 추가 승인
9. 리더가 최종 요약과 integration만 수행
EOF

cat > "${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/leader-minimal.md" <<EOF
# Leader Minimal

이 파일만 먼저 읽고 시작합니다.

## 최소 규칙

- 리더 모델은 Opus입니다.
- 리더는 직접 코드 작성, 초안 작성, 상세 구현을 하지 않습니다.
- 기본은 primary worker 1개만 먼저 준비합니다.
- 현재 cost mode는 ${COST_MODE}이며, 활성 워커는 최대 ${WORKER_LIMIT}개입니다.
- 워커 내부 sub-agent는 기본적으로 금지합니다.
- 정말 필요할 때만 리더가 명시 승인한 뒤 최대 2개까지, 모두 plan mode로만 허용합니다.

## 바로 실행할 명령

\`\`\`bash
cd ${SESSION_WORK_ROOT}
source ${SHARED_PREFIX}/.company-runtime/sessions/${SESSION_ID}/load-env.sh >/dev/null 2>&1 || true
cat ${SHARED_PREFIX}/.company-project/model-policy.md
bash .company-kit/scripts/prepare-worker.sh ${SESSION_ID} <worker>
\`\`\`

## 권장 순서

1. topic을 한 줄로 고정
2. primary worker 1개 선택
3. worker 준비
4. 활성 러너(Runner)에 따라 Sonnet worker 스폰 — attached(tmux/cmux): 새 pane / detached(sequential): 별도 터미널·창 / manual: 본인 환경. (러너 확인: \`company doctor\` 또는 preflight.json)
5. worker의 compact plan 수집
6. 승인 또는 반려
7. 승인된 worker만 실행
EOF

echo "Prepared session: ${SESSION_ID}"
echo "Shared Root: ${PROJECT_ROOT}"
echo "Worktree: ${SESSION_WORK_ROOT}"
echo "Runtime: ${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}"
echo "Artifacts: ${PROJECT_ROOT}/.company-artifacts/${SESSION_ID}"
echo "Leader session guide: ${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/leader-session.md"
echo "Leader minimal guide: ${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/leader-minimal.md"
echo "Recommended Claude request: /rw ${SESSION_ID}"
