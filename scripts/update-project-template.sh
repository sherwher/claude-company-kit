#!/usr/bin/env bash
set -euo pipefail

TARGET_ROOT="${1:-}"
FORCE_YES=false

# Simple argument parsing for --yes flag
# We might have <target-root> --yes or --yes <target-root>
for arg in "$@"; do
  if [[ "${arg}" == "--yes" || "${arg}" == "-y" ]]; then
    FORCE_YES=true
  elif [[ -z "${TARGET_ROOT}" ]]; then
    TARGET_ROOT="${arg}"
  fi
done

if [[ -z "${TARGET_ROOT}" ]]; then
  TARGET_ROOT="."
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="${TARGET_ROOT}/.company-kit"
SAMPLE_DIR="${KIT_DIR}/scaffold/project-root-sample"
CONFIG_DIR="${KIT_DIR}/config"
VERSION_FILE="${SCRIPT_DIR}/../VERSION"
CHANGELOG_FILE="${SCRIPT_DIR}/../CHANGELOG.md"

if [[ ! -d "${KIT_DIR}" ]]; then
  echo "Error: ${TARGET_ROOT} does not appear to be an ai-company project (missing .company-kit)."
  exit 1
fi

# v1.1.0: self-update 감지 — target 내부의 .company-kit/scripts/에서 실행하면
# rsync가 kit을 자기 자신으로 복사해 조용히 아무것도 안 바뀌는 기존 결함을 방지.
SCRIPT_DIR_REAL="$(cd "${SCRIPT_DIR}" && pwd -P)"
KIT_SCRIPTS_REAL="$(cd "${KIT_DIR}/scripts" 2>/dev/null && pwd -P || echo "")"
if [[ -n "${KIT_SCRIPTS_REAL}" && "${SCRIPT_DIR_REAL}" == "${KIT_SCRIPTS_REAL}" ]]; then
  cat >&2 <<EOF
Error: 이 스크립트는 **source repo**에서 실행해야 합니다.

지금은 target 프로젝트의 .company-kit/scripts/ 에서 실행됐기 때문에,
kit을 자기 자신으로 rsync하는 결과가 되어 실제로는 아무것도 업데이트되지
않습니다. (silent no-op)

올바른 사용법:
  cd <source-repo-clone>                          # ai-company template 소스 클론
  git pull origin master                          # 최신 받기
  bash scripts/update-project-template.sh ${TARGET_ROOT} --yes

또는 company facade 사용 시:
  cd <source-repo-clone>
  bash scripts/company update ${TARGET_ROOT} --yes

source repo 클론이 없다면 먼저 다음으로 clone 하세요:
  git clone <TEMPLATE_GIT_URL> ~/src/ai-company
EOF
  exit 2
fi

LATEST_VERSION="$(tr -d '\n' < "${VERSION_FILE}")"
CURRENT_VERSION="unknown"
LOCK_FILE="${TARGET_ROOT}/.company-template.lock"
if [[ -f "${LOCK_FILE}" ]]; then
  CURRENT_VERSION=$(grep "template_version:" "${LOCK_FILE}" 2>/dev/null | awk '{print $2}' || true)
  if [[ -z "${CURRENT_VERSION}" ]]; then
    CURRENT_VERSION="unknown"
    echo "⚠️  .company-template.lock에서 template_version을 읽을 수 없습니다. unknown으로 진행합니다." >&2
  fi
fi

echo "=========================================="
echo "    ai-company Template Update"
echo "=========================================="
echo "Target:  ${TARGET_ROOT}"
echo "Current: ${CURRENT_VERSION}"
echo "Latest:  ${LATEST_VERSION}"
echo "------------------------------------------"

if [[ "${CURRENT_VERSION}" == "${LATEST_VERSION}" ]]; then
  echo "✅ Project is already up to date."
  if [[ "${FORCE_YES}" == "true" ]]; then
    REPLY="y"
  else
    read -p "Do you want to force refresh files? [y/N] " -n 1 -r
    echo
  fi
  if [[ ! ${REPLY:-} =~ ^[Yy]$ ]]; then
    exit 0
  fi
else
  echo "📦 New version available!"
  echo ""
  echo "Recent Changes:"
  echo "------------------------------------------"
  # v1.5.10: head 가 30줄 받고 닫히면 상류(extract-changelog)가 SIGPIPE(141)로
  # 죽고, 스크립트 최상단의 `set -euo pipefail` 때문에 전체 update 가 그 자리에서
  # 종료되던 회귀를 차단. v1.2.x → 1.5.9 처럼 누적 changelog 가 30줄을 넘는 경우
  # 처음 트리거됐다. `|| true` 로 상류 종료코드를 흡수해 파이프라인 자체는 0 유지.
  { bash "${SCRIPT_DIR}/extract-changelog.sh" "${CHANGELOG_FILE}" "${CURRENT_VERSION}" "${LATEST_VERSION}" || true; } | head -n 30
  echo "------------------------------------------"
  echo ""
  
  if [[ "${FORCE_YES}" == "true" ]]; then
    REPLY="y"
  else
    if [[ -t 0 ]]; then
      read -p "Proceed with update? [y/N] " -n 1 -r
      echo
    else
      echo "Non-interactive shell detected. Use -y or --yes to proceed."
      exit 1
    fi
  fi

  if [[ ! ${REPLY:-} =~ ^[Yy]$ ]]; then
    echo "Update cancelled."
    exit 0
  fi
fi

echo "🚀 Starting update..."

# 1. Update .company-kit/ (Core)
echo "  [1/4] Updating core scripts (.company-kit/)..."
bash "${SCRIPT_DIR}/export-company-kit.sh" "${TARGET_ROOT}" >/dev/null

if [[ ! -d "${KIT_DIR}" ]]; then
  echo "❌ Error: Missing ${KIT_DIR} after export"
  exit 1
fi

# 2. Sync project files based on manifest
echo "  [2/4] Syncing project files..."
# shellcheck source=./manifest-lib.sh
source "${SCRIPT_DIR}/manifest-lib.sh"

REFRESHED_FILES=()
PREVIEW_FILES=()

while IFS=$'\t' read -r source_base source_rel target_rel mode; do
  [[ -n "${source_base}" && -n "${source_rel}" && -n "${target_rel}" && -n "${mode}" ]] || continue

  case "${source_base}" in
    kit) SOURCE_PATH="${KIT_DIR}/${source_rel}" ;;
    sample) SOURCE_PATH="${SAMPLE_DIR}/${source_rel}" ;;
    *) echo "Unknown update manifest source base: ${source_base}"; exit 1 ;;
  esac

  TARGET_PATH="${TARGET_ROOT}/${target_rel}"
  mkdir -p "$(dirname "${TARGET_PATH}")"

  if [[ "${mode}" == "refresh" ]]; then
    cp "${SOURCE_PATH}" "${TARGET_PATH}"
    REFRESHED_FILES+=("${target_rel}")
  elif [[ "${mode}" == "preview" ]]; then
    cp "${SOURCE_PATH}" "${TARGET_PATH}"
    PREVIEW_FILES+=("${target_rel}")
  elif [[ "${mode}" == "managed-block" ]]; then
    # v1.3.5: managed-block 모드 — # >>> company-kit managed ... # <<< company-kit managed
    # 마커 사이만 소스로 교체. 사용자가 추가한 줄(.gitignore 등)은 보존.
    # 기존 프로젝트에 마커가 없으면 파일 끝에 블록을 append (migration path).
    if ! command -v python3 >/dev/null 2>&1; then
      echo "⚠️  python3 미설치 — ${target_rel} 을 managed-block 대신 refresh 로 처리" >&2
      cp "${SOURCE_PATH}" "${TARGET_PATH}"
      REFRESHED_FILES+=("${target_rel} (fallback: refresh)")
    else
      python3 - "${SOURCE_PATH}" "${TARGET_PATH}" <<'PYEOF'
import sys, os, re
source, target = sys.argv[1], sys.argv[2]
MARK_RE = re.compile(
    r"^# >>> company-kit managed.*?^# <<< company-kit managed[^\n]*\n?",
    flags=re.M | re.S,
)
with open(source, "r", encoding="utf-8") as f:
    src = f.read()
m_src = MARK_RE.search(src)
if not m_src:
    # 소스 마커 부재: 전체 내용을 managed 블록으로 래핑
    block = (
        "# >>> company-kit managed (harness 가 관리 — 아래 블록은 template update 시 덮어써집니다) >>>\n"
        + src.rstrip() + "\n"
        + "# <<< company-kit managed <<<\n"
    )
else:
    block = m_src.group(0)
    if not block.endswith("\n"):
        block += "\n"
if not os.path.exists(target):
    with open(target, "w", encoding="utf-8") as f:
        f.write(src if m_src is None else src)
    print(f"managed-block: created {target}")
    sys.exit(0)
with open(target, "r", encoding="utf-8") as f:
    tgt = f.read()
m_tgt = MARK_RE.search(tgt)
if m_tgt:
    new = tgt[:m_tgt.start()] + block + tgt[m_tgt.end():]
    status = "replaced"
else:
    sep = "" if tgt.endswith("\n") else "\n"
    new = tgt + sep + "\n" + block
    status = "appended (migration)"
if new == tgt:
    print(f"managed-block: no-op {target}")
else:
    with open(target, "w", encoding="utf-8") as f:
        f.write(new)
    print(f"managed-block: {status} {target}")
PYEOF
      REFRESHED_FILES+=("${target_rel} (managed-block)")
    fi
  fi
done < <(read_nonempty_lines "${CONFIG_DIR}/update-managed-files.tsv")

# 3. Migration Hooks & Cleanup
echo "  [3/4] Running migration hooks..."
bash "${TARGET_ROOT}/.company-kit/scripts/init-cloned-project.sh" "${TARGET_ROOT}" >/dev/null

# v1.5.5: settings.json 의 leader-wake hook 자동 merge.
# v1.5.4 에서 scaffold settings.json 에 default-on 으로 등록했지만 기존 프로젝트는
# 자동 갱신 안 됐다. 여기서 사용자 permissions/env 등은 보존하면서 hooks.UserPromptSubmit
# 의 leader-wake 등록만 보장한다 (이미 등록돼 있으면 no-op).
SETTINGS_JSON_PATH="${TARGET_ROOT}/.claude/settings.json"
if [[ -f "${SETTINGS_JSON_PATH}" ]] && command -v python3 >/dev/null 2>&1; then
  python3 - "${SETTINGS_JSON_PATH}" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    settings = json.load(f)

# v1.5.6: self-locating leader-wake. worktree 또는 sub-dir 에서 실행돼도
# .company-kit 가 있는 부모를 찾아 절대경로로 hook 을 호출한다.
LEADER_WAKE_CMD = (
    'bash -c \'d="$PWD"; while [ "$d" != "/" ] && [ ! -d "$d/.company-kit" ]; '
    'do d="$(dirname "$d")"; done; '
    'if [ -d "$d/.company-kit" ]; then '
    'COMPANY_PROJECT_ROOT="$d" bash "$d/.company-kit/scripts/hooks/claude-userpromptsubmit-leader-wake.sh"; '
    'fi\''
)
LEGACY_LEADER_WAKE = "bash .company-kit/scripts/hooks/claude-userpromptsubmit-leader-wake.sh"
hooks = settings.setdefault("hooks", {})
ups = hooks.setdefault("UserPromptSubmit", [])

def find_leader_wake(entries):
    for ei, entry in enumerate(entries):
        for hi, h in enumerate(entry.get("hooks", [])):
            cmd = h.get("command", "").strip() if h.get("type") == "command" else ""
            if cmd == LEADER_WAKE_CMD:
                return (ei, hi, "current")
            if cmd == LEGACY_LEADER_WAKE or "claude-userpromptsubmit-leader-wake.sh" in cmd:
                return (ei, hi, "legacy")
    return None

found = find_leader_wake(ups)
if found and found[2] == "current":
    print("settings.json: leader-wake hook already at current self-locating form — no-op")
    sys.exit(0)
if found and found[2] == "legacy":
    ei, hi, _ = found
    ups[ei]["hooks"][hi] = {"type": "command", "command": LEADER_WAKE_CMD}
    with open(path, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("settings.json: leader-wake hook upgraded to self-locating form (worktree-safe)")
    sys.exit(0)

ups.append({
    "hooks": [
        {"type": "command", "command": LEADER_WAKE_CMD}
    ]
})
with open(path, "w", encoding="utf-8") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")
print("settings.json: leader-wake hook merged into UserPromptSubmit")
PYEOF
elif [[ -f "${SETTINGS_JSON_PATH}" ]]; then
  echo "  ⚠️  python3 미설치 — settings.json 의 leader-wake hook 자동 merge 를 건너뜁니다." >&2
  echo "      수동 등록: hooks.UserPromptSubmit 에" >&2
  echo "      'bash .company-kit/scripts/hooks/claude-userpromptsubmit-leader-wake.sh' 을 추가해 주세요." >&2
fi

# Agent 재생성 — .company-template.lock에서 categories 읽기
UPDATE_CATEGORIES="base,business,engineering,design"
if [[ -f "${LOCK_FILE}" ]]; then
  LOCK_CATEGORIES=$(grep "^categories:" "${LOCK_FILE}" 2>/dev/null | sed 's/^categories:[[:space:]]*//' || true)
  if [[ -n "${LOCK_CATEGORIES}" ]]; then
    UPDATE_CATEGORIES="${LOCK_CATEGORIES}"
  fi
fi
echo "  Regenerating agents (categories: ${UPDATE_CATEGORIES})..."
bash "${SCRIPT_DIR}/generate-project-agents.sh" "${TARGET_ROOT}" --categories="${UPDATE_CATEGORIES}"

# categories를 lock에 기록 (기존 프로젝트 업데이트 시에도 추적)
if [[ -f "${LOCK_FILE}" ]]; then
  if grep -q "^categories:" "${LOCK_FILE}"; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "s/^categories:.*/categories: ${UPDATE_CATEGORIES}/" "${LOCK_FILE}"
    else
      sed -i "s/^categories:.*/categories: ${UPDATE_CATEGORIES}/" "${LOCK_FILE}"
    fi
  else
    echo "categories: ${UPDATE_CATEGORIES}" >> "${LOCK_FILE}"
  fi
fi

# Legacy commands cleanup — 이전 /company 네임스페이스 명령을 삭제하고 루트로 이전됨
LEGACY_CMDS_DELETED=()
for _legacy_cmd in \
  spawn-team.md start-workstream.md rw.md spawn-worker.md run-workers.md \
  route-topic.md record-routing-feedback.md check-project.md \
  runtime-insights.md close-workstream.md help.md; do
  _legacy_path="${TARGET_ROOT}/.claude/commands/company/${_legacy_cmd}"
  if [[ -f "${_legacy_path}" ]]; then
    rm -f "${_legacy_path}"
    LEGACY_CMDS_DELETED+=("${_legacy_cmd}")
  fi
done
rmdir "${TARGET_ROOT}/.claude/commands/company" 2>/dev/null || true
if [[ ${#LEGACY_CMDS_DELETED[@]} -gt 0 ]]; then
  echo "  ℹ️  Removed ${#LEGACY_CMDS_DELETED[@]} legacy commands from .claude/commands/company/"
  echo "     (이전 /company/* 명령은 루트 /rw, /run-workers 등으로 이전되었습니다)"
fi

# Legacy Team/Agent Notices
LEGACY_NOTICES=()
if compgen -G "${TARGET_ROOT}/.claude/agents/company-*.md" >/dev/null 2>&1 \
   && [[ -f "${TARGET_ROOT}/.claude/agents/README.md" ]] \
   && ! grep -q "categories=" "${TARGET_ROOT}/.claude/agents/README.md" 2>/dev/null; then
  NOTICE_PATH=".company-project/_template-updates/legacy-agents.notice.md"
  mkdir -p "${TARGET_ROOT}/.company-project/_template-updates"
  cat > "${TARGET_ROOT}/${NOTICE_PATH}" <<EOF
# Legacy Agents Notice

이 프로젝트에는 예전 템플릿 버전에서 복사된 \`.claude/agents/company-*.md\` 파일이 남아 있습니다.
현재 기본 실행 경로는 \`/rw -> agent teams\` 입니다.
이 파일들은 참고용이 아니면 제거하는 것이 좋습니다.
EOF
  LEGACY_NOTICES+=("${NOTICE_PATH}")
fi

if [[ -f "${VERSION_FILE}" ]]; then
  TEMPLATE_VERSION="$(tr -d '\n' < "${VERSION_FILE}")"
  NOW="$(date '+%Y-%m-%dT%H:%M:%S%z' | sed 's/\(..\)$/:\1/')"

  if [[ -f "${TARGET_ROOT}/.company-template.lock" ]]; then
    # MacOS compatibility for sed -i
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "s/^template_version:.*/template_version: ${TEMPLATE_VERSION}/" "${TARGET_ROOT}/.company-template.lock"
      sed -i '' "s/^last_synced_at:.*/last_synced_at: ${NOW}/" "${TARGET_ROOT}/.company-template.lock"
    else
      sed -i "s/^template_version:.*/template_version: ${TEMPLATE_VERSION}/" "${TARGET_ROOT}/.company-template.lock"
      sed -i "s/^last_synced_at:.*/last_synced_at: ${NOW}/" "${TARGET_ROOT}/.company-template.lock"
    fi
  fi
fi

# 4. Finish
echo "  [4/4] Completing update..."
echo ""
echo "✨ Update Complete!"
echo ""
echo "✅ Automatically Refreshed (Engine & Standards):"
for f in "${REFRESHED_FILES[@]}"; do echo "  - ${f}"; done
echo "  - .company-kit/ (all contents)"

echo ""
echo "📝 Review Required (Latest templates written as preview):"
for f in "${PREVIEW_FILES[@]}"; do echo "  - ${f}"; done

if [[ ${#LEGACY_NOTICES[@]} -gt 0 ]]; then
  echo ""
  echo "⚠️ Legacy Notices (Action recommended):"
  for f in "${LEGACY_NOTICES[@]}"; do echo "  - ${f}"; done
fi

echo ""
echo "Recommended Next Steps:"
echo "1. Review and merge files in .company-project/_template-updates/"
echo "2. Restart or reopen Claude once so it refreshes slash commands."
echo "3. Run: company status (or bash .company-kit/scripts/check-template.sh)"
echo "4. Continue with: /rw <topic>"
echo "=========================================="
