#!/usr/bin/env bash
# assemble-worker-prompt.sh — R18 (축 1 / Phase 1 injection 경로)
#
# 역할:
#   base worker-system-prompt.md (role override) 위에 worker 별 persona 카드
#   (docs/profiles/personas/<worker>.md) 를 concat 하여, 세션 스코프에
#   `worker-system-prompt.assembled.md` 를 생성한다. prepare-worker.sh 가
#   이 파일 경로를 `claude --append-system-prompt-file` 로 넘겨 워커 서브
#   프로세스에 시스템 프롬프트로 주입된다.
#
# 왜 session 스코프인가:
#   - 카드가 R19/R20 에서 개정되더라도 진행 중인 세션의 프롬프트는 그 시점에
#     고정되어야 재현성이 유지된다.
#   - 여러 워커를 동시에 돌릴 때 카드 내용이 교차 오염되지 않도록 세션 × 워커
#     경로로 분리.
#
# Usage:
#   assemble-worker-prompt.sh <worker-name> <session-id> [project-root]
#
# Output:
#   stdout: assembled 파일 절대경로 (prepare-worker.sh 가 캡처)
#   stderr: WARN/ERROR (persona 누락 시 warn-only, base 템플릿 누락 시 fatal)
#
# Exit codes:
#   0 — 성공 (persona present OR persona absent-with-warn)
#   1 — usage 오류 / base template 누락 / assembled 쓰기 실패

set -euo pipefail

WORKER_NAME="${1:-}"
SESSION_ID="${2:-}"
PROJECT_ROOT_ARG="${3:-.}"

if [[ -z "${WORKER_NAME}" || -z "${SESSION_ID}" ]]; then
  echo "Usage: $0 <worker-name> <session-id> [project-root]" >&2
  exit 1
fi

if [[ ! -d "${PROJECT_ROOT_ARG}" ]]; then
  echo "ERROR: project-root 디렉토리를 찾지 못했습니다: ${PROJECT_ROOT_ARG}" >&2
  exit 1
fi

PROJECT_ROOT="$(cd "${PROJECT_ROOT_ARG}" && pwd)"

# 1) base worker-system-prompt.md 위치 해석
#    target 프로젝트: .company-kit/templates/ (export-company-kit 가 rsync)
#    harness 소스 레포: templates/ (개발/스모크용)
BASE_TEMPLATE=""
for candidate in \
  "${PROJECT_ROOT}/.company-kit/templates/worker-system-prompt.md" \
  "${PROJECT_ROOT}/templates/worker-system-prompt.md"; do
  if [[ -f "${candidate}" ]]; then
    BASE_TEMPLATE="${candidate}"
    break
  fi
done

if [[ -z "${BASE_TEMPLATE}" ]]; then
  echo "ERROR: worker-system-prompt.md 베이스 템플릿을 찾지 못했습니다." >&2
  echo "       확인 경로: .company-kit/templates/, templates/" >&2
  exit 1
fi

# 2) persona 카드 위치 해석 (1:1 파일명 규약)
PERSONA_FILE=""
for candidate in \
  "${PROJECT_ROOT}/.company-kit/docs/profiles/personas/${WORKER_NAME}.md" \
  "${PROJECT_ROOT}/docs/profiles/personas/${WORKER_NAME}.md"; do
  if [[ -f "${candidate}" ]]; then
    PERSONA_FILE="${candidate}"
    break
  fi
done

# 3) 세션 스코프 assembled 경로 계산 + 디렉토리 보장
SESSION_WORKER_DIR="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}"
mkdir -p "${SESSION_WORKER_DIR}"
ASSEMBLED="${SESSION_WORKER_DIR}/worker-system-prompt.assembled.md"

# 4) R21: MCP sidecar 경로 해석 (warn-only if missing)
MCP_SIDECAR=""
for candidate in \
  "${PROJECT_ROOT}/.company-kit/config/worker-role-mcp.tsv" \
  "${PROJECT_ROOT}/config/worker-role-mcp.tsv"; do
  [[ -f "${candidate}" ]] && { MCP_SIDECAR="${candidate}"; break; }
done
if [[ -z "${MCP_SIDECAR}" ]]; then
  echo "[assemble] WARN: worker-role-mcp.tsv 미발견 — 도구 기반 섹션 생략 (R21)" >&2
fi

# 5) concat 작성 — 중간에 명시적 separator + 주입 메타 + 우선순위 주석
{
  cat "${BASE_TEMPLATE}"
  printf '\n\n---\n\n'
  if [[ -n "${PERSONA_FILE}" ]]; then
    printf '# 페르소나 카드 (injected by assemble-worker-prompt.sh)\n\n'
    printf '> 아래 카드는 이 워커의 가상 배경·톤/말투·아웃풋 장르·금기·필수 질문·Primary Toolchains·Decision Framework·Interaction Protocol 을 정의합니다.\n'
    printf '> 당신은 이 카드의 인물로 사고하고, 카드의 Self-Check 기준을 통과하지 못하는 산출물은 self-reject 후 재작성합니다.\n'
    printf '> 카드의 evidence 형식([E1] repo / [E2] ADR·spec / [E3] MCP)과 Don'"'"'ts 는 위의 worker-system-prompt evidence 규칙과 동일 우선순위입니다 — 두 규칙이 **모두** 충족되어야 합니다.\n'
    printf '>\n'
    printf '> Source: %s\n' "${PERSONA_FILE#${PROJECT_ROOT}/}"
    printf '> Session: %s\n' "${SESSION_ID}"
    printf '> Worker: %s\n\n' "${WORKER_NAME}"
    cat "${PERSONA_FILE}"
  else
    printf '# 페르소나 카드 (NOT FOUND — base template only)\n\n'
    printf '> WARN: docs/profiles/personas/%s.md 를 찾지 못해 base template 만 적용되었습니다.\n' "${WORKER_NAME}"
    printf '> 이 워커는 페르소나 없이 기본 worker role 로 동작하며, R17 카드의 톤·깊이·금기 규칙이 **주입되지 않은** 상태입니다.\n'
    printf '> 운영 시 이 경고가 보이면 assemble-worker-prompt.sh 의 persona lookup 경로와 워커 이름 (1:1 파일명 규약) 을 먼저 점검하세요.\n'
  fi

  # R21: 도구 기반 섹션 (MCP sidecar 존재 시만 렌더)
  if [[ -n "${MCP_SIDECAR}" ]]; then
    printf '\n\n---\n\n'
    printf '# 도구 기반 (injected by assemble-worker-prompt.sh / R21)\n\n'
    printf '> **도구는 판단의 근거이며, 근거 없는 설계는 오염이다.**\n\n'
    printf '> Source: %s\n' "${MCP_SIDECAR#${PROJECT_ROOT}/}"
    printf '> Worker: %s\n\n' "${WORKER_NAME}"

    # minimum_call
    MIN_CALL="$(awk -F'\t' -v w="${WORKER_NAME}" '$1==w && $2=="meta" {gsub(/^minimum_call=/,"",$4); print $4; exit}' "${MCP_SIDECAR}")"
    if [[ -n "${MIN_CALL}" ]]; then
      printf '**최소 MCP 호출**: 산출물 제출 전 MCP 도구를 최소 **%s회** 이상 호출해야 합니다.\n\n' "${MIN_CALL}"
    fi

    # Preferred Tools
    PREFERRED="$(awk -F'\t' -v w="${WORKER_NAME}" '$1==w && $2=="preferred" {printf "%s\t%s\n",$3,$4}' "${MCP_SIDECAR}")"
    if [[ -n "${PREFERRED}" ]]; then
      printf '## Preferred Tools\n\n'
      while IFS=$'\t' read -r tool rationale; do
        [[ -z "${tool}" ]] && continue
        # tool ID에서 짧은 이름 추출 (마지막 __ 이후)
        short_name="$(printf '%s' "${tool}" | awk -F'__' '{print $NF}')"
        printf '%s\n' "- **${short_name}** (\`${tool}\`)"
        printf '  %s\n\n' "${rationale}"
      done <<< "${PREFERRED}"
    fi

    # Prefetch Queries
    PREFETCH="$(awk -F'\t' -v w="${WORKER_NAME}" '$1==w && $2=="prefetch" {printf "%s\t%s\t%s\n",$3,$4,$5}' "${MCP_SIDECAR}")"
    if [[ -n "${PREFETCH}" ]]; then
      printf '## Prefetch Queries (세션 시작 시 즉시 실행)\n\n'
      while IFS=$'\t' read -r tool query why; do
        [[ -z "${tool}" ]] && continue
        short_name="$(printf '%s' "${tool}" | awk -F'__' '{print $NF}')"
        printf '%s\n' "- **${short_name}**: \`${query}\`"
        printf '  %s\n\n' "→ ${why}"
      done <<< "${PREFETCH}"
    fi

    # Deferred Tools
    DEFERRED="$(awk -F'\t' -v w="${WORKER_NAME}" '$1==w && $2=="deferred" {print $3"\t"$4}' "${MCP_SIDECAR}")"
    if [[ -n "${DEFERRED}" ]]; then
      printf '## Deferred (현재 운영 불가 — 대체 방법 사용)\n\n'
      while IFS=$'\t' read -r tool payload; do
        [[ -z "${tool}" ]] && continue
        reason="$(printf '%s' "${payload}" | awk -F'[|][|]' '{print $1}' | sed 's/^ *//;s/ *$//')"
        fallback="$(printf '%s' "${payload}" | awk -F'[|][|]' '{print $2}' | sed 's/^ *//;s/ *$//')"
        printf '%s\n\n' "- **${tool}**: ${reason}. 대체 방법: ${fallback}"
      done <<< "${DEFERRED}"
    fi

    # Self-Reject Trigger
    printf '## Self-Reject Trigger\n\n'
    printf '위 Preferred Tools 를 호출하지 않고 작성한 산출물은 **자동 self-reject** 대상입니다.\n'
    printf '도구 없이 추측으로 작성된 내용은 제출 전 반드시 재작성하세요.\n'
  fi
} > "${ASSEMBLED}"

if [[ ! -s "${ASSEMBLED}" ]]; then
  echo "ERROR: assembled 파일이 비어 있습니다: ${ASSEMBLED}" >&2
  exit 1
fi

if [[ -z "${PERSONA_FILE}" ]]; then
  echo "[assemble] WARN: persona 카드 누락 (worker=${WORKER_NAME}) — base template 만 주입되었습니다" >&2
fi

printf '%s\n' "${ASSEMBLED}"
