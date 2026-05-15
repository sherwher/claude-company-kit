#!/usr/bin/env bash
set -euo pipefail

CHANGELOG_FILE="$1"
FROM_VERSION="$2"
TO_VERSION="$3"

if [[ ! -f "${CHANGELOG_FILE}" ]]; then
  echo "(Changelog not found)"
  exit 0
fi

# Find the start line for TO_VERSION (latest we want to show)
# We search for headers like "## 1.0.0" or "## [1.0.0]"
START_LINE=$(grep -nE "^## (\[)?${TO_VERSION}(\])?" "${CHANGELOG_FILE}" | cut -d: -f1 | head -n 1 || true)

# If TO_VERSION not found, start from the very first version header
if [[ -z "${START_LINE}" ]]; then
  START_LINE=$(grep -n "^## " "${CHANGELOG_FILE}" | head -n 1 | cut -d: -f1 || true)
fi

# Find the end line for FROM_VERSION (where we stop)
END_LINE=$(grep -nE "^## (\[)?${FROM_VERSION}(\])?" "${CHANGELOG_FILE}" | cut -d: -f1 | head -n 1 || true)

if [[ -z "${START_LINE}" ]]; then
  echo "(No version headers found in changelog)"
  exit 0
fi

if [[ -n "${END_LINE}" ]]; then
  if [[ "${START_LINE}" -eq "${END_LINE}" ]]; then
    echo "(Already at version ${FROM_VERSION})"
    exit 0
  fi
  if [[ "${START_LINE}" -gt "${END_LINE}" ]]; then
    echo "(Target version ${TO_VERSION} is older than current version ${FROM_VERSION})"
    exit 0
  fi
  # Show lines between START_LINE and END_LINE (exclusive of END_LINE)
  sed -n "${START_LINE},$((END_LINE - 1))p" "${CHANGELOG_FILE}" | sed '/^$/d'
else
  # Show lines from START_LINE to the end
  sed -n "${START_LINE},$ p" "${CHANGELOG_FILE}" | sed '/^$/d'
fi
