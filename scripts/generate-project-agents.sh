#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────
# generate-project-agents.sh
# Reads worker TSV configs and generates
# .claude/agents/company-<worker>.md files
# Compatible with bash 3.2+ (no associative arrays)
# ──────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Usage ────────────────────────────────────
usage() {
  cat <<'USAGE'
Usage: generate-project-agents.sh <target-root> [--categories=<comma-list>]

  <target-root>       Project root directory (e.g. "." or "/path/to/project")
  --categories=...    Comma-separated worker categories to include
                      Default: base,business,engineering,design

Examples:
  bash scripts/generate-project-agents.sh .
  bash scripts/generate-project-agents.sh /tmp/myproject --categories=base,game
USAGE
  exit 1
}

# ── Parse arguments ──────────────────────────
TARGET_ROOT=""
CATEGORIES="base,business,engineering,design"

for arg in "$@"; do
  case "${arg}" in
    --categories=*)
      CATEGORIES="${arg#--categories=}"
      ;;
    -h|--help)
      usage
      ;;
    *)
      if [[ -z "${TARGET_ROOT}" ]]; then
        TARGET_ROOT="${arg}"
      else
        echo "Error: unexpected argument '${arg}'" >&2
        usage
      fi
      ;;
  esac
done

if [[ -z "${TARGET_ROOT}" ]]; then
  echo "Error: <target-root> is required." >&2
  usage
fi

# Resolve to absolute path
TARGET_ROOT="$(cd "${TARGET_ROOT}" && pwd)"

# ── Resolve CONFIG_DIR ───────────────────────
if [[ -d "${TARGET_ROOT}/.company-kit/config" ]]; then
  CONFIG_DIR="${TARGET_ROOT}/.company-kit/config"
else
  CONFIG_DIR="${SOURCE_REPO_DIR}/config"
fi
echo "Config dir: ${CONFIG_DIR}"

# ── Source manifest-lib.sh ───────────────────
MANIFEST_LIB=""
if [[ -f "${SCRIPT_DIR}/manifest-lib.sh" ]]; then
  MANIFEST_LIB="${SCRIPT_DIR}/manifest-lib.sh"
elif [[ -f "${TARGET_ROOT}/.company-kit/scripts/manifest-lib.sh" ]]; then
  MANIFEST_LIB="${TARGET_ROOT}/.company-kit/scripts/manifest-lib.sh"
fi

if [[ -z "${MANIFEST_LIB}" ]]; then
  echo "Error: manifest-lib.sh not found." >&2
  exit 1
fi
# shellcheck source=manifest-lib.sh
source "${MANIFEST_LIB}"

# ── Validate TSV files ───────────────────────
CATEGORIES_TSV="${CONFIG_DIR}/worker-categories.tsv"
DEFINITIONS_TSV="${CONFIG_DIR}/worker-definitions.tsv"
BRIEFS_TSV="${CONFIG_DIR}/worker-role-briefs.tsv"

for f in "${CATEGORIES_TSV}" "${DEFINITIONS_TSV}" "${BRIEFS_TSV}"; do
  if [[ ! -f "${f}" ]]; then
    echo "Error: required TSV file not found: ${f}" >&2
    exit 1
  fi
done

# ── Helper: check if value is in comma-separated list ──
in_list() {
  local needle="$1" haystack="$2"
  echo ",${haystack}," | grep -q ",${needle},"
}

# ── Helper: lookup value from a "key\tvalue" store file ──
# We build temp lookup files to avoid associative arrays
TMPWORK="$(mktemp -d)"
trap 'rm -rf "${TMPWORK}"' EXIT

# ── Step 1: Read categories TSV → selected worker list ──
SELECTED_FILE="${TMPWORK}/selected.tsv"
: > "${SELECTED_FILE}"

while IFS=$'\t' read -r worker_id category; do
  worker_id="$(printf '%s' "${worker_id}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  category="$(printf '%s' "${category}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "${worker_id}" || -z "${category}" ]] && continue
  if in_list "${category}" "${CATEGORIES}"; then
    printf '%s\t%s\n' "${worker_id}" "${category}" >> "${SELECTED_FILE}"
  fi
done < <(read_nonempty_lines "${CATEGORIES_TSV}")

WORKER_COUNT="$(wc -l < "${SELECTED_FILE}" | tr -d ' ')"
if [[ "${WORKER_COUNT}" -eq 0 ]]; then
  echo "Warning: no workers matched categories '${CATEGORIES}'." >&2
  exit 0
fi

# ── Step 2: Read definitions TSV → aliases lookup ──
ALIASES_FILE="${TMPWORK}/aliases.tsv"
: > "${ALIASES_FILE}"

while IFS=$'\t' read -r aliases worker_id _profile _starter _docs; do
  worker_id="$(printf '%s' "${worker_id}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  aliases="$(printf '%s' "${aliases}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "${worker_id}" ]] && continue
  printf '%s\t%s\n' "${worker_id}" "${aliases}" >> "${ALIASES_FILE}"
done < <(read_nonempty_lines "${DEFINITIONS_TSV}")

# ── Step 3: Read role-briefs TSV → role details lookup ──
BRIEFS_FILE="${TMPWORK}/briefs.tsv"
: > "${BRIEFS_FILE}"

while IFS=$'\t' read -r worker_id role_name _collabs brief artifacts questions; do
  worker_id="$(printf '%s' "${worker_id}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "${worker_id}" ]] && continue
  # Store as: worker_id \t role_name \t brief \t artifacts \t questions
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "${worker_id}" "${role_name}" "${brief}" "${artifacts}" "${questions}" \
    >> "${BRIEFS_FILE}"
done < <(read_nonempty_lines "${BRIEFS_TSV}")

# ── Lookup helpers ───────────────────────────
lookup_aliases() {
  local wid="$1"
  grep "^${wid}	" "${ALIASES_FILE}" 2>/dev/null | head -1 | cut -f2
}

lookup_brief_field() {
  # field: 2=role_name, 3=brief, 4=artifacts, 5=questions
  local wid="$1" field="$2"
  grep "^${wid}	" "${BRIEFS_FILE}" 2>/dev/null | head -1 | cut -f"${field}"
}

# ── Prepare output directory ─────────────────
AGENTS_DIR="${TARGET_ROOT}/.claude/agents"
mkdir -p "${AGENTS_DIR}"

# ── Generate agent files ─────────────────────
GENERATED=0

while IFS=$'\t' read -r worker_id _category; do
  role_name="$(lookup_brief_field "${worker_id}" 2)"
  role_name="${role_name:-${worker_id}}"
  aliases="$(lookup_aliases "${worker_id}")"
  aliases="${aliases:-${worker_id}}"
  artifacts_raw="$(lookup_brief_field "${worker_id}" 4)"
  questions_raw="$(lookup_brief_field "${worker_id}" 5)"

  # Build questions markdown
  questions_md=""
  if [[ -n "${questions_raw}" ]]; then
    while IFS= read -r q; do
      q="$(printf '%s' "${q}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -n "${q}" ]] && questions_md="${questions_md}
- ${q}"
    done < <(printf '%s\n' "${questions_raw}" | tr '|' '\n')
  fi

  # Build artifacts markdown
  artifacts_md=""
  if [[ -n "${artifacts_raw}" ]]; then
    while IFS= read -r a; do
      a="$(printf '%s' "${a}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -n "${a}" ]] && artifacts_md="${artifacts_md}
- ${a}"
    done < <(printf '%s\n' "${artifacts_raw}" | tr ',' '\n')
  fi

  # Write agent file
  cat > "${AGENTS_DIR}/company-${worker_id}.md" <<AGENT_EOF
---
name: company-${worker_id}
description: ${role_name} — ${aliases}. Prefer this over plugin agents.
model: sonnet
maxTurns: 8
---

You are the ${role_name} subagent for this project.

Operating rules:

- You are a spawned worker, not the leader.
- Read the paths the leader gives you first, especially \`agent-team-brief.md\`, \`team-prompt.md\`, \`reference-files.md\`, and \`context.md\`.
- Follow \`.company-project/model-policy.md\`.
- Do the hands-on investigation, drafting, implementation, and review work inside approved scope.
- Do not make final approvals, final architecture signoff, or external writes.
- If scope changes or approval is needed, return control to the leader.
- Keep output compact:
  - Summary
  - Decision
  - Risks
  - Next Action

Key questions to always ask:${questions_md}

Expected artifacts:${artifacts_md}
AGENT_EOF

  GENERATED=$((GENERATED + 1))
done < "${SELECTED_FILE}"

# ── Generate README.md ───────────────────────
GEN_DATE="$(date '+%Y-%m-%d %H:%M:%S')"

{
  cat <<README_HEADER
# Project Subagents

이 디렉터리는 이 프로젝트에서 우선 사용할 팀 서브에이전트를 정의합니다.

생성 기준: categories=${CATEGORIES}
생성 일시: ${GEN_DATE}
워커 수: ${GENERATED}

## 기본 원칙

- 리더는 이 프로젝트의 팀 작업을 전역 plugin agent가 아니라 여기 있는 project subagent로 실행합니다.
- 필요할 때는 \`@agent-company-<worker>\` 형태로 명시 호출합니다.
- 같은 이름의 plugin agent보다 project subagent가 우선됩니다.

## 등록된 서브에이전트

README_HEADER

  # Sort worker IDs for stable output
  sort -t$'\t' -k1,1 "${SELECTED_FILE}" | while IFS=$'\t' read -r worker_id _category; do
    role_name="$(lookup_brief_field "${worker_id}" 2)"
    role_name="${role_name:-${worker_id}}"
    echo "- \`@agent-company-${worker_id}\` — ${role_name}"
  done

  cat <<README_FOOTER

## 재생성

\`\`\`bash
bash .company-kit/scripts/generate-project-agents.sh . --categories=${CATEGORIES}
\`\`\`
README_FOOTER
} > "${AGENTS_DIR}/README.md"

echo "Generated ${GENERATED} agent files + README.md in ${AGENTS_DIR}"
