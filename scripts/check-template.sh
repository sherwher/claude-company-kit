#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_ROOT="$(mktemp -d /tmp/team-profile-company-check.XXXXXX)"
PROJECT_ROOT="${TMP_ROOT}/project"

cleanup() {
  rm -rf "${TMP_ROOT}"
}

trap cleanup EXIT

bash "${KIT_DIR}/scripts/install-into-project.sh" "${PROJECT_ROOT}" \
  --name=TemplateCheck \
  --domain='template 점검 임시 프로젝트' \
  --stack=harness-smoke \
  --primary-worker=frontend-engineer \
  --supporting-workers=backend-engineer >/dev/null

for script_path in \
  "${KIT_DIR}/scripts/"*.sh
do
  bash -n "${script_path}"
done

git -C "${PROJECT_ROOT}" init -b main >/dev/null
git -C "${PROJECT_ROOT}" config user.name "Template Check"
git -C "${PROJECT_ROOT}" config user.email "template-check@example.com"
git -C "${PROJECT_ROOT}" add .
git -C "${PROJECT_ROOT}" commit -m "초기 템플릿 점검" >/dev/null

bash "${PROJECT_ROOT}/.company-kit/scripts/prepare-session.sh" "feature-check" "${PROJECT_ROOT}" >/dev/null
# v1.3.7: worker-request.md 가 러너별로 달라진다. 기존 expected 값은 tmux 러너 기준.
COMPANY_RUNNER=tmux bash "${PROJECT_ROOT}/.company-kit/scripts/prepare-worker.sh" "feature-check" "frontend-engineer" "${PROJECT_ROOT}" >/dev/null

test -f "${PROJECT_ROOT}/START_HERE.md"
test -f "${PROJECT_ROOT}/.gitignore"
test -f "${PROJECT_ROOT}/CLAUDE.md"
test -f "${PROJECT_ROOT}/.claude/settings.json"
test -f "${PROJECT_ROOT}/.claude/settings.local.example.json"
test -d "${PROJECT_ROOT}/.claude/commands"
test -f "${PROJECT_ROOT}/.company-kit/scripts/recommend-routing.sh"
test -f "${PROJECT_ROOT}/.company-kit/scripts/spawn-readiness-check.sh"
test -f "${PROJECT_ROOT}/.company-kit/scripts/spawn-telemetry-log.sh"
test -f "${PROJECT_ROOT}/.company-kit/scripts/runtime-insights.sh"
test -x "${PROJECT_ROOT}/.company-kit/scripts/quality-gate.sh"
test ! -e "${PROJECT_ROOT}/.company-kit/scripts/prepare-team.sh"
test ! -e "${PROJECT_ROOT}/.company-kit/scripts/tmux-team-spawn.sh"
test ! -e "${PROJECT_ROOT}/.company-kit/scripts/tmux-team-close.sh"
test -f "${PROJECT_ROOT}/.company-kit/templates/session-report.md"
test -f "${PROJECT_ROOT}/.company-kit/templates/approval-log.md"
test -f "${PROJECT_ROOT}/.company-kit/templates/promotion-log.md"
test -f "${PROJECT_ROOT}/.company-kit/templates/compact-plan.md"
test -f "${PROJECT_ROOT}/.company-kit/templates/compact-plan-prompt.md"
# R19 (축 1 / Phase 2): compact-plan v2 고밀도 템플릿 승격 검증
PLAN_TPL="${PROJECT_ROOT}/.company-kit/templates/compact-plan.md"
# 5 exact top-level headers
grep -Eq '^## Goal$' "${PLAN_TPL}"
grep -Eq '^## Steps$' "${PLAN_TPL}"
grep -Eq '^## Outputs$' "${PLAN_TPL}"
grep -Eq '^## Risks$' "${PLAN_TPL}"
grep -Eq '^## Questions$' "${PLAN_TPL}"
# top-level 정확히 5개
test "$(grep -Ec '^## ' "${PLAN_TPL}")" -eq 5
# R19 고밀도 구조 마커
grep -Eq '^### Trade-offs$' "${PLAN_TPL}"
grep -Eq '^\|[[:space:]]*전략[[:space:]]*\|[[:space:]]*장점[[:space:]]*\|[[:space:]]*단점[[:space:]]*\|[[:space:]]*결정 사유[[:space:]]*\|' "${PLAN_TPL}"
grep -Eq '\*\*(배제|채택)\*\*' "${PLAN_TPL}"
grep -Eq '^### Definition of Done$' "${PLAN_TPL}"
grep -Eq '^- \[[ x]\] ' "${PLAN_TPL}"
# [E] 인용 마커 최소 1회
grep -Eq '\[E[0-9]+\]' "${PLAN_TPL}"
# frontmatter mcp_footprints
grep -Eq '^mcp_footprints:$' "${PLAN_TPL}"
# retry/lock/timeout/idempotency 키워드 커버리지
grep -Eiq 'retry' "${PLAN_TPL}"
grep -Eiq 'lock' "${PLAN_TPL}"
grep -Eiq 'timeout' "${PLAN_TPL}"
grep -Eiq 'idempotency|멱등성' "${PLAN_TPL}"
# R19: compact-plan-prompt.md 톤 강화 검증
PROMPT_TPL="${PROJECT_ROOT}/.company-kit/templates/compact-plan-prompt.md"
grep -q '행동은 판단의 부산물' "${PROMPT_TPL}"
grep -q 'Self-Reject Trigger' "${PROMPT_TPL}"
grep -Eq '\[E1\]|\[E2\]|\[E3\]' "${PROMPT_TPL}"
# R20 (축 1 / Phase 2): compact-result v2 대칭 리디자인 검증
RESULT_TPL="${PROJECT_ROOT}/.company-kit/templates/compact-result.md"
# 8 exact top-level headers (close-session.sh L104/L121/L203/L205 파싱 계약)
grep -Eq '^## Summary$' "${RESULT_TPL}"
grep -Eq '^## Outputs$' "${RESULT_TPL}"
grep -Eq '^## Risks$' "${RESULT_TPL}"
grep -Eq '^## Next Action$' "${RESULT_TPL}"
grep -Eq '^## Evidence Delivered$' "${RESULT_TPL}"
grep -Eq '^## Plan Deviations$' "${RESULT_TPL}"
grep -Eq '^## Observed Unknown Kinds$' "${RESULT_TPL}"
grep -Eq '^## Next Hop$' "${RESULT_TPL}"
# top-level 정확히 8개
test "$(grep -Ec '^## ' "${RESULT_TPL}")" -eq 8
# R20 고밀도 구조 마커 (H3)
grep -Eq '^### Delivered Outputs$' "${RESULT_TPL}"
grep -Eq '^### Residual Risks$' "${RESULT_TPL}"
grep -Eq '^### Evidence[- ]Claim Matching$|^### Evidence Matching$' "${RESULT_TPL}"
# [E] 인용 최소 1회
grep -Eq '\[E[0-9]+\]' "${RESULT_TPL}"
# frontmatter mcp_footprints
grep -Eq '^mcp_footprints:$' "${RESULT_TPL}"
# retry/lock/timeout/idempotency 키워드 커버리지 (샘플 시나리오)
grep -Eiq 'retry' "${RESULT_TPL}"
grep -Eiq 'lock' "${RESULT_TPL}"
grep -Eiq 'timeout' "${RESULT_TPL}"
grep -Eiq 'idempotency|멱등성' "${RESULT_TPL}"
# R20: compact-result-prompt.md 신규 파일 존재 + 톤 강화 검증
RESULT_PROMPT="${PROJECT_ROOT}/.company-kit/templates/compact-result-prompt.md"
test -f "${RESULT_PROMPT}"
grep -q '결과는 설계의 증명' "${RESULT_PROMPT}"
grep -q 'Self-Reject Trigger' "${RESULT_PROMPT}"
grep -Eq '\[E1\]|\[E2\]|\[E3\]' "${RESULT_PROMPT}"
grep -Eq '판단의 수정 사유|판단의 정교화' "${RESULT_PROMPT}"
test -f "${PROJECT_ROOT}/.company-kit/templates/worker-system-prompt.md"
test -f "${PROJECT_ROOT}/.company-kit/templates/compact-result.md"
# v1.3.6: generate-project-agents.sh:268 이 README.md 를 생성하므로 존재가 정상.
# 과거 category 통합 agent 파일(company-engineering.md)은 현재 per-worker 로 분해됐으므로 부재가 정상.
test -f "${PROJECT_ROOT}/.claude/agents/README.md"
test ! -e "${PROJECT_ROOT}/.claude/agents/company-engineering.md"
test -f "${PROJECT_ROOT}/.company-project/model-policy.md"
test -f "${PROJECT_ROOT}/.company-kit/docs/guides/TOKEN_EFFICIENCY.md"
test -f "${PROJECT_ROOT}/.company-kit/docs/profiles-lite/engineering.md"
test -f "${PROJECT_ROOT}/.company-kit/templates/handoff-summary.md"
test -f "${PROJECT_ROOT}/.claude/commands/rw.md"
test -f "${PROJECT_ROOT}/.claude/commands/start-workstream.md"
test -f "${PROJECT_ROOT}/.claude/commands/run-workers.md"
test -f "${PROJECT_ROOT}/.claude/commands/spawn-worker.md"
test -f "${PROJECT_ROOT}/.claude/commands/route-topic.md"
test -f "${PROJECT_ROOT}/.claude/commands/record-routing-feedback.md"
test -f "${PROJECT_ROOT}/.claude/commands/check-project.md"
test -f "${PROJECT_ROOT}/.claude/commands/runtime-insights.md"
test -f "${PROJECT_ROOT}/.claude/commands/close-workstream.md"
test -f "${PROJECT_ROOT}/.claude/commands/help.md"
test ! -e "${PROJECT_ROOT}/.claude/commands/company/spawn-team.md"
test ! -e "${PROJECT_ROOT}/.claude/commands/company/rw.md"
test ! -e "${PROJECT_ROOT}/.claude/commands/company/run-workers.md"
grep -q '"teammateMode": "tmux"' "${PROJECT_ROOT}/.claude/settings.json"
# v1.3.6: scaffold settings.json:4 이 CLAUDE_THINKING_MODE 를 포함하므로 존재가 정상.
# hooks 섹션은 기본 settings 에는 두지 않고 사용자가 .claude/settings.local.json 로 확장한다.
grep -q 'CLAUDE_THINKING_MODE' "${PROJECT_ROOT}/.claude/settings.json"
! grep -q '"hooks"' "${PROJECT_ROOT}/.claude/settings.json"
grep -q 'Bash(cmux current-workspace:\*)' "${PROJECT_ROOT}/.claude/settings.json"
grep -q 'Bash(cmux list-panes:\*)' "${PROJECT_ROOT}/.claude/settings.json"
grep -q 'Bash(cmux send:\*)' "${PROJECT_ROOT}/.claude/settings.json"
grep -q 'Bash(cmux send-key:\*)' "${PROJECT_ROOT}/.claude/settings.json"
grep -q 'Bash(cmux send-panel:\*)' "${PROJECT_ROOT}/.claude/settings.json"
grep -q 'Bash(cmux send-key-panel:\*)' "${PROJECT_ROOT}/.claude/settings.json"
grep -q 'Bash(which npm:\*)' "${PROJECT_ROOT}/.claude/settings.json"
grep -q 'Bash(npm --version:\*)' "${PROJECT_ROOT}/.claude/settings.json"
grep -q 'Bash(npm run build:\*)' "${PROJECT_ROOT}/.claude/settings.json"
grep -q 'Bash(npm run typecheck:\*)' "${PROJECT_ROOT}/.claude/settings.json"
grep -q 'Bash(cmux notify:\*)' "${PROJECT_ROOT}/.claude/settings.json"
! grep -q 'Bash(cmux display-message:\*)' "${PROJECT_ROOT}/.claude/settings.json"
! grep -q 'Bash(cmux send-keys:\*)' "${PROJECT_ROOT}/.claude/settings.json"
! grep -q 'Bash(cmux list-sessions:\*)' "${PROJECT_ROOT}/.claude/settings.json"
grep -q 'run-session.sh' "${PROJECT_ROOT}/.claude/commands/run-workers.md"
grep -q '/run-workers' "${PROJECT_ROOT}/.claude/commands/rw.md"
grep -q '^\.company-kit/$' "${PROJECT_ROOT}/.gitignore"
grep -q '^\.company-runtime/$' "${PROJECT_ROOT}/.gitignore"
grep -q '^\.company-artifacts/$' "${PROJECT_ROOT}/.gitignore"
grep -q '^\.company-exports/$' "${PROJECT_ROOT}/.gitignore"
grep -q '^\.company-local.env$' "${PROJECT_ROOT}/.gitignore"
grep -q '^\.claude/settings\.local\.json$' "${PROJECT_ROOT}/.gitignore"
grep -q '^\.company-project/_template-updates/$' "${PROJECT_ROOT}/.gitignore"
grep -q '^\.codex/$' "${PROJECT_ROOT}/.gitignore"
grep -q '^\.omc/$' "${PROJECT_ROOT}/.gitignore"
grep -q '^firebase-debug\.log$' "${PROJECT_ROOT}/.gitignore"
grep -q 'company-project/integrations/\*\.env' "${PROJECT_ROOT}/.gitignore"
test -f "${PROJECT_ROOT}/.company-project/skills/enabled-packs.txt"
test -f "${PROJECT_ROOT}/.company-project/integrations/README.md"
test -f "${PROJECT_ROOT}/.company-project/integrations/notion.env"
test -f "${PROJECT_ROOT}/.company-project/integrations/google.env"
test -f "${PROJECT_ROOT}/.company-project/integrations/pencil.env"
test -f "${PROJECT_ROOT}/.company-project/integrations/notebooklm.env"
test -f "${PROJECT_ROOT}/.company-project/mcp/service-credentials.md"
test -f "${PROJECT_ROOT}/.company-project/mcp/service-usage-rules.md"
test -f "${PROJECT_ROOT}/.company-project/mcp/local-settings.example.json"
test -f "${PROJECT_ROOT}/.company-project/cost-mode.md"
test -f "${PROJECT_ROOT}/.company-project/routing-feedback.md"
test -f "${PROJECT_ROOT}/.company-project/project-standards.md"
test -f "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/session.env"
test -f "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/session-info.env"
test -f "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/load-env.sh"
test -f "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/leader-session.md"
test -f "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/leader-minimal.md"
test -f "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/session-report.md"
test -f "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/approval-log.md"
test -f "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/promotion-log.md"
test -f "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/context.md"
test -f "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/worker-request.md"
test -f "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/handoff-summary.md"
# v0.3-alpha B3 evidence 경로는 scripts/smoke-prepare-worker.sh 가 독립 검증한다 (R10 Phase 1).
# v1.1.0: compact-plan.md는 워커가 첫 Write 호출로 직접 생성한다 (HARNESS_V0 §4.1A).
# 따라서 prepare-worker 직후에는 존재하지 않는 것이 정상이다.
test ! -e "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/compact-plan.md"
# v1.5.6: compact-result.md도 워커가 종료 시 직접 Write로 생성한다. 템플릿 예시를
# 사전 복사하면 leader-wake/status가 실제 완료로 오인한다.
test ! -e "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/compact-result.md"
test -f "${PROJECT_ROOT}/project-work/03-frontend/frontend-architecture.md"
test -f "${PROJECT_ROOT}/project-work/00-project/working-agreements.md"
test -f "${PROJECT_ROOT}/project-work/00-project/code-conventions.md"
test -f "${PROJECT_ROOT}/project-work/08-reviews/review-checklist.md"
test -f "${PROJECT_ROOT}/project-work/09-decisions/decision-template.md"
grep -q "NOTION_ROOT_PAGE_ID" "${PROJECT_ROOT}/.company-project/integrations/notion.env"
grep -q "current_mode: balanced" "${PROJECT_ROOT}/.company-project/cost-mode.md"
grep -q "feedback=\`good\`" "${PROJECT_ROOT}/.company-project/routing-feedback.md"
grep -q "GOOGLE_CLIENT_ID" "${PROJECT_ROOT}/.company-project/integrations/google.env"
grep -q "PENCIL_CLI_PATH" "${PROJECT_ROOT}/.company-project/integrations/pencil.env"
grep -q "PENCIL_WORKSPACE_ID" "${PROJECT_ROOT}/.company-project/integrations/pencil.env"
grep -q "PENCIL_DEFAULT_FILE_PATH" "${PROJECT_ROOT}/.company-project/integrations/pencil.env"
grep -q "NOTEBOOKLM_MCP_NAME" "${PROJECT_ROOT}/.company-project/integrations/notebooklm.env"
grep -q "NOTEBOOKLM_MCP_TRANSPORT" "${PROJECT_ROOT}/.company-project/integrations/notebooklm.env"
grep -q "NOTEBOOKLM_MCP_COMMAND" "${PROJECT_ROOT}/.company-project/integrations/notebooklm.env"
grep -q "NOTEBOOKLM_ROOT_NOTEBOOK_ID" "${PROJECT_ROOT}/.company-project/integrations/notebooklm.env"
grep -q '"pencil": "mcp-primary-cli-secondary"' "${PROJECT_ROOT}/.company-project/mcp/local-settings.example.json"
grep -q '"notebooklm": "mcp-byo-http-or-stdio"' "${PROJECT_ROOT}/.company-project/mcp/local-settings.example.json"
grep -q '".company-project/integrations/notion.env"' "${PROJECT_ROOT}/.company-project/mcp/local-settings.example.json"
grep -Fq '.company-project/integrations/*.env' "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/load-env.sh"
grep -q "/rw <topic>" "${PROJECT_ROOT}/.company-kit/README.md"
grep -q "리더 전용 세션" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/leader-session.md"
grep -q "이 파일만 먼저 읽고 시작합니다" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/leader-minimal.md"
grep -q "기본 모델은 Opus" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/leader-session.md"
grep -q "Worker Model: Sonnet" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/context.md"
grep -q "추가 sub-agent를 기본적으로 스폰하지 않는다" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/context.md"
grep -q "현재 tmux 리더 세션에서" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/worker-request.md"
grep -q "Sonnet worker pane" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/worker-request.md"
grep -q "sub-agent" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/worker-request.md"
grep -q "compact-plan.md" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/worker-request.md"
# v1.1.0: 워커는 acceptEdits 모드로 스폰되며, 첫 도구 호출은 Write여야 한다.
grep -q "permission-mode acceptEdits" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/worker-request.md"
grep -q "첫 도구 호출" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/worker-request.md"
# v1.1.0 C1-hotfix: smoke test에서 발견된 3가지 구조적 제약 해결을 위한 플래그
grep -q -- "--add-dir" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/worker-request.md"
grep -q -- "--append-system-prompt-file" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/worker-request.md"
# R18 (축 1 / Phase 1): assemble-worker-prompt.sh 가 세션 스코프 assembled 파일을
# 생성하고, worker-request.md 가 그 절대경로를 --append-system-prompt-file 로
# 가리키는지 검증. 또한 assembled 본문에 base template 의 워커 규칙과 R17 페르소나
# 카드 본문(frontend-engineer → Jamie)이 모두 들어갔는지 확인한다.
test -f "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/worker-system-prompt.assembled.md"
grep -q "worker-system-prompt.assembled.md" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/worker-request.md"
grep -q "워커 운영 규칙" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/worker-system-prompt.assembled.md"
grep -q "페르소나 카드 (injected by assemble-worker-prompt.sh)" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/worker-system-prompt.assembled.md"
grep -q "Jamie" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/worker-system-prompt.assembled.md"
# R21 (축 1 / Phase 3) + R28 (축 3 / Phase B): worker-role-mcp.tsv sidecar + assembled.md 도구 기반 섹션 검증
# company.yaml 의 workers 수를 동적으로 집계하고 모든 워커가 brief.mcp 블록을 갖는지 확인.
# R28 에서 worker taxonomy 가 11 → N 으로 확장 가능해졌으므로 하드코딩 해제.
_COMPANY_YAML="${PROJECT_ROOT}/.company-kit/config/company.yaml"
[[ -f "${_COMPANY_YAML}" ]] || _COMPANY_YAML="${KIT_DIR}/config/company.yaml"
_WORKER_COUNT="$(awk '
  /^workers:/ {in_workers=1; next}
  /^[a-z]/ && in_workers==1 && !/^workers:/ {in_workers=0}
  in_workers==1 && /^  [a-z][a-z-]*:$/ {n++}
  END {print n+0}
' "${_COMPANY_YAML}" 2>/dev/null)"
test "${_WORKER_COUNT:-0}" -ge 11
# R21 / R28 두 표식 모두 집계 (append-only 로 증가 가능)
test "$(grep -cE 'mcp:  # R(21|28)' "${_COMPANY_YAML}" 2>/dev/null || echo 0)" -eq "${_WORKER_COUNT}"
# worker-role-mcp.tsv sidecar 존재 + 최소 줄 수 (worker_count × 3)
MCP_TSV=""
for _cand in \
  "${PROJECT_ROOT}/.company-kit/config/worker-role-mcp.tsv" \
  "${KIT_DIR}/config/worker-role-mcp.tsv"; do
  [[ -f "${_cand}" ]] && { MCP_TSV="${_cand}"; break; }
done
test -n "${MCP_TSV}"
test "$(wc -l < "${MCP_TSV}")" -ge "$((_WORKER_COUNT * 3))"
# sidecar meta 행 == worker_count (동적)
test "$(awk -F'\t' '$2=="meta"' "${MCP_TSV}" | wc -l | tr -d ' ')" -eq "${_WORKER_COUNT}"
# assembled.md R21 stamp + 도구 기반 섹션 확인
ASSEMBLED_FE="${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/worker-system-prompt.assembled.md"
grep -q '도구는 판단의 근거이며, 근거 없는 설계는 오염이다' "${ASSEMBLED_FE}"
grep -q '# 도구 기반' "${ASSEMBLED_FE}"
grep -q '## Preferred Tools' "${ASSEMBLED_FE}"
grep -q '## Self-Reject Trigger' "${ASSEMBLED_FE}"
# v1.1.0: context.md 하단에 5섹션 행동 지시문이 inline 주입되어야 한다.
grep -q "## Goal" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/context.md"
grep -q "## Steps" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/context.md"
grep -q "## Outputs" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/context.md"
grep -q "## Risks" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/context.md"
grep -q "## Questions" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/workers/frontend-engineer/context.md"
grep -q "리더 세션 기본 모델: Opus" "${PROJECT_ROOT}/.company-project/model-policy.md"
grep -q "agent teams pane" "${PROJECT_ROOT}/.company-project/model-policy.md"

# v1.4 Phase 1: model-policy.md 와 prepare-worker.sh 의 permission-mode 정합성
# (model-policy 가 acceptEdits + 파일 게이트 설계를 명시해야 한다)
grep -q "permission-mode acceptEdits" "${PROJECT_ROOT}/.company-project/model-policy.md"
grep -q "approval gate는 .*acceptEdits.*아니라 파일\|파일 게이트\|승인 게이트는 CLI" "${PROJECT_ROOT}/.company-project/model-policy.md"
# plan 모드 잘못 명시되는 회귀 차단
! grep -q -- "--permission-mode plan" "${PROJECT_ROOT}/.company-project/model-policy.md"
grep -q "If run inside an attached runner (tmux/cmux), current session name is used automatically." <(bash "${PROJECT_ROOT}/.company-kit/scripts/prepare-worker.sh" 2>&1 || true)

bash "${PROJECT_ROOT}/.company-kit/scripts/run-session.sh" "frontend 구조와 구현" "feature-check" "${PROJECT_ROOT}" >/dev/null
test -f "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/dispatch-summary.md"
grep -q "Primary Worker:" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/dispatch-summary.md"

# R11: outside-tmux fallback 경로 복구. `env -u TMUX` 로 tmux 세션명 자동 감지 경로를
# 제거해, run-session.sh 의 generate_session_id() 가 topic 기반 슬러그를 실제로 만드는지
# 검증한다. R10 P1에서는 run-session.sh L37 PROJECT_ROOT unbound pre-existing 버그 때문에
# 이 블록이 실패 상태로 이월되어 있었으나, R11에서 bug fix 후 재활성화.
env -u TMUX bash "${PROJECT_ROOT}/.company-kit/scripts/run-session.sh" "outside tmux fallback topic" "" "${PROJECT_ROOT}" >/dev/null
test -f "${PROJECT_ROOT}/.company-runtime/sessions/outside-tmux-fallback-topic/dispatch-summary.md"

env -u TMUX bash "${PROJECT_ROOT}/.company-kit/scripts/prepare-session.sh" "outside tmux direct topic" "${PROJECT_ROOT}" >/dev/null
test -f "${PROJECT_ROOT}/.company-runtime/sessions/outside-tmux-direct-topic/session.env"

WORKTREE_ENV="${PROJECT_ROOT}/.company-runtime/sessions/feature-check/session.env"
# shellcheck disable=SC1090
source "${WORKTREE_ENV}"
test -d "${WORKTREE_ROOT}"
test -L "${WORKTREE_ROOT}/.company-shared"
grep -qxF "/.company-shared" "$(git -C "${WORKTREE_ROOT}" rev-parse --git-dir)/info/exclude"

PACK_OUTPUT="$(bash "${PROJECT_ROOT}/.company-kit/scripts/resolve-skill-packs.sh" frontend-engineer "${PROJECT_ROOT}")"
printf '%s\n' "${PACK_OUTPUT}" | grep -q "Recommended Worker Packs: core,frontend,design,review"
printf '%s\n' "${PACK_OUTPUT}" | grep -q "Recommended Skills:"

ROUTE_OUTPUT="$(bash "${PROJECT_ROOT}/.company-kit/scripts/recommend-routing.sh" "결제 기능 프론트엔드 구조 설계" "${PROJECT_ROOT}")"
printf '%s\n' "${ROUTE_OUTPUT}" | grep -q "Cost Mode: balanced"
printf '%s\n' "${ROUTE_OUTPUT}" | grep -q "Auto Cost Hint:"
printf '%s\n' "${ROUTE_OUTPUT}" | grep -q "Recommended Primary Worker: frontend-engineer"
printf '%s\n' "${ROUTE_OUTPUT}" | grep -q "feedback_weight="
printf '%s\n' "${ROUTE_OUTPUT}" | grep -q "similar_feedback="
printf '%s\n' "${ROUTE_OUTPUT}" | grep -q "accuracy_weight="
printf '%s\n' "${ROUTE_OUTPUT}" | grep -q "Similar Session Pattern:"

# v1.4 Phase 1: 도메인 필터 출력 검증
# 비게임 프로젝트(default categories)는 Project Categories 행에 game 미포함,
# Excluded Categories 에 game 포함되어야 한다.
printf '%s\n' "${ROUTE_OUTPUT}" | grep -q "Project Categories:"
printf '%s\n' "${ROUTE_OUTPUT}" | grep -q "Excluded Categories:.*game"
# 메타/템플릿 효율 검토 토픽이 game-* 워커로 라우팅되지 않아야 한다
META_ROUTE="$(bash "${PROJECT_ROOT}/.company-kit/scripts/recommend-routing.sh" "템플릿 효율 검토 회고 메타" "${PROJECT_ROOT}")"
! printf '%s\n' "${META_ROUTE}" | grep -qE "Recommended Primary Worker: game-"
# 명시적 게임 키워드도 비게임 프로젝트에서는 game-* 로 라우팅되지 않는다
GAME_TOPIC_ROUTE="$(bash "${PROJECT_ROOT}/.company-kit/scripts/recommend-routing.sh" "Unity 셰이더 최적화" "${PROJECT_ROOT}")"
! printf '%s\n' "${GAME_TOPIC_ROUTE}" | grep -qE "Recommended Primary Worker: (game-|unity-|unreal-|level-|narrative-|technical-artist)"

# v1.4 Phase 2: Lane 라벨 출력
printf '%s\n' "${ROUTE_OUTPUT}" | grep -qE "^Lane: (micro|standard|deep)$"
# balanced 보수화: 매칭 키워드 1개뿐인 토픽은 supporting=none 이어야 한다.
LOW_MATCH_ROUTE="$(bash "${PROJECT_ROOT}/.company-kit/scripts/recommend-routing.sh" "프론트엔드 작업" "${PROJECT_ROOT}")"
printf '%s\n' "${LOW_MATCH_ROUTE}" | grep -qE "^Supporting Workers: none$"
printf '%s\n' "${LOW_MATCH_ROUTE}" | grep -qE "^Supporting Skip Reason:.*(보수화|cost_mode|적합 supporting)"

# v1.4 Phase 2: sentinel-scan 의 subagent 누수 감지
# fixture 파일을 만들고 SUBAGENT-LEAK 경고 라인이 출력되는지 확인
LEAK_SESSION="leak-fixture"
LEAK_DIR="${PROJECT_ROOT}/.company-runtime/sessions/${LEAK_SESSION}/workers/test-worker"
mkdir -p "${LEAK_DIR}"
cat > "${LEAK_DIR}/compact-result.md" <<'LEAK_EOF'
# Compact Result
## Summary
워커가 Agent(Task("explore code")) 와 oh-my-claudecode:executor 를 호출했음.
## Outputs
EnterPlanMode 로 plan 모드 전환 시도.
LEAK_EOF
LEAK_SCAN="$(bash "${PROJECT_ROOT}/.company-kit/scripts/sentinel-scan.sh" "${LEAK_SESSION}" "${PROJECT_ROOT}" --dry-run 2>&1 || true)"
printf '%s\n' "${LEAK_SCAN}" | grep -q "SUBAGENT-LEAK"
printf '%s\n' "${LEAK_SCAN}" | grep -q "Sonnet worker 비용 제한 우회"

# v1.4 Phase 3: compact-result 템플릿에 AC 라벨 + resume snippet 존재
test -f "${PROJECT_ROOT}/.company-kit/templates/compact-result.md"
grep -q "| AC | Verdict | Evidence ID" "${PROJECT_ROOT}/.company-kit/templates/compact-result.md"
grep -q "Resume Snippet" "${PROJECT_ROOT}/.company-kit/templates/compact-result.md"
grep -q "resume-worker.sh" "${PROJECT_ROOT}/.company-kit/templates/compact-result.md"

bash "${PROJECT_ROOT}/.company-kit/scripts/record-routing-feedback.sh" "결제 기능 프론트엔드 구조 설계" "frontend-engineer" "good" "${PROJECT_ROOT}" "service-planner" >/dev/null
grep -q "frontend-engineer" "${PROJECT_ROOT}/.company-project/routing-feedback.md"

STATUS_OUTPUT="$(cd "${PROJECT_ROOT}" && bash .company-kit/scripts/claude-tmux-statusline.sh)"
printf '%s\n' "${STATUS_OUTPUT}" | grep -q "project:project"

bash "${PROJECT_ROOT}/.company-kit/scripts/close-session.sh" "feature-check" "${PROJECT_ROOT}" --cleanup-worktree >/dev/null
test -f "${PROJECT_ROOT}/.company-runtime/pattern-memory/session-history.tsv"
test -f "${PROJECT_ROOT}/.company-runtime/telemetry/spawn-telemetry.tsv"
grep -q "Session ID: feature-check" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/session-report.md"
grep -q "Compact Results:" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/session-report.md"
grep -q "Worker Outputs:" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/session-report.md"
grep -q "Approval Summary:" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/session-report.md"
grep -q "Promotion Status:" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/session-report.md"
grep -q "Spawn Success Rate:" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/session-report.md"
grep -q "## Close Checklist" "${PROJECT_ROOT}/.company-runtime/sessions/feature-check/session-report.md"

INSIGHTS_OUTPUT="$(bash "${PROJECT_ROOT}/.company-kit/scripts/runtime-insights.sh" "${PROJECT_ROOT}")"
printf '%s\n' "${INSIGHTS_OUTPUT}" | grep -q "# Runtime Insights"
printf '%s\n' "${INSIGHTS_OUTPUT}" | grep -q "## Recent Sessions"
printf '%s\n' "${INSIGHTS_OUTPUT}" | grep -q "## Cost Mode Distribution"
printf '%s\n' "${INSIGHTS_OUTPUT}" | grep -q "## Worker Feedback Snapshot"
printf '%s\n' "${INSIGHTS_OUTPUT}" | grep -q "## Worker Recommendation Accuracy"
printf '%s\n' "${INSIGHTS_OUTPUT}" | grep -q "## Recent Spawn Failures"

# R22 (축 2 / Phase 4): notification-policy 정본 + integrations scaffold 검증
# 기존 R17~R21 assertion 수정 0 건 — append only

# notification-policy.md 존재 + 11 canonical 이벤트 전수 등장
POLICY_DOC="${KIT_DIR}/docs/operations/notification-policy.md"
test -f "${POLICY_DOC}"
for _ev in spawn_prepared spawn_success spawn_failure approval_required \
           plan_validated approved rejected compact_result_ready \
           export_promoted sentinel_detected worker_timeout; do
  grep -q "${_ev}" "${POLICY_DOC}"
done
# R22 직인 문자열 존재
grep -q '신호는 많음이 아니라 도달로 증명되며' "${POLICY_DOC}"

# config/integrations.yaml scaffold
INTEG_YAML="${KIT_DIR}/config/integrations.yaml"
test -f "${INTEG_YAML}"
grep -q 'enabled: false' "${INTEG_YAML}"
grep -q 'bot_name:' "${INTEG_YAML}"
# 11 routes 전수 존재
for _ev in spawn_prepared spawn_success spawn_failure approval_required \
           plan_validated approved rejected compact_result_ready \
           export_promoted sentinel_detected worker_timeout; do
  grep -q "    ${_ev}:" "${INTEG_YAML}"
done

# scripts/integrations/slack/README.md 존재 + "R22 계약" 문자열
SLACK_README="${KIT_DIR}/scripts/integrations/slack/README.md"
test -f "${SLACK_README}"
grep -q "R22 계약" "${SLACK_README}"

# .company-local.env.example 에 Slack env key 가이드 존재
grep -q "SLACK_WEBHOOK_URL" "${KIT_DIR}/.company-local.env.example"

# 소스 .gitignore R22 블록 — .company-local.env 차단 + .example 예외
grep -q '^\.company-local\.env$' "${KIT_DIR}/.gitignore"
grep -q '^!\.company-local\.env\.example$' "${KIT_DIR}/.gitignore"

# validate-integrations-config.sh 존재 + 실행 PASS
test -f "${KIT_DIR}/scripts/validate-integrations-config.sh"
bash "${KIT_DIR}/scripts/validate-integrations-config.sh" >/dev/null

# Telegram 미착수 확인 (R24 범위 경계)
test ! -d "${KIT_DIR}/scripts/integrations/telegram"
! grep -q '^telegram:' "${INTEG_YAML}"

# R23 (축 2 / Phase 4): Slack outbound 실재화 assertion
# 기존 R17~R22 assertion 수정 0 건 — append only

# event-flush.mjs 이관본 존재 + --once 문자열 포함
FLUSH_MJS="${KIT_DIR}/scripts/integrations/slack/event-flush.mjs"
test -f "${FLUSH_MJS}"
grep -q '\-\-once' "${FLUSH_MJS}"
grep -q '\-\-check' "${FLUSH_MJS}"

# generate-slack-routes-json.sh 존재
test -f "${KIT_DIR}/scripts/generate-slack-routes-json.sh"

# smoke-slack-dispatch.sh 존재
test -f "${KIT_DIR}/scripts/smoke-slack-dispatch.sh"
test -f "${KIT_DIR}/scripts/cmux-lib.sh"

# prepare-worker.sh 에 spawn_success 문자열
grep -q 'spawn_success' "${KIT_DIR}/scripts/prepare-worker.sh"
test -f "${KIT_DIR}/scripts/cmux-start-worker.sh"
test -f "${KIT_DIR}/scripts/cmux-submit-worker-message.sh"

# company-approve.sh 에 plan_validated 문자열 + rejected 문자열 + --reject 플래그
grep -q 'plan_validated' "${KIT_DIR}/scripts/company-approve.sh"
grep -q 'rejected' "${KIT_DIR}/scripts/company-approve.sh"
grep -q '\-\-reject' "${KIT_DIR}/scripts/company-approve.sh"

# company-emit.sh 에 R23 one-shot flush hook 문자열
grep -q '_R23_slack_one_shot_flush' "${KIT_DIR}/scripts/company-emit.sh"

# doctor.sh ACTIVE 분기에 R23 실재화 — event-flush --check 호출 문자열
grep -q 'event-flush.mjs' "${KIT_DIR}/scripts/doctor.sh"
grep -q '\-\-check' "${KIT_DIR}/scripts/doctor.sh"

# R24 (축 2 / Phase 4): Slack callback + approval_required + mock E2E assertion
# 기존 R17~R23 assertion 수정 0 건 — append only

# slack-callback.mjs 이관본 존재 + R24 이관본 표식 주석
CALLBACK_MJS="${KIT_DIR}/scripts/integrations/slack/slack-callback.mjs"
test -f "${CALLBACK_MJS}"
grep -q 'R24 이관본' "${CALLBACK_MJS}"
# 한국어 §5 패치 키워드 7 개소 (대상 파일 CALLBACK_MJS 고정 — 교차 오검 방지)
grep -q '만료된 계획서' "${CALLBACK_MJS}"
grep -q '이미 처리 중인 요청' "${CALLBACK_MJS}"
grep -q '승인 실패. 원격 서버' "${CALLBACK_MJS}"
grep -q '승인 완료. 요청을 정상 처리' "${CALLBACK_MJS}"
grep -q '거절 완료. 요청을 정상 처리' "${CALLBACK_MJS}"
grep -q '시스템 오류. 잠시 후 다시' "${CALLBACK_MJS}"
grep -q '보안 세션이 만료' "${CALLBACK_MJS}"
# node --check syntax 무결성 (R24 게이트 13)
node --check "${CALLBACK_MJS}"

# smoke-slack-callback.mjs 존재 + 4 시나리오 pass (R24 게이트 12)
SMOKE_CALLBACK="${KIT_DIR}/scripts/smoke-slack-callback.mjs"
test -f "${SMOKE_CALLBACK}"
node "${SMOKE_CALLBACK}"

# company-approve.sh 에 approval_required 문자열
grep -q 'approval_required' "${KIT_DIR}/scripts/company-approve.sh"

# notification-policy §13 R24 정정 로그 섹션 존재
grep -q '## 13. R24 정정 로그' "${KIT_DIR}/docs/operations/notification-policy.md"

# slack-callback-notes.md 존재 (HTTP 런타임 경계 선언)
test -f "${KIT_DIR}/scripts/integrations/slack/slack-callback-notes.md"

# R25 Phase 4a (축 2): export_promoted + thread_ts persist + 수동 검증 가이드
# 기존 R17~R24 assertion 수정 0 건 — append only
# close-session.sh 에 export_promoted emit 블록 존재
grep -q '"export_promoted"' "${KIT_DIR}/scripts/close-session.sh"
grep -q 'R25 Phase 4a' "${KIT_DIR}/scripts/close-session.sh"
# slack-callback.mjs 에 persistSlackThread 함수 + R25 §6 표식
grep -q 'persistSlackThread' "${CALLBACK_MJS}"
grep -q 'R25 Phase 4a §6' "${CALLBACK_MJS}"
grep -q 'slack-thread.env' "${CALLBACK_MJS}"
# 실 workspace 수동 검증 가이드 존재
test -f "${KIT_DIR}/scripts/integrations/slack/MANUAL_VERIFY.md"

# R26 Phase 4b (축 2): sentinel-scan + timeout-watchdog + event-flush thread_ts 주입 + drift 영구화
# 기존 R17~R25 assertion 수정 0 건 — append only
# sentinel-scan.sh 신규 파일 + 패턴 집합
SENTINEL_SCAN="${KIT_DIR}/scripts/sentinel-scan.sh"
test -f "${SENTINEL_SCAN}"
grep -q 'sentinel_detected' "${SENTINEL_SCAN}"
grep -q 'TODO|FIXME|XXX|PLACEHOLDER' "${SENTINEL_SCAN}"
# timeout-watchdog.sh 신규 파일 + worker_timeout emit
TIMEOUT_WATCHDOG="${KIT_DIR}/scripts/timeout-watchdog.sh"
test -f "${TIMEOUT_WATCHDOG}"
grep -q 'worker_timeout' "${TIMEOUT_WATCHDOG}"

# v1.4.2 docs/runtime contract drift guards
grep -q 'v1.4.2' "${KIT_DIR}/README.md"
grep -q '현재 상태 (v1.4.2)' "${KIT_DIR}/ROADMAP.md"
grep -q 'Summary / Outputs / Risks / Next Action / Evidence Delivered / Plan Deviations / Observed Unknown Kinds / Next Hop (8)' "${KIT_DIR}/docs/guides/QUICKSTART.md"
grep -q 'company status' "${KIT_DIR}/docs/guides/QUICKSTART.md"
grep -q '\.company-artifacts/' "${KIT_DIR}/scaffold/project-root-sample/START_HERE.md"
! grep -q '\.company/artifacts/' "${KIT_DIR}/scaffold/project-root-sample/START_HERE.md"
! grep -q '\.company/artifacts/' "${KIT_DIR}/docs/standards/PROMOTION_RULES.md"
grep -q 'codex-native (adapter slot only; not selectable yet)' "${KIT_DIR}/scripts/doctor.sh"
grep -q 'company quality' "${KIT_DIR}/scripts/company"
grep -q 'sentinel-scan.sh' "${KIT_DIR}/scripts/close-session.sh"
grep -q 'validate-compact-schemas.sh' "${KIT_DIR}/scripts/close-session.sh"
test -x "${KIT_DIR}/scripts/quality-gate.sh"
grep -q 'R24 D1 연장' "${TIMEOUT_WATCHDOG}"
# event-flush.mjs 에 maybeAttachThreadTs 함수 + R26 §ᗄ 표식
EVENT_FLUSH="${KIT_DIR}/scripts/integrations/slack/event-flush.mjs"
grep -q 'maybeAttachThreadTs' "${EVENT_FLUSH}"
grep -q 'R26 Phase 4b' "${EVENT_FLUSH}"
# smoke-sentinel-scan.sh + smoke-timeout-watchdog.sh 존재 + 실행
test -f "${KIT_DIR}/scripts/smoke-sentinel-scan.sh"
test -f "${KIT_DIR}/scripts/smoke-timeout-watchdog.sh"
bash "${KIT_DIR}/scripts/smoke-sentinel-scan.sh" >/dev/null
bash "${KIT_DIR}/scripts/smoke-timeout-watchdog.sh" >/dev/null
# smoke-slack-dispatch 에 R26 thread_ts 검증 블록 존재
grep -q 'R26 Phase 4b' "${KIT_DIR}/scripts/smoke-slack-dispatch.sh"
grep -q 'thread_ts 주입 확인' "${KIT_DIR}/scripts/smoke-slack-dispatch.sh"
# notification-policy §14 R26 drift 영구화 결정 섹션 존재
grep -q '## 14. R26 드리프트 영구화 결정' "${KIT_DIR}/docs/operations/notification-policy.md"

# v1.3.7: runner abstraction 기본 파일/스키마 검증
test -f "${KIT_DIR}/scripts/runner-lib.sh"
test -d "${KIT_DIR}/scripts/runners"
test -f "${KIT_DIR}/scripts/runners/sequential.sh"
test -f "${KIT_DIR}/scripts/runners/tmux.sh"
test -f "${KIT_DIR}/scripts/runners/manual.sh"
test -f "${KIT_DIR}/scripts/runners/cmux.sh"
test -f "${KIT_DIR}/scripts/runners/codex-native.sh"
test -x "${KIT_DIR}/tests/fixtures/fake-cmux/cmux"
grep -q "(k.1)" "${KIT_DIR}/scripts/smoke-runner.sh"
grep -q "(k.2)" "${KIT_DIR}/scripts/smoke-runner.sh"
grep -q "(k.3)" "${KIT_DIR}/scripts/smoke-runner.sh"
grep -q "(k.4)" "${KIT_DIR}/scripts/smoke-runner.sh"
grep -q "(k.5)" "${KIT_DIR}/scripts/smoke-runner.sh"
grep -q "(k.6)" "${KIT_DIR}/scripts/smoke-runner.sh"
# 설치본에도 동일하게 전파됐는지
test -f "${PROJECT_ROOT}/.company-kit/scripts/runner-lib.sh"
test -d "${PROJECT_ROOT}/.company-kit/scripts/runners"
test -f "${PROJECT_ROOT}/.company-kit/scripts/runners/sequential.sh"
test -f "${PROJECT_ROOT}/.company-kit/scripts/runners/tmux.sh"
test -f "${PROJECT_ROOT}/.company-kit/scripts/runners/manual.sh"
# resolve_runner + preflight 경로 smoke: sequential 강제, fallback 없이 성공해야 함
RUNNER_SMOKE="${TMP_ROOT}/runner-smoke"
mkdir -p "${RUNNER_SMOKE}"
(
  set -euo pipefail
  unset TMUX
  source "${KIT_DIR}/scripts/runner-lib.sh"
  resolve_runner --runner=sequential
  [[ "${RUNNER_SELECTED}" == "sequential" ]]
  [[ "${RUNNER_SOURCE}" == "flag" ]]
  runner_write_preflight "${RUNNER_SMOKE}" "rs-1" >/dev/null
  test -f "${RUNNER_SMOKE}/.company-runtime/sessions/rs-1/preflight.json"
  # 필수 키
  grep -q '"runner"' "${RUNNER_SMOKE}/.company-runtime/sessions/rs-1/preflight.json"
  grep -q '"runner_source"' "${RUNNER_SMOKE}/.company-runtime/sessions/rs-1/preflight.json"
  grep -q '"parallel_available"' "${RUNNER_SMOKE}/.company-runtime/sessions/rs-1/preflight.json"
)
# --no-fallback 시 불가 러너는 비 0 이어야 함
(
  unset TMUX
  # runner-lib.sh 가 `set -euo pipefail` 을 켜므로 source 이후에 set +e 로 해제한다.
  source "${KIT_DIR}/scripts/runner-lib.sh"
  set +e
  resolve_runner --runner=cmux --no-fallback >/dev/null 2>&1
  _rc=$?
  set -e
  [[ "${_rc}" != "0" ]]
)

printf 'Template check passed.\n'
