#!/usr/bin/env bash
set -euo pipefail

# smoke-prepare-worker.sh — v0.3-alpha B3 evidence 경로 smoke (R10 Phase 1)
#
# 왜: source 레포에는 .company-kit/config/ 가 없어 prepare-worker.sh를 직접 호출할
#     수 없다 (R7 "source vs target" 경계 이슈). target 프로젝트를 /tmp 에 하나
#     install-into-project.sh 로 뿌린 뒤, prepare-session.sh → prepare-worker.sh
#     경로가 워커별로 expected-evidence.json 을 정확한 스키마로 떨구는지 검증한다.
#     R8 5개 후보 중 (5) prepare-worker.sh 테스트 경로 편입 deliverable.
#
# 검증 항목:
#   (1) install-into-project.sh + prepare-session.sh + prepare-worker.sh 체인 성공
#   (2) expected-evidence.json 파일 존재 (워커별)
#   (3) 스키마 필드: worker / minimum_distinct_kinds / required_kinds / optional_kinds / deferred_kinds
#   (4) config/company.yaml R6 매핑표와 1:1 일치 (3개 워커 샘플링)
#       - frontend-engineer:  mdk=2, required=[repo_text_or_diff, external_spec_or_policy]
#       - backend-engineer:   mdk=2, required=[code_symbol_or_reference, external_spec_or_policy]
#       - risk-reviewer:      mdk=2, required=[static_vuln_scan, code_symbol_or_reference]
#   (5) validate-evidence.sh 가 해당 session에 대해 INFO skip 경로로 나가는지
#       (manifest 부재 시 hard_fail_count=0)
#
# 실행:
#   bash scripts/smoke-prepare-worker.sh
#
# 성공 시 "smoke-prepare-worker: PASS" + exit 0.
# 실패 시 set -e 로 즉시 중단.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_ROOT="$(mktemp -d /tmp/smoke-prepare-worker.XXXXXX)"
PROJECT_ROOT="${TMP_ROOT}/project"
SESSION_ID="smoke-evidence"

cleanup() { rm -rf "${TMP_ROOT}"; }
trap cleanup EXIT

# (1) install + session + worker chain
bash "${REPO_ROOT}/scripts/install-into-project.sh" "${PROJECT_ROOT}" \
  --name=SmokePrepareWorker \
  --domain='R10 phase1 evidence smoke' \
  --stack=harness-smoke \
  --primary-worker=frontend-engineer \
  --supporting-workers=backend-engineer >/dev/null

# install 직후 git init — prepare-session.sh 가 worktree 경로 확인용
git -C "${PROJECT_ROOT}" init -b main -q
git -C "${PROJECT_ROOT}" config user.name "Smoke"
git -C "${PROJECT_ROOT}" config user.email "smoke@example.com"
git -C "${PROJECT_ROOT}" add .
git -C "${PROJECT_ROOT}" commit -q -m "smoke init"

bash "${PROJECT_ROOT}/.company-kit/scripts/prepare-session.sh" "${SESSION_ID}" "${PROJECT_ROOT}" >/dev/null
bash "${PROJECT_ROOT}/.company-kit/scripts/prepare-worker.sh" "${SESSION_ID}" "frontend-engineer" "${PROJECT_ROOT}" >/dev/null
bash "${PROJECT_ROOT}/.company-kit/scripts/prepare-worker.sh" "${SESSION_ID}" "backend-engineer" "${PROJECT_ROOT}" >/dev/null
bash "${PROJECT_ROOT}/.company-kit/scripts/prepare-worker.sh" "${SESSION_ID}" "risk-reviewer" "${PROJECT_ROOT}" >/dev/null

SESSION_DIR="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}"

# (2~4) 워커별 expected-evidence.json 스키마 검증
python3 - "${SESSION_DIR}" <<'PYEOF'
import json, sys
from pathlib import Path

session_dir = Path(sys.argv[1])
expected_matrix = {
    "frontend-engineer": {
        "mdk": 2,
        "required": {"repo_text_or_diff", "external_spec_or_policy"},
    },
    "backend-engineer": {
        "mdk": 2,
        "required": {"code_symbol_or_reference", "external_spec_or_policy"},
    },
    "risk-reviewer": {
        "mdk": 2,
        "required": {"static_vuln_scan", "code_symbol_or_reference"},
    },
}

for worker, spec in expected_matrix.items():
    ev_path = session_dir / "workers" / worker / "expected-evidence.json"
    assert ev_path.is_file(), f"{worker}: expected-evidence.json 부재 ({ev_path})"
    with ev_path.open("r", encoding="utf-8") as f:
        exp = json.load(f)
    assert exp.get("worker") == worker, \
        f"{worker}: worker 필드 mismatch — got {exp.get('worker')!r}"
    assert int(exp.get("minimum_distinct_kinds", 0)) == spec["mdk"], \
        f"{worker}: mdk mismatch — got {exp.get('minimum_distinct_kinds')}"
    required = set(exp.get("required_kinds") or [])
    assert required == spec["required"], \
        f"{worker}: required_kinds mismatch — got {sorted(required)}"
    for key in ("optional_kinds", "deferred_kinds"):
        assert key in exp, f"{worker}: {key} 필드 부재"
        assert isinstance(exp[key], list), f"{worker}: {key} 가 list 가 아님"
    print(f"OK: {worker} — mdk={spec['mdk']}, required={sorted(spec['required'])}")
PYEOF

# (5) validate-evidence.sh: manifest 부재 상태에서 INFO skip 경로 → hard_fails=0
rc=0
SUMMARY_LINE="$(bash "${REPO_ROOT}/scripts/validate-evidence.sh" "${SESSION_DIR}" 2>&1 | grep '^\[evidence\] SUMMARY:' || true)"
echo "${SUMMARY_LINE}"
if [[ -z "${SUMMARY_LINE}" ]]; then
  echo "smoke-prepare-worker: FAIL — validator SUMMARY 라인 부재" >&2
  exit 1
fi
# manifest 아직 없음 → soft_warnings=0, hard_fails=0 기대
if ! echo "${SUMMARY_LINE}" | grep -q 'hard_fails=0'; then
  echo "smoke-prepare-worker: FAIL — manifest 부재 경로에서 hard_fails 누출" >&2
  exit 1
fi

# (6) R11 회귀 방지 — run-session.sh outside-tmux fallback 경로
#     `env -u TMUX` 로 호출 시 PROJECT_ROOT unbound 에러 없이 topic 기반 슬러그가
#     만들어져야 한다. (R10 P1에서 drop되었던 pre-existing 버그)
env -u TMUX bash "${PROJECT_ROOT}/.company-kit/scripts/run-session.sh" \
  "smoke outside tmux fallback" "" "${PROJECT_ROOT}" >/dev/null
test -f "${PROJECT_ROOT}/.company-runtime/sessions/smoke-outside-tmux-fallback/dispatch-summary.md" || {
  echo "smoke-prepare-worker: FAIL — outside-tmux fallback 경로에서 topic 슬러그 미생성" >&2
  exit 1
}

# (7) R21 회귀 방지 — assembled.md 도구 기반 섹션 주입 확인
#     3개 워커 샘플링: frontend-engineer, backend-engineer, risk-reviewer
for _w in frontend-engineer backend-engineer risk-reviewer; do
  _assembled="${SESSION_DIR}/workers/${_w}/worker-system-prompt.assembled.md"
  if [[ ! -f "${_assembled}" ]]; then
    echo "smoke-prepare-worker: FAIL — ${_w} assembled.md 없음" >&2
    exit 1
  fi
  if ! grep -q '도구는 판단의 근거이며, 근거 없는 설계는 오염이다' "${_assembled}"; then
    echo "smoke-prepare-worker: FAIL — ${_w} assembled.md R21 stamp 미발견" >&2
    exit 1
  fi
  if ! grep -q '# 도구 기반' "${_assembled}"; then
    echo "smoke-prepare-worker: FAIL — ${_w} assembled.md '# 도구 기반' 섹션 미발견" >&2
    exit 1
  fi
done

# (8) v1.3.4 Shadow Tracking 회귀 방지 — shadow-tool-scan.sh 가 존재하고
#     transcript 디렉토리 부재 상태에서도 exit 0 + 최소 1 레코드 기록하는지 확인.
if [[ ! -x "${REPO_ROOT}/scripts/shadow-tool-scan.sh" ]]; then
  echo "smoke-prepare-worker: FAIL — shadow-tool-scan.sh 가 실행 권한 없음" >&2
  exit 1
fi
# HOME 을 비어있는 임시 디렉토리로 바꿔 "no-claude-projects-dir" 경로 검증
_shadow_tmp_home="$(mktemp -d /tmp/shadow-home.XXXXXX)"
HOME="${_shadow_tmp_home}" bash "${REPO_ROOT}/scripts/shadow-tool-scan.sh" \
  "shadow-smoke" "${PROJECT_ROOT}" >/dev/null 2>&1
_shadow_out="${PROJECT_ROOT}/.company-runtime/sessions/shadow-smoke/shadow-tool-calls.jsonl"
if [[ ! -s "${_shadow_out}" ]]; then
  echo "smoke-prepare-worker: FAIL — shadow-tool-calls.jsonl 이 생성되지 않음" >&2
  rm -rf "${_shadow_tmp_home}"
  exit 1
fi
if ! grep -q '"status":"no-claude-projects-dir"' "${_shadow_out}"; then
  echo "smoke-prepare-worker: FAIL — shadow 레코드가 기대 형식이 아님" >&2
  cat "${_shadow_out}" >&2
  rm -rf "${_shadow_tmp_home}"
  exit 1
fi
rm -rf "${_shadow_tmp_home}"

printf '\nsmoke-prepare-worker: PASS\n'
