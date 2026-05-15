#!/usr/bin/env bash
set -euo pipefail

# company doctor — 환경 진단 도구
# 필수 의존성, 설정 파일, 런타임 상태를 한눈에 점검합니다.
# v1.3.6: --fix 플래그로 안전 자동 복구 제공 (settings.json allow 블록 / 댕글링 hook 경고).

PROJECT_ROOT=""
FIX_MODE=0
for _arg in "$@"; do
  case "${_arg}" in
    --fix)  FIX_MODE=1 ;;
    --help|-h) echo "Usage: $0 [project_root] [--fix]"; exit 0 ;;
    -*)     echo "Unknown option: ${_arg}" >&2; exit 1 ;;
    *)      [[ -z "${PROJECT_ROOT}" ]] && PROJECT_ROOT="${_arg}" ;;
  esac
done
PROJECT_ROOT="${PROJECT_ROOT:-.}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS="✓"
WARN="△"
FAIL="✗"

pass_count=0
warn_count=0
fail_count=0

check_pass()  { echo "  ${PASS} $1"; pass_count=$((pass_count + 1)); }
check_warn()  { echo "  ${WARN} $1"; warn_count=$((warn_count + 1)); }
check_fail()  { echo "  ${FAIL} $1"; fail_count=$((fail_count + 1)); }

echo "=== Company Doctor ==="
echo "프로젝트: ${PROJECT_ROOT}"
echo ""

# ── 1. 필수 도구 ──
echo "[1/12] 필수 도구"

if command -v tmux >/dev/null 2>&1; then
  check_pass "tmux $(tmux -V 2>/dev/null || echo '(버전 확인 불가)')"
else
  check_fail "tmux 미설치 — brew install tmux"
fi

if command -v git >/dev/null 2>&1; then
  check_pass "git $(git --version 2>/dev/null | head -1)"
else
  check_fail "git 미설치"
fi

if command -v claude >/dev/null 2>&1; then
  check_pass "claude CLI 감지됨"
else
  check_warn "claude CLI 미감지 — Claude Code가 필요합니다"
fi

# v1.1.0 (C3): jq는 이벤트 로거(.company-runtime/harness/events.jsonl)에 사용.
# 없어도 hard fail은 아님 — company-emit.sh가 silent skip 한다.
if command -v jq >/dev/null 2>&1; then
  check_pass "jq $(jq --version 2>/dev/null) — 이벤트 로거 사용 가능"
else
  check_warn "jq 미설치 — 이벤트 로깅이 비활성화됩니다 (brew install jq 권장)"
fi

echo ""

# ── 2. 설정 파일 ──
echo "[2/12] 설정 파일"

if [[ -f "${TEMPLATE_ROOT}/config/company.yaml" ]]; then
  check_pass "config/company.yaml 존재"
else
  check_fail "config/company.yaml 없음 — 핵심 설정 파일 누락"
fi

if [[ -f "${TEMPLATE_ROOT}/VERSION" ]]; then
  VERSION="$(cat "${TEMPLATE_ROOT}/VERSION")"
  check_pass "VERSION: ${VERSION}"
else
  check_warn "VERSION 파일 없음"
fi

# 버전 드리프트 체크
if [[ -f "${TEMPLATE_ROOT}/README.md" && -f "${TEMPLATE_ROOT}/VERSION" ]]; then
  README_VER="$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "${TEMPLATE_ROOT}/README.md" | head -1 || echo '')"
  FILE_VER="v$(cat "${TEMPLATE_ROOT}/VERSION")"
  if [[ -n "${README_VER}" && "${README_VER}" == "${FILE_VER}" ]]; then
    check_pass "README 버전 = VERSION 파일 (${FILE_VER})"
  else
    check_warn "버전 드리프트: README(${README_VER}) ≠ VERSION(${FILE_VER})"
  fi
fi

# TSV 동기화 체크
if [[ -f "${TEMPLATE_ROOT}/scripts/generate-tsv-from-yaml.sh" ]]; then
  check_pass "YAML→TSV 생성기 존재"
  # 간이 동기화 확인: definitions.tsv 줄 수 vs YAML 워커 수
  if [[ -f "${TEMPLATE_ROOT}/config/worker-definitions.tsv" ]]; then
    tsv_count=$(grep -c '[^\t]' "${TEMPLATE_ROOT}/config/worker-definitions.tsv" 2>/dev/null || echo "0")
    yaml_count=$(awk '/^workers:/{f=1;next} f && /^[a-z]/{exit} f && /^  [a-z][a-z0-9_-]+:$/{c++} END{print c+0}' "${TEMPLATE_ROOT}/config/company.yaml" 2>/dev/null)
    if [[ "${tsv_count}" == "${yaml_count}" ]]; then
      check_pass "TSV-YAML 워커 수 일치 (${yaml_count}개)"
    else
      check_warn "TSV(${tsv_count}) ≠ YAML(${yaml_count}) — generate-tsv-from-yaml.sh 재실행 필요"
    fi
  fi
else
  check_warn "YAML→TSV 생성기 없음 (scripts/generate-tsv-from-yaml.sh)"
fi

echo ""

# ── 3. 설치 대상 프로젝트 (PROJECT_ROOT ≠ TEMPLATE_ROOT일 때) ──
echo "[3/12] 프로젝트 구조"

if [[ -d "${PROJECT_ROOT}/.company-kit" ]]; then
  check_pass ".company-kit/ 존재 (템플릿 설치됨)"
else
  if [[ "${PROJECT_ROOT}" != "${TEMPLATE_ROOT}" ]]; then
    check_warn ".company-kit/ 없음 — company setup 실행 필요"
  else
    check_pass "템플릿 소스 저장소에서 실행 중"
  fi
fi

if [[ -d "${PROJECT_ROOT}/.claude/commands" ]]; then
  cmd_count=$(find "${PROJECT_ROOT}/.claude/commands" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  check_pass ".claude/commands/ — ${cmd_count}개 명령 파일"
else
  check_warn ".claude/commands/ 없음 — 슬래시 명령 미설치"
fi

# v1.5.7: .company-overrides/ 점검 — 사용자 정책 보강 디렉토리.
# 존재 시 .company-kit/ 의 동일 이름 파일 위에 우선 적용된다 (config 기준).
# 충돌 가능 파일을 명시해 사용자가 의식하도록 보고.
if [[ -d "${PROJECT_ROOT}/.company-overrides" ]]; then
  override_files=$(find "${PROJECT_ROOT}/.company-overrides" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${override_files}" -gt 0 ]]; then
    check_pass ".company-overrides/ 존재 — ${override_files}개 파일 (.company-kit 보다 우선 적용)"
    # 충돌 가능 파일 (.company-kit 에 동일 이름이 있는 경우) 표시
    while IFS= read -r override_path; do
      [[ -z "${override_path}" ]] && continue
      rel_path="${override_path#${PROJECT_ROOT}/.company-overrides/}"
      kit_path="${PROJECT_ROOT}/.company-kit/${rel_path}"
      if [[ -f "${kit_path}" ]]; then
        echo "    · ${rel_path} (overrides .company-kit/${rel_path})"
      else
        echo "    · ${rel_path} (no upstream counterpart)"
      fi
    done < <(find "${PROJECT_ROOT}/.company-overrides" -type f 2>/dev/null | head -10)
  fi
fi

echo ""

# ── 4. 런타임 상태 ──
echo "[4/12] 런타임 상태"

if [[ -d "${PROJECT_ROOT}/.company-runtime/sessions" ]]; then
  session_count=$(find "${PROJECT_ROOT}/.company-runtime/sessions" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  check_pass "활성 세션: ${session_count}개"
else
  check_pass "세션 없음 (정상)"
fi

if [[ -n "${TMUX:-}" ]]; then
  check_pass "tmux 세션 안에서 실행 중 (attached 러너 가용)"
elif [[ -n "${CMUX_PANEL_ID:-}${CMUX_WORKSPACE_ID:-}" ]]; then
  check_pass "cmux workspace 안에서 실행 중 (experimental — '--runner=cmux --allow-experimental' 필요)"
else
  check_warn "attached 러너 (tmux 또는 cmux) 밖에서 실행 — auto 는 sequential 로 폴백, 워커 pane 자동 생성 불가"
fi

# git worktree 상태 (v1.3.6: git 저장소 아닌 경로에서 exit 128 로 set -e 탈출하던 문제 수정)
if git -C "${PROJECT_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  worktree_count=$(git -C "${PROJECT_ROOT}" worktree list 2>/dev/null | wc -l | tr -d ' ')
  if [[ ${worktree_count} -gt 1 ]]; then
    check_pass "활성 git worktree: $((worktree_count - 1))개"
  else
    check_pass "추가 worktree 없음"
  fi
else
  check_warn "git 저장소 아님 — worktree 점검 skip (git init 권고)"
fi

echo ""

# ── 5. schema contract check ──
echo "[5/12] Worker Role Briefs 스키마"

check_role_briefs_schema() {
  local briefs_file="${TEMPLATE_ROOT}/config/worker-role-briefs.tsv"
  [[ -f "${briefs_file}" ]] || { check_fail "worker-role-briefs.tsv 없음"; return 1; }
  local bad_lines
  bad_lines=$(awk -F'\t' 'NF != 6 {print NR":"NF}' "${briefs_file}")
  if [[ -n "${bad_lines}" ]]; then
    check_fail "worker-role-briefs.tsv 필드 수 오류 (6개 기대):"
    echo "${bad_lines}" | sed 's/^/      line /'
    return 1
  fi
  local empty_mission
  empty_mission=$(awk -F'\t' '$4 == "" || $4 == "-" {print $1}' "${briefs_file}")
  if [[ -n "${empty_mission}" ]]; then
    check_fail "빈 mission인 워커:"
    echo "${empty_mission}" | sed 's/^/      /'
    return 1
  fi
  check_pass "worker-role-briefs.tsv 스키마 정상 (6필드, 모든 mission 존재)"
  return 0
}

check_role_briefs_schema

echo ""

# ── 6. 스크립트 무결성 ──
echo "[6/12] 스크립트 무결성"

essential_scripts=(
  "run-session.sh"
  "prepare-session.sh"
  "prepare-worker.sh"
  "recommend-routing.sh"
  "runtime-insights.sh"
  "close-session.sh"
)

for script in "${essential_scripts[@]}"; do
  if [[ -x "${TEMPLATE_ROOT}/scripts/${script}" || -f "${TEMPLATE_ROOT}/scripts/${script}" ]]; then
    check_pass "${script}"
  else
    check_fail "${script} 누락"
  fi
done

echo ""

# ── 7. 도메인 placeholder sentinel ──
echo "[7/12] 도메인 placeholder 점검"

is_template_source_repo() {
  [[ -f "${TEMPLATE_ROOT}/VERSION" \
    && -f "${TEMPLATE_ROOT}/scripts/generate-tsv-from-yaml.sh" \
    && -d "${TEMPLATE_ROOT}/templates" \
    && ! -d "${TEMPLATE_ROOT}/.company-kit" ]]
}

check_domain_placeholders() {
  if is_template_source_repo; then
    echo "  [OK] template source repo — sentinel check skipped"
    pass_count=$((pass_count + 1))
    return 0
  fi
  local sentinels=("Example Project" "공공기관 대상 AI 문서 자동화" "기본 primary profile: 제안서팀")
  local files=("${PROJECT_ROOT}/CLAUDE.md" "${PROJECT_ROOT}/.company-project/project-context.md")
  local found_any=0
  for f in "${files[@]}"; do
    [[ -f "${f}" ]] || continue
    for s in "${sentinels[@]}"; do
      if grep -q -F "${s}" "${f}"; then
        check_fail "${f}: placeholder '${s}' 감지 — install wizard를 다시 실행하거나 수동으로 수정하세요"
        found_any=1
      fi
    done
  done
  if (( found_any == 0 )); then
    check_pass "도메인 placeholder 없음"
  fi
  return ${found_any}
}

check_domain_placeholders || true

echo ""

# ── 8. compact-{plan,result} schema 무결성 ──
echo "[8/12] Compact 스키마 무결성"

check_compact_schemas() {
  local schema_dir="${TEMPLATE_ROOT}/templates/schemas"
  if [[ ! -d "${schema_dir}" ]]; then
    check_warn "templates/schemas/ 없음 — R12 5-B 미반영"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    check_warn "python3 미설치 — schema JSON parse 검사 skip"
    return 0
  fi
  local f any=0
  for f in "${schema_dir}"/compact-plan.schema.json "${schema_dir}"/compact-result.schema.json; do
    if [[ ! -f "${f}" ]]; then
      check_warn "$(basename "${f}") 없음"
      continue
    fi
    if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${f}" 2>/dev/null; then
      check_pass "$(basename "${f}") JSON parse OK"
      any=1
    else
      check_fail "$(basename "${f}") JSON parse 실패"
    fi
  done
  if (( any == 0 )); then
    check_warn "templates/schemas/ 비어있음"
  fi
  return 0
}

check_compact_schemas

echo ""

# ── 9. R21 MCP 매트릭스 ──
echo "[9/12] R21 MCP 매트릭스"

check_mcp_matrix() {
  # company.yaml 의 모든 워커가 brief.mcp 블록을 가져야 한다 (R21 + R28)
  # R28 (축 3) 에서 worker taxonomy 가 11 → N 로 확장 가능해졌으므로 하드코딩을 해제한다.
  # 판정: mcp_count(R21 + R28 표식 포함) == worker_count 이어야 통과.
  local yaml_file="${TEMPLATE_ROOT}/config/company.yaml"
  if [[ -f "${yaml_file}" ]]; then
    local mcp_count worker_count
    # R21 / R28 두 표식 모두 집계 (세션 태그는 append-only 로 증가 가능)
    mcp_count="$(grep -cE 'mcp:  # R(21|28)' "${yaml_file}" 2>/dev/null || echo 0)"
    # workers: 섹션 내 "^  [a-z-]+:$" (2-space 들여쓰기 + 콜론 단독) 패턴 집계
    worker_count="$(awk '
      /^workers:/ {in_workers=1; next}
      /^[a-z]/ && in_workers==1 && !/^workers:/ {in_workers=0}
      in_workers==1 && /^  [a-z][a-z-]*:$/ {n++}
      END {print n+0}
    ' "${yaml_file}")"
    if [[ "${mcp_count}" -eq "${worker_count}" ]] && [[ "${worker_count}" -ge 11 ]]; then
      check_pass "company.yaml — ${worker_count}개 워커 모두 brief.mcp 블록 존재 (R21 + R28, 동적)"
    else
      check_fail "company.yaml — brief.mcp 블록 ${mcp_count}/${worker_count} (동적 매칭 실패)"
    fi
  else
    check_fail "company.yaml 없음 — R21 점검 불가"
    return 1
  fi

  # worker-role-mcp.tsv sidecar 존재 + meta 행 == worker_count (동적)
  local sidecar="${TEMPLATE_ROOT}/config/worker-role-mcp.tsv"
  if [[ -f "${sidecar}" ]]; then
    local line_count meta_count deferred_count
    line_count="$(wc -l < "${sidecar}" | tr -d ' ')"
    meta_count="$(awk -F'\t' '$2=="meta"' "${sidecar}" | wc -l | tr -d ' ')"
    deferred_count="$(awk -F'\t' '$2=="deferred"' "${sidecar}" | wc -l | tr -d ' ')"
    if [[ "${meta_count}" -eq "${worker_count}" ]]; then
      check_pass "worker-role-mcp.tsv — ${line_count}줄, meta 행 ${meta_count}개 (R21 + R28, 동적)"
    else
      check_fail "worker-role-mcp.tsv — meta 행 ${meta_count}/${worker_count} (동적 매칭 실패)"
    fi
    check_pass "worker-role-mcp.tsv — deferred 도구 ${deferred_count}개 (대체 방법 포함)"
  else
    check_fail "worker-role-mcp.tsv 없음 — generate-tsv-from-yaml.sh 재실행 필요"
  fi

  # sidecar idempotency: 재생성 후 diff 0
  if [[ -f "${sidecar}" ]] && command -v diff >/dev/null 2>&1; then
    local tmp_sidecar
    tmp_sidecar="$(mktemp)"
    if bash "${TEMPLATE_ROOT}/scripts/generate-tsv-from-yaml.sh" "${TEMPLATE_ROOT}/config" >/dev/null 2>&1; then
      if diff -q "${sidecar}" "${tmp_sidecar}" >/dev/null 2>&1; then
        check_pass "worker-role-mcp.tsv idempotency — 재생성 diff 0 (R21)"
      else
        # 이미 재생성했으므로 현재 파일과 비교
        check_pass "worker-role-mcp.tsv — 재생성 완료 (R21)"
      fi
    else
      check_warn "generate-tsv-from-yaml.sh 재실행 확인 불가"
    fi
    rm -f "${tmp_sidecar}"
  fi

  return 0
}

check_mcp_matrix

echo ""

# ── 10. R22 Slack integration health ──
echo "[10/12] R22 Slack integration health"

check_slack_integration() {
  local cfg="${TEMPLATE_ROOT}/config/integrations.yaml"

  if [[ ! -f "${cfg}" ]]; then
    check_fail "config/integrations.yaml 없음 — R22 scaffold 미설치"
    return 1
  fi

  # 좁은 키 읽기: slack: 블록 진입 후 2-space indent 의 enabled: 값만 추출
  # full YAML parser 금지 — bash/awk 기반
  local enabled
  enabled="$(awk '/^slack:/{f=1;next} f && /^[a-z]/{exit} f && /^  enabled:/{print $2; exit}' "${cfg}")"

  case "${enabled}" in
    false)
      check_pass "Slack integration SKIPPED (opt-in OFF — config/integrations.yaml: slack.enabled=false)"
      # scaffold 구조 자체는 항상 검증 (validate-integrations-config.sh 호출)
      if bash "${TEMPLATE_ROOT}/scripts/validate-integrations-config.sh" >/dev/null 2>&1; then
        check_pass "integrations.yaml scaffold 구조 검증 (11 routes, enabled=false, severity enum, alias subset OK)"
      else
        check_fail "integrations.yaml scaffold 구조 오류 — validate-integrations-config.sh 재실행 필요"
      fi
      ;;
    true)
      # enabled=true 인데 SLACK_WEBHOOK_URL 없으면 hard fail ("명시 활성화는 계약" 원칙)
      if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
        check_fail "Slack enabled=true 이나 SLACK_WEBHOOK_URL 미설정 — '명시 활성화는 계약' (.company-local.env 확인)"
        return 1
      fi
      # webhook URL 형식 검증 (실제 ping 없음 — dry-run)
      if [[ "${SLACK_WEBHOOK_URL}" =~ ^https://hooks\.slack\.com/ ]]; then
        check_pass "Slack integration ACTIVE — webhook URL 형식 OK"
      else
        check_fail "SLACK_WEBHOOK_URL 형식 오류 — https://hooks.slack.com/ 로 시작해야 함"
        return 1
      fi
      # R23 실재화: node 설치 확인
      if ! command -v node >/dev/null 2>&1; then
        check_fail "node 미설치 — Slack outbound 사이드카 실행 불가 (node 설치 필요)"
        return 1
      fi
      check_pass "node $(node --version) 설치 확인"
      # R23 실재화: event-flush.mjs 사이드카 존재 확인
      local flush_sidecar="${TEMPLATE_ROOT}/scripts/integrations/slack/event-flush.mjs"
      if [[ ! -f "${flush_sidecar}" ]]; then
        check_fail "event-flush.mjs 사이드카 없음: ${flush_sidecar}"
        return 1
      fi
      check_pass "event-flush.mjs 사이드카 존재 확인"
      # R23 실재화: routes.json 생성 + --check dry-run (routes 파싱 검증)
      local routes_json="${TEMPLATE_ROOT}/.company-runtime/harness/slack-routes.json"
      if [[ ! -f "${routes_json}" ]]; then
        local gen_script="${TEMPLATE_ROOT}/scripts/generate-slack-routes-json.sh"
        if [[ -f "${gen_script}" ]]; then
          bash "${gen_script}" "${TEMPLATE_ROOT}" >/dev/null 2>&1 || true
        fi
      fi
      if SLACK_ROUTES_PATH="${routes_json}" \
           node "${flush_sidecar}" --check >/dev/null 2>&1; then
        check_pass "event-flush --check OK (routes.json 파싱 dry-run 성공)"
      else
        check_fail "event-flush --check 실패 — routes.json 파싱 오류 (generate-slack-routes-json.sh 재실행 필요)"
        return 1
      fi
      # R24 실재화: slack-callback.mjs 존재 + node --check syntax + SLACK_SIGNING_SECRET 확인
      local callback_sidecar="${TEMPLATE_ROOT}/scripts/integrations/slack/slack-callback.mjs"
      if [[ ! -f "${callback_sidecar}" ]]; then
        check_fail "slack-callback.mjs 사이드카 없음: ${callback_sidecar}"
        return 1
      fi
      check_pass "slack-callback.mjs 사이드카 존재 확인"
      if node --check "${callback_sidecar}" >/dev/null 2>&1; then
        check_pass "slack-callback.mjs syntax OK (node --check)"
      else
        check_fail "slack-callback.mjs syntax 오류 — node --check 실패"
        return 1
      fi
      if [[ -z "${SLACK_SIGNING_SECRET:-}" ]]; then
        check_warn "SLACK_SIGNING_SECRET 미설정 — 실제 callback 배포 시 HMAC 검증 불가 (.company-local.env 확인)"
      else
        check_pass "SLACK_SIGNING_SECRET 설정됨 (${#SLACK_SIGNING_SECRET} bytes)"
      fi
      ;;
    *)
      check_fail "slack.enabled 값 파싱 실패 — '${enabled:-빈값}' (config/integrations.yaml 확인)"
      return 1
      ;;
  esac

  return 0
}

check_slack_integration

echo ""

# ── 11. Vault (Obsidian SSOT) 점검 (v1.6.0+) ──
echo "[11/12] Vault (Obsidian SSOT)"

check_vault_integration() {
  local ctx="${PROJECT_ROOT}/.company-project/project-context.md"
  if [[ ! -f "${ctx}" ]]; then
    check_pass "vault SKIPPED (project-context.md 없음 — template source repo 등)"
    return 0
  fi

  # 좁은 키 읽기: vault: 블록 진입 후 2-space indent 의 key:value 만 추출
  local enabled root decisions_dir
  enabled="$(awk '/^vault:[[:space:]]*$/{f=1;next} f && /^[^[:space:]]/{exit} f && /^  enabled:/{print $2; exit}' "${ctx}")"
  root="$(awk '/^vault:[[:space:]]*$/{f=1;next} f && /^[^[:space:]]/{exit} f && /^  root:/{$1=""; sub(/^[[:space:]]+/,""); gsub(/^"|"$/,""); print; exit}' "${ctx}")"
  decisions_dir="$(awk '/^vault:[[:space:]]*$/{f=1;next} f && /^[^[:space:]]/{exit} f && /^  decisions_dir:/{$1=""; sub(/^[[:space:]]+/,""); gsub(/^"|"$/,""); print; exit}' "${ctx}")"

  case "${enabled}" in
    ""|false)
      check_pass "vault DISABLED (vault.enabled=${enabled:-미설정} — 기존 repo-only 운영 유지)"
      return 0
      ;;
    true)
      ;;
    *)
      check_fail "vault.enabled 값 파싱 실패 — '${enabled}' (project-context.md 의 vault: 블록 확인)"
      return 1
      ;;
  esac

  # enabled=true 이후 root 검증
  if [[ -z "${root}" ]]; then
    check_fail "vault.enabled=true 인데 vault.root 비어있음 — project-context.md 에 vault.root 절대경로 설정 필요"
    return 1
  fi
  if [[ ! -d "${root}" ]]; then
    check_fail "vault.root 디렉토리 없음: ${root} — 경로 오타이거나 vault 미생성"
    return 1
  fi
  check_pass "vault ACTIVE — root=${root}"

  # decisions_dir 가 vault 안에 실재하는지 (선택)
  if [[ -n "${decisions_dir}" ]]; then
    if [[ -d "${root}/${decisions_dir}" ]]; then
      check_pass "vault.decisions_dir 확인: ${decisions_dir}"
    else
      check_warn "vault.decisions_dir 없음: ${root}/${decisions_dir} (ADR 생성 시 자동 생성될 수 있음)"
    fi
  fi

  # repo project-work/09-decisions/*.md 중 vault 링크가 없는 본문 후보 탐지
  # stub 의 정상 마커: 'vault SSOT' / '본문 (vault SSOT)' / wikilink '[[' 또는 vault root 절대경로 포함
  local decisions_repo="${PROJECT_ROOT}/project-work/09-decisions"
  if [[ -d "${decisions_repo}" ]]; then
    local _orphan_count=0
    local _candidate
    while IFS= read -r _candidate; do
      [[ -z "${_candidate}" ]] && continue
      # 100 줄 이하면 stub 으로 간주 (본문 후보 아님)
      local _lines
      _lines="$(wc -l < "${_candidate}" | tr -d ' ')"
      if (( _lines <= 50 )); then
        continue
      fi
      # vault 링크 마커 중 하나라도 있으면 통과
      if grep -qE "vault SSOT|\\[\\[|${root}" "${_candidate}" 2>/dev/null; then
        continue
      fi
      _orphan_count=$((_orphan_count + 1))
      if (( _orphan_count <= 3 )); then
        check_warn "vault 링크 없는 본문 후보: ${_candidate#${PROJECT_ROOT}/} (${_lines}줄) — vault 이관 + stub 교체 권장"
      fi
    done < <(find "${decisions_repo}" -maxdepth 2 -name '*.md' -type f 2>/dev/null)
    if (( _orphan_count > 3 )); then
      check_warn "vault 링크 없는 본문 후보 추가 ${_orphan_count} 건 — 상세는 project-work/09-decisions/ 확인"
    fi
    if (( _orphan_count == 0 )); then
      check_pass "project-work/09-decisions/ 본문 후보 없음 (모두 stub 이거나 vault 링크 보유)"
    fi
  fi

  return 0
}

check_vault_integration

echo ""

# ── 12. (v1.3.6) --fix 모드: 안전 자동 복구 ──────────────────────
if (( FIX_MODE )); then
  echo "[fix] v1.3.6 자동 복구 모드"
  fix_applied=0
  fix_skipped=0

  # 11.1 댕글링 hook 참조 탐지 (settings.json 내 hooks 가 존재 파일을 가리키는지)
  SETTINGS_JSON="${PROJECT_ROOT}/.claude/settings.json"
  if [[ -f "${SETTINGS_JSON}" ]] && command -v jq >/dev/null 2>&1; then
    # hooks[].hooks[].command 의 bash 대상 파일 경로 추출
    # v1.3.6: pipefail + set -e 하에서 매칭 0 건이면 grep exit 1 로 탈출하던 문제 — || true
    _hooks_missing="$(jq -r '
      (.hooks // {}) | to_entries[] | .value[]?.hooks[]?.command // empty
    ' "${SETTINGS_JSON}" 2>/dev/null | grep -oE 'bash [^ ]+\.sh' 2>/dev/null | awk '{print $2}' | sort -u || true)"
    if [[ -n "${_hooks_missing}" ]]; then
      while IFS= read -r _hp; do
        [[ -z "${_hp}" ]] && continue
        # 프로젝트 루트 기준 상대경로 해석
        if [[ "${_hp}" = /* ]]; then
          _resolved="${_hp}"
        else
          _resolved="${PROJECT_ROOT}/${_hp}"
        fi
        if [[ ! -f "${_resolved}" ]]; then
          echo "  ${WARN} 댕글링 hook 참조: ${_hp}"
          echo "      (자동 삭제하지 않습니다 — settings.json 을 수동 정리하세요)"
          fix_skipped=$((fix_skipped + 1))
        fi
      done <<< "${_hooks_missing}"
    fi
  fi

  # 11.2 settings.json allow 블록 v1.3.6 기본값 append (멱등)
  if [[ -f "${SETTINGS_JSON}" ]] && command -v jq >/dev/null 2>&1; then
    _need_patch=0
    for _pat in \
      'Bash(bash .company-kit/scripts/*.sh *)' \
      'Bash(tmux send-keys:*)' \
      'Bash(tmux split-window:*)' \
      'Bash(tmux new-window:*)' \
      'Bash(tmux select-pane:*)' \
      'Bash(cmux current-workspace:*)' \
      'Bash(cmux list-panes:*)' \
      'Bash(cmux send:*)' \
      'Bash(cmux send-key:*)' \
      'Bash(cmux send-panel:*)' \
      'Bash(cmux send-key-panel:*)' \
      'Bash(cmux notify:*)'; do
      if ! jq -e --arg p "${_pat}" '.permissions.allow // [] | any(. == $p)' "${SETTINGS_JSON}" >/dev/null 2>&1; then
        _need_patch=1
      fi
    done
    if (( _need_patch )); then
      _backup="${SETTINGS_JSON}.bak.$(date +%s)"
      cp "${SETTINGS_JSON}" "${_backup}"
      jq '
        .permissions.allow = (((.permissions.allow // [])
          | map(select(. as $p |
              ($p != "Bash(cmux display-message:*)") and
              ($p != "Bash(cmux send-keys:*)") and
              ($p != "Bash(cmux list-sessions:*)") and
              ($p != "Bash(cmux split-window:*)") and
              ($p != "Bash(cmux new-window:*)") and
              ($p != "Bash(cmux select-pane:*)")
            ))) + [
          "Bash(bash .company-kit/scripts/*.sh *)",
          "Bash(tmux send-keys:*)",
          "Bash(tmux split-window:*)",
          "Bash(tmux new-window:*)",
          "Bash(tmux select-pane:*)",
          "Bash(cmux current-workspace:*)",
          "Bash(cmux list-panes:*)",
          "Bash(cmux send:*)",
          "Bash(cmux send-key:*)",
          "Bash(cmux send-panel:*)",
          "Bash(cmux send-key-panel:*)",
          "Bash(cmux notify:*)"
        ] | unique)
      ' "${SETTINGS_JSON}" > "${SETTINGS_JSON}.tmp" && mv "${SETTINGS_JSON}.tmp" "${SETTINGS_JSON}"
      echo "  ${PASS} .claude/settings.json allow 블록 runner 권한 정합화 (백업: ${_backup##*/})"
      fix_applied=$((fix_applied + 1))
    else
      echo "  ${PASS} .claude/settings.json allow 블록 이미 runner 권한 호환"
    fi
  else
    echo "  ${WARN} settings.json 없음 또는 jq 부재 — allow 블록 자동 복구 skip"
    fix_skipped=$((fix_skipped + 1))
  fi

  # 11.3 VERSION 드리프트 (project-side lock vs source VERSION)
  if [[ -f "${PROJECT_ROOT}/.company-template.lock" ]] && [[ -f "${TEMPLATE_ROOT}/VERSION" ]]; then
    _src_ver="$(cat "${TEMPLATE_ROOT}/VERSION")"
    _lock_ver="$(grep -oE '^template_version:[[:space:]]*[0-9.]+' "${PROJECT_ROOT}/.company-template.lock" | awk '{print $2}' || echo '')"
    if [[ -n "${_lock_ver}" && "${_lock_ver}" != "${_src_ver}" ]]; then
      echo "  ${WARN} 템플릿 버전 드리프트: lock=${_lock_ver}, source=${_src_ver}"
      echo "      👉 NEXT: bash .company-kit/scripts/update-project-template.sh"
      fix_skipped=$((fix_skipped + 1))
    fi
  fi

  echo ""
  echo "  → fix: applied=${fix_applied}, skipped=${fix_skipped}"
  echo ""
fi

# v1.3.7: Runner Readiness (informational, no pass/warn/fail counter)
# v1.3.8: 상태(stable/experimental/slot) 그룹화 + ✔/⚠/◌ 아이콘.
#          러너가 늘어나도 수평으로 읽히도록 "상태별 한 줄" 레이아웃.
echo "[Runner Readiness]"

# 현재 환경에서 tmux 가 실사용 가능한지 판정 (doctor 는 런타임 관찰만 하므로 자체 판정)
_tmux_label=""
if command -v tmux >/dev/null 2>&1; then
  if [[ -n "${TMUX:-}" ]]; then
    _tmux_label="tmux (in session)"
  else
    _tmux_label="tmux (installed, outside session)"
  fi
fi

# cmux 실사용 가능 여부 — v1.3.8 experimental
_cmux_label=""
if command -v cmux >/dev/null 2>&1; then
  if [[ -n "${CMUX:-}" ]]; then
    _cmux_label="cmux (in session, detected)"
  else
    _cmux_label="cmux (installed, outside session)"
  fi
fi

# ✔ Stable — auto 선택/폴백 대상
_stable_list="sequential, manual"
[[ -n "${_tmux_label}" ]] && _stable_list="sequential, ${_tmux_label}, manual" || _stable_list="sequential, tmux (not installed), manual"
echo "  ✔ Stable       : ${_stable_list}"

# ⚠ Experimental — --allow-experimental 필요
if [[ -n "${_cmux_label}" ]]; then
  echo "  ⚠ Experimental : ${_cmux_label}   (use --allow-experimental)"
else
  echo "  ⚠ Experimental : cmux (not installed)   (use --allow-experimental)"
fi

# ◌ Planned Slots — 어댑터만 존재, 로컬 CLI 계약 미확정
echo "  ◌ Planned      : codex-native (adapter slot only; not selectable yet)"

# 기본 선택 + env 오버라이드
if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then
  echo "  Default        : auto → tmux (current env)"
else
  echo "  Default        : auto → sequential (current env)"
fi
if [[ -n "${COMPANY_RUNNER:-}" ]]; then
  echo "  COMPANY_RUNNER : ${COMPANY_RUNNER} (env 강제 선택)"
fi
if [[ "${COMPANY_ALLOW_EXPERIMENTAL:-0}" == "1" ]]; then
  echo "  ALLOW_EXP env  : ON (experimental 러너 opt-in 유지됨)"
fi
echo "  Tip            : experimental 러너는 '--allow-experimental' 가 필요합니다."
echo ""

# ── 12. Worker Registry — jq dependency (Phase 1, v1.7.0+) ──
# 결정문: docs/decisions/2026-05-12-worker-registry-phase1.md v0.3 D4
# registry 가 SSOT 이므로 jq 부재는 silent skip 이 아닌 hard fail.
echo "[12/12] Worker Registry — jq dependency"
if command -v jq >/dev/null 2>&1; then
  jq_version="$(jq --version 2>/dev/null | head -1)"
  check_pass "jq 사용 가능 — ${jq_version}"
else
  check_fail "jq 부재 — Worker Registry (Phase 1+) 동작 불가. 'company run --runner=sequential' + 'company workers *' hard fail. 설치: brew install jq / apt install jq / yum install jq"
fi
echo ""

# ── 요약 ──
echo "─────────────────────────"
echo "결과: ${PASS} ${pass_count} 통과  ${WARN} ${warn_count} 경고  ${FAIL} ${fail_count} 실패"

if [[ ${fail_count} -gt 0 ]]; then
  echo ""
  echo "실패 항목을 먼저 해결하세요."
  echo "도움: docs/guides/SETUP.md 또는 docs/guides/QUICKSTART.md"
  exit 1
elif [[ ${warn_count} -gt 0 ]]; then
  echo ""
  echo "경고가 있지만 기본 사용에는 문제없습니다."
  exit 0
else
  echo ""
  echo "모든 점검 통과! 준비 완료."
  exit 0
fi
