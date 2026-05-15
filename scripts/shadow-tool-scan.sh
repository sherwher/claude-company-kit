#!/usr/bin/env bash
set -euo pipefail

# shadow-tool-scan.sh — v1.3.4 Shadow Tracking (warn-only)
#
# 왜: ROADMAP "강제 차단형 hook 우선 도입: Shadow Tracking 단계를 거친 뒤에만
#     고려" 원칙을 따르기 위해, 워커 서브프로세스가 어떤 금지 툴을 얼마나
#     자주 호출했는지 관찰만 한다. permissions.deny 도입 전 근거 수집 용도.
#
# 무엇을 보나:
#   - EnterPlanMode / ExitPlanMode 호출 (Claude Code built-in plan mode 진입)
#   - Agent / Task 호출 (sub-agent 자가 스폰 → 토큰 예산 고갈 신호)
#   - oh-my-claudecode:* subagent_type 지정 Agent 호출
#
# 어떻게:
#   ~/.claude/projects/<slug>/*.jsonl 중 최근 24시간 내 수정된 transcript 를
#   훑어 위 tool_use 를 count 한다. 매칭되는 transcript 당 JSONL 한 줄 기록.
#   매칭 0건이어도 메타 레코드 1건 기록 (실행 증적).
#
# 정책:
#   - warn-only. 어떤 경우에도 exit 1 하지 않는다 (set -e 에도 exit 0 로 빠짐).
#   - jq / python3 중 하나만 있으면 동작. 둘 다 없으면 silent skip.
#   - close-session.sh 에서 best-effort 로 호출 (실패 무시).
#
# 사용:
#   bash shadow-tool-scan.sh <session-id> [project-root]
#
# 출력 파일:
#   <project-root>/.company-runtime/sessions/<session-id>/shadow-tool-calls.jsonl

SESSION_ID="${1:-}"
ROOT="${2:-.}"

if [[ -z "${SESSION_ID}" ]]; then
  echo "Usage: $0 <session-id> [project-root]" >&2
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[shadow] python3 not available — scan skipped" >&2
  exit 0
fi

PROJECT_ROOT="$(cd "${ROOT}" && pwd)"
SESSION_DIR="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}"
OUT_FILE="${SESSION_DIR}/shadow-tool-calls.jsonl"
mkdir -p "${SESSION_DIR}"

CC_PROJECTS="${HOME}/.claude/projects"
TS="$(date -u +%FT%TZ)"

if [[ ! -d "${CC_PROJECTS}" ]]; then
  printf '{"ts":"%s","session":"%s","status":"no-claude-projects-dir"}\n' \
    "${TS}" "${SESSION_ID}" >> "${OUT_FILE}"
  exit 0
fi

# 프로젝트 루트 + (있다면) worktree 루트를 모두 scan 대상에 포함.
# Claude Code 는 cwd 마다 별도 slug 디렉토리를 만든다.
CANDIDATE_ROOTS=("${PROJECT_ROOT}")
WORKTREE_ROOT=""
# load_session_metadata 대신 session-info.env 직접 파싱 (종속성 최소화)
SESSION_INFO="${SESSION_DIR}/session-info.env"
if [[ -f "${SESSION_INFO}" ]]; then
  # shellcheck disable=SC1090
  WORKTREE_ROOT="$(awk -F= '/^WORKTREE_ROOT=/{gsub(/"/,"",$2); print $2}' "${SESSION_INFO}" | tail -1)"
fi
if [[ -n "${WORKTREE_ROOT}" && -d "${WORKTREE_ROOT}" ]]; then
  CANDIDATE_ROOTS+=("${WORKTREE_ROOT}")
fi

# slug 계산: 앞 '/' 포함한 path 에서 '/' → '-'.
path_to_slug() {
  local p="$1"
  printf -- '-%s' "$(printf '%s' "${p}" | sed 's#^/##; s#/#-#g')"
}

SCANNED=0
MATCHED_TRANSCRIPTS=0

for root in "${CANDIDATE_ROOTS[@]}"; do
  slug="$(path_to_slug "${root}")"
  cc_dir="${CC_PROJECTS}/${slug}"
  [[ -d "${cc_dir}" ]] || continue

  # 최근 24시간 내 수정된 transcript 만 검사
  while IFS= read -r -d '' transcript; do
    SCANNED=$((SCANNED + 1))
    # python3 로 tool_use count
    if python3 - "${transcript}" "${SESSION_ID}" "${TS}" "${OUT_FILE}" <<'PYEOF'
import json, sys, os
transcript, session, ts, out = sys.argv[1:5]
counts = {"EnterPlanMode": 0, "ExitPlanMode": 0, "Agent": 0, "Task": 0}
omc_subagent = 0
errors = 0
try:
    with open(transcript, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                errors += 1
                continue
            if d.get("type") != "assistant":
                continue
            msg = d.get("message") or {}
            content = msg.get("content") or []
            if not isinstance(content, list):
                continue
            for c in content:
                if not isinstance(c, dict):
                    continue
                if c.get("type") != "tool_use":
                    continue
                name = c.get("name", "")
                if name in counts:
                    counts[name] += 1
                if name == "Agent":
                    inp = c.get("input") or {}
                    st = str(inp.get("subagent_type", "")) if isinstance(inp, dict) else ""
                    if st.startswith("oh-my-claudecode:"):
                        omc_subagent += 1
except Exception as e:
    print(f"[shadow] scan error {transcript}: {e}", file=sys.stderr)
    sys.exit(2)
total = sum(counts.values()) + omc_subagent
if total == 0:
    sys.exit(1)  # 매칭 없음 → 스킵
rec = {
    "ts": ts,
    "session": session,
    "transcript": os.path.basename(transcript),
    "forbidden": counts,
    "omc_subagent": omc_subagent,
    "parse_errors": errors,
}
with open(out, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
PYEOF
    then
      MATCHED_TRANSCRIPTS=$((MATCHED_TRANSCRIPTS + 1))
    fi
  done < <(find "${cc_dir}" -maxdepth 1 -name '*.jsonl' -mtime -1 -print0 2>/dev/null || true)
done

# scanned=0 이어도 최소 1 레코드는 남겨 '실행 증적' 으로 사용
if [[ "${SCANNED}" -eq 0 ]]; then
  printf '{"ts":"%s","session":"%s","status":"no-recent-transcripts"}\n' \
    "${TS}" "${SESSION_ID}" >> "${OUT_FILE}"
fi

echo "[shadow] scanned=${SCANNED} matched=${MATCHED_TRANSCRIPTS} out=${OUT_FILE}"
exit 0
