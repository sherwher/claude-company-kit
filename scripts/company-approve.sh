#!/usr/bin/env bash
set -euo pipefail

# company-approve.sh — 리더가 워커의 compact-plan을 승인할 때 호출.
# 승인 시 .company-runtime/sessions/<id>/approved 빈 마커 파일을 생성하고,
# close-session.sh의 severity 게이트가 이 마커를 읽어 promotion 분기를 결정한다.
#
# v1.1.0: HARNESS_V0 §4.1 (C) 구현.

SESSION_ID="${1:-}"
ROOT="${2:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# R23 (축 2): --reject / --force 플래그 파싱
# 기존 ${3:-} 직접 참조를 플래그 변수로 대체 (하위 호환 유지)
# v1.5.0: --scope 추가 — 외부 서비스 write 만 위임 승인하는 경량 경로.
_REJECT_MODE=0
_FORCE_MODE=0
_SCOPE=""
for _flag in "${@:3}"; do
  case "${_flag}" in
    --reject)    _REJECT_MODE=1 ;;
    --force)     _FORCE_MODE=1  ;;
    --scope=*)   _SCOPE="${_flag#--scope=}" ;;
    --scope)     ;; # 다음 인자에서 처리
  esac
done
# `--scope <value>` 분리 형태도 지원
_prev=""
for _flag in "${@:3}"; do
  if [[ "${_prev}" == "--scope" && -z "${_SCOPE}" ]]; then
    _SCOPE="${_flag}"
  fi
  _prev="${_flag}"
done

if [[ -z "${SESSION_ID}" ]]; then
  echo "Usage: $0 <session-id> [project-root] [--reject] [--force] [--scope <scope>]" >&2
  echo "" >&2
  echo "리더가 워커의 compact-plan을 승인 또는 거절할 때 사용합니다." >&2
  echo "  --reject     : plan 거절 (rejected emit, approved 마커 미생성)" >&2
  echo "  --force      : 검증 실패에도 불구하고 강제 승인" >&2
  echo "  --scope <s>  : compact-plan 전체가 아닌 특정 외부 write 액션만 위임 승인." >&2
  echo "                 형식: external_write:<service>:<resource>" >&2
  echo "                 예  : external_write:notion:page-create" >&2
  echo "                       external_write:slack:message-post" >&2
  echo "                       external_write:notion:* (서비스 단위 와일드카드)" >&2
  echo "                       external_write:* (전체 외부 write 단위 — 신중히)" >&2
  exit 1
fi

# shellcheck source=./git-worktree-lib.sh
source "${SCRIPT_DIR}/git-worktree-lib.sh"

PROJECT_ROOT="$(resolve_shared_project_root "${ROOT}")"
SESSION_DIR="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}"
APPROVED_MARKER="${SESSION_DIR}/approved"
APPROVAL_LOG="${SESSION_DIR}/approval-log.md"

if [[ ! -d "${SESSION_DIR}" ]]; then
  echo "Error: 세션이 존재하지 않습니다: ${SESSION_ID}" >&2
  echo "       먼저 'company run \"<topic>\"' 또는 prepare-session.sh 로 세션을 만드세요." >&2
  exit 2
fi

# v1.5.0: --scope 분기 — 외부 write 위임 승인 (compact-plan 검증 우회).
#   목적: "외부 서비스 write (Notion/Slack/Issue 등 비가역) 는 leader 승인 토큰을
#         받은 워커가 실행한다" 정책의 토큰 발행 경로. compact-plan 단위가 아니라
#         특정 액션 단위라서 plan validation / evidence validator 는 건너뛴다.
#   제약: scope prefix 는 'external_write:' 만 허용. 다른 prefix 는 거절.
#   효과:
#     - events.jsonl 에 external_write_approved 이벤트 emit
#       (필드: scope, service, resource, approver, idempotency_key)
#     - .company-runtime/sessions/<sid>/external-write-approvals.log 에 한 줄 기록
#     - approved 마커 (compact-plan 승인) 는 건드리지 않음 — 두 승인은 분리 관리
if [[ -n "${_SCOPE}" ]]; then
  if [[ "${_SCOPE}" != external_write:* ]]; then
    echo "Error: --scope 는 'external_write:' prefix 만 허용합니다 (받은 값: ${_SCOPE})" >&2
    exit 5
  fi
  # scope 분해: external_write:<service>:<resource>
  # service / resource 둘 다 와일드카드(*) 허용. resource 는 생략 가능 → '*'
  _scope_rest="${_SCOPE#external_write:}"
  _service="${_scope_rest%%:*}"
  if [[ "${_scope_rest}" == *":"* ]]; then
    _resource="${_scope_rest#*:}"
  else
    _resource="*"
  fi
  if [[ -z "${_service}" ]]; then
    echo "Error: --scope 의 service 부분이 비어 있습니다 (예: external_write:notion:page-create)" >&2
    exit 5
  fi

  _now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _idem="${SESSION_ID}:external_write:${_service}:${_resource}:${_now_iso}"

  bash "${SCRIPT_DIR}/company-emit.sh" "external_write_approved" "${SESSION_ID}" "${PROJECT_ROOT}" \
    "scope=${_SCOPE}" \
    "service=${_service}" \
    "resource=${_resource}" \
    "approver=${USER:-leader}" \
    "idempotency_key=${_idem}" \
    >/dev/null 2>&1 || true

  _ext_log="${SESSION_DIR}/external-write-approvals.log"
  printf '%s\tscope=%s\tservice=%s\tresource=%s\tapprover=%s\n' \
    "${_now_iso}" "${_SCOPE}" "${_service}" "${_resource}" "${USER:-leader}" \
    >> "${_ext_log}"

  echo "✓ 외부 write 승인 발행: ${_SCOPE}"
  echo "  service=${_service} resource=${_resource}"
  echo "  세션: ${SESSION_ID}"
  echo "  로그: ${_ext_log}"
  echo "👉 워커는 'bash scripts/check-external-write-approval.sh ${SESSION_ID} ${_SCOPE}' 로 토큰 확인 후 실제 호출을 진행할 수 있습니다."
  exit 0
fi

# compact-plan 사전 검증 — 워커가 5섹션을 채웠는지 확인
WORKERS_DIR="${SESSION_DIR}/workers"
plan_checked=0
plan_failed=0
if [[ -d "${WORKERS_DIR}" ]]; then
  while IFS= read -r worker_dir; do
    [[ -d "${worker_dir}" ]] || continue
    plan_file="${worker_dir}/compact-plan.md"
    worker_name="$(basename "${worker_dir}")"
    plan_checked=$((plan_checked + 1))
    if [[ ! -f "${plan_file}" ]]; then
      echo "FAIL: ${worker_name} — compact-plan.md 부재 (워커가 첫 Write 호출을 안 했습니다)" >&2
      plan_failed=$((plan_failed + 1))
      continue
    fi
    # 5섹션 헤더 + 본문 검증
    missing=""
    for section in "## Goal" "## Steps" "## Outputs" "## Risks" "## Questions"; do
      if ! grep -q "^${section}\b" "${plan_file}"; then
        missing="${missing} ${section}"
      fi
    done
    if [[ -n "${missing}" ]]; then
      echo "FAIL: ${worker_name} — compact-plan.md 누락 섹션:${missing}" >&2
      plan_failed=$((plan_failed + 1))
      continue
    fi
    # 라인 수 휴리스틱 (헤더 5 + 제목 1 + 최소 본문 5)
    lines=$(wc -l < "${plan_file}" | tr -d ' ')
    if [[ "${lines}" -lt 11 ]]; then
      echo "FAIL: ${worker_name} — compact-plan.md 본문이 너무 짧습니다 (${lines} lines, 최소 11 필요)" >&2
      plan_failed=$((plan_failed + 1))
      continue
    fi
    echo "PASS: ${worker_name} — compact-plan.md 검증 통과 (${lines} lines)"
  done < <(find "${WORKERS_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
fi

if [[ "${plan_checked}" -eq 0 ]]; then
  echo "WARN: 워커 디렉토리가 없습니다 — prepare-worker.sh를 먼저 실행하세요." >&2
fi

if [[ "${plan_failed}" -gt 0 ]]; then
  echo "" >&2
  echo "Error: ${plan_failed}건의 compact-plan 검증 실패. 워커가 5섹션을 모두 채운 뒤 다시 시도하세요." >&2
  echo "       강제 승인이 필요하면 --force 플래그를 사용하세요." >&2
  if [[ "${_FORCE_MODE}" -ne 1 ]]; then
    exit 3
  fi
  echo "       (--force 지정됨 — 검증 실패에도 불구하고 승인을 진행합니다)"
fi

# R24 (축 2 3단계): approval_required emit — compact-plan 검증 완료 직후, plan_validated/rejected 이전.
# 엄격 분기: plan_failed=0 && plan_checked>0 일 때만 emit (실패 plan 은 "승인 대기" 비정합 — policy §6 L49).
# idempotency_key = <session_id>:<first_worker>:<plan_sha256:0:8> (policy §6 L247 spec).
# 복수 워커 세션은 첫 워커만 emit — R25+ 에서 per-worker fan-out 재검토.
if [[ "${plan_checked}" -gt 0 && "${plan_failed}" -eq 0 ]]; then
  _first_plan=""
  _first_worker=""
  while IFS= read -r _wd; do
    if [[ -f "${_wd}/compact-plan.md" ]]; then
      _first_plan="${_wd}/compact-plan.md"
      _first_worker="$(basename "${_wd}")"
      break
    fi
  done < <(find "${WORKERS_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  if [[ -n "${_first_plan}" && -n "${_first_worker}" ]]; then
    _plan_sha_full=""
    if command -v shasum >/dev/null 2>&1; then
      _plan_sha_full="$(shasum -a 256 "${_first_plan}" | awk '{print $1}')"
    elif command -v sha256sum >/dev/null 2>&1; then
      _plan_sha_full="$(sha256sum "${_first_plan}" | awk '{print $1}')"
    fi
    if [[ -n "${_plan_sha_full}" ]]; then
      _plan_sha8="${_plan_sha_full:0:8}"
      _idem="${SESSION_ID}:${_first_worker}:${_plan_sha8}"
      bash "${SCRIPT_DIR}/company-emit.sh" "approval_required" "${SESSION_ID}" "${PROJECT_ROOT}" \
        "worker=${_first_worker}" "plan_sha256=${_plan_sha_full}" "idempotency_key=${_idem}" \
        "severity=P1" >/dev/null 2>&1 || true
    fi
  fi
fi

# R23 (축 2): --reject 분기 — plan 검증 완료 후 리더 거절 시 처리
# approved 마커 미생성, approval-log.md 에 Rejected 기록, rejected emit
if [[ "${_REJECT_MODE}" -eq 1 ]]; then
  mkdir -p "${SESSION_DIR}"
  {
    printf '%s\n' "## Rejected $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' "- session_id: ${SESSION_ID}"
    printf '%s\n' "- rejecter: ${USER:-leader}"
    printf '%s\n' "- plans_checked: ${plan_checked}"
    printf '\n'
  } >> "${APPROVAL_LOG}"
  bash "${SCRIPT_DIR}/company-emit.sh" "rejected" "${SESSION_ID}" "${PROJECT_ROOT}" \
    "actor=${USER:-leader}" "plans_checked=${plan_checked}" >/dev/null 2>&1 || true
  echo ""
  echo "✗ 세션 거절 완료: ${SESSION_ID}"
  echo "  워커에게 compact-plan 재작성을 지시하십시오."
  exit 0
fi

# R23 (축 2): plan_validated emit — 검증 통과 (plan_failed=0 이 이 지점까지 도달한 경우)
# --force 로 강제 통과한 경우도 plan_validated 를 emit (fail 정보는 plans_failed 필드에)
bash "${SCRIPT_DIR}/company-emit.sh" "plan_validated" "${SESSION_ID}" "${PROJECT_ROOT}" \
  "actor=company-approve.sh" "plans_checked=${plan_checked}" "plans_failed=${plan_failed}" >/dev/null 2>&1 || true

# v0.3-alpha B4: evidence validator (hard gate optional).
# 부착 위치 근거: docs/design/HANDOFF_2026-04-07.md R6/R7/R8 참조.
# EVIDENCE_STRICT=1 + validator exit 1 → approve 차단 (단, --force 지정 시 경고 후 통과).
EVIDENCE_VALIDATOR="${SCRIPT_DIR}/validate-evidence.sh"
EVIDENCE_STRICT=0
EVIDENCE_YAML=""
for _ev_yaml in \
  "${PROJECT_ROOT}/.company-kit/config/company.yaml" \
  "${PROJECT_ROOT}/config/company.yaml"; do
  if [[ -f "${_ev_yaml}" ]]; then
    EVIDENCE_YAML="${_ev_yaml}"
    break
  fi
done
if [[ -n "${EVIDENCE_YAML}" ]] && grep -qE '^[[:space:]]*exit_on_failure:[[:space:]]*true\b' "${EVIDENCE_YAML}" 2>/dev/null; then
  EVIDENCE_STRICT=1
fi
if [[ -x "${EVIDENCE_VALIDATOR}" ]]; then
  # `set -e` 하에서 non-zero exit를 즉시 잡기 위해 if 가드로 감싼다.
  if EVIDENCE_STRICT="${EVIDENCE_STRICT}" bash "${EVIDENCE_VALIDATOR}" "${SESSION_DIR}" >&2; then
    evidence_rc=0
  else
    evidence_rc=$?
  fi
  if [[ "${evidence_rc}" -ne 0 ]]; then
    if [[ "${EVIDENCE_STRICT}" == "1" ]]; then
      if [[ "${_FORCE_MODE}" -eq 1 ]]; then
        echo "" >&2
        echo "WARN: evidence validator가 hard fail을 보고했지만 --force 지정으로 승인을 진행합니다." >&2
      else
        echo "" >&2
        echo "Error: evidence validator hard fail (exit ${evidence_rc}). approve 차단." >&2
        echo "       워커가 expected-evidence.json 게이트(minimum_distinct_kinds / required_kinds)를 충족한 뒤 다시 시도하세요." >&2
        echo "       강제 승인이 필요하면 --force 플래그를 사용하세요." >&2
        exit 4
      fi
    fi
  fi
fi

# 마커 생성
mkdir -p "${SESSION_DIR}"
{
  printf 'session_id: %s\n' "${SESSION_ID}"
  printf 'approved_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'approver: %s\n' "${USER:-leader}"
  printf 'plans_checked: %d\n' "${plan_checked}"
  printf 'plans_failed: %d\n' "${plan_failed}"
} > "${APPROVED_MARKER}"

# approval-log.md에 기록 (printf의 옵션 해석 회피를 위해 %s\n 형식 사용)
{
  printf '%s\n' "## Approved $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n' "- session_id: ${SESSION_ID}"
  printf '%s\n' "- approver: ${USER:-leader}"
  printf '%s\n' "- plans_checked: ${plan_checked}"
  printf '%s\n' "- plans_failed: ${plan_failed}"
  printf '\n'
} >> "${APPROVAL_LOG}"

# v1.1.0 (C3): 이벤트 로거 — approved 기록
bash "${SCRIPT_DIR}/company-emit.sh" "approved" "${SESSION_ID}" "${PROJECT_ROOT}" "approver=${USER:-leader}" "plans_checked=${plan_checked}" >/dev/null 2>&1 || true

# v1.3.2: 승인 후 재투입 경로 — 각 워커별 resume-request.md 를 즉시 렌더한다.
# 기존에는 approved 마커만 만들고 끝나서 워커가 "plan 작성 → turn 종료" 상태로
# 멎어 있었다. resume-worker.sh 가 실행 프롬프트를 session-local 파일로 찍어
# 리더가 그대로 붙여넣을 수 있는 한 줄 지시를 제공한다.
AUTO_RESUME=1
if [[ "${COMPANY_APPROVE_SKIP_RESUME:-0}" == "1" ]]; then
  AUTO_RESUME=0
fi
if [[ "${AUTO_RESUME}" -eq 1 && -x "${SCRIPT_DIR}/resume-worker.sh" ]]; then
  echo ""
  echo "── Resume 요청 렌더링 ──────────────────────────────"
  # v1.3.6: COMPANY_RESUME_AUTO_INJECT=1 이면 --auto-inject 전파.
  # 기본은 dry-run(리더 붙여넣기). tmux send-keys 자동 주입은 명시적 opt-in.
  _resume_args=("${SESSION_ID}" "" "${PROJECT_ROOT}")
  if [[ "${COMPANY_RESUME_AUTO_INJECT:-0}" == "1" ]]; then
    _resume_args+=("--auto-inject")
  fi
  bash "${SCRIPT_DIR}/resume-worker.sh" "${_resume_args[@]}" || true
fi

echo ""
echo "✓ 세션 승인 완료: ${SESSION_ID}"
echo "  마커: ${APPROVED_MARKER}"
echo "  워커가 이제 외부 write 단계로 진행할 수 있습니다."
if [[ "${COMPANY_RESUME_AUTO_INJECT:-0}" == "1" ]]; then
  echo "👉 NEXT: 워커 pane 에 자동 주입을 시도했습니다. tmux status line 의 ⚙️ 표시를 확인하세요."
else
  echo "👉 NEXT: 각 워커 pane 에 위 resume-request 한 줄을 붙여넣어 재투입하세요."
  echo "        (환경 변수 'export COMPANY_RESUME_AUTO_INJECT=1' 로 자동 주입 활성화 가능)"
fi
echo "  세션 종료는: company close ${SESSION_ID}"
