#!/usr/bin/env bash
set -euo pipefail

TARGET_ROOT="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -z "${TARGET_ROOT}" ]]; then
  echo "Usage: $0 <target-project-root>"
  exit 1
fi

mkdir -p "${TARGET_ROOT}/.company-kit"

if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude '.git/' \
    --exclude '.omc/' \
    --exclude '.omx/' \
    --exclude '.company-runtime/' \
    --exclude '.company-artifacts/' \
    --exclude '.company-exports/' \
    --exclude '.claude/settings.local.json' \
    --exclude 'firebase-debug.log' \
    --exclude '.DS_Store' \
    "${TEMPLATE_ROOT}/" "${TARGET_ROOT}/.company-kit/"
else
  rm -rf "${TARGET_ROOT}/.company-kit"
  mkdir -p "${TARGET_ROOT}/.company-kit"
  (
    cd "${TEMPLATE_ROOT}"
    tar \
      --exclude='.git' \
      --exclude='.omc' \
      --exclude='.omx' \
      --exclude='.company-runtime' \
      --exclude='.company-artifacts' \
      --exclude='.company-exports' \
      --exclude='.claude/settings.local.json' \
      --exclude='firebase-debug.log' \
      --exclude='.DS_Store' \
      -cf - .
  ) | (
    cd "${TARGET_ROOT}/.company-kit"
    tar -xf -
  )
fi

echo "Exported template to ${TARGET_ROOT}/.company-kit"
