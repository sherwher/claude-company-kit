#!/usr/bin/env bash
set -euo pipefail

# quality-gate.sh — release/readiness gate for the template repository.
#
# Scope:
# - fast repo hygiene checks always run
# - smoke matrix checks run unless --quick is passed
# - no network, no external service writes
#
# Usage:
#   bash scripts/quality-gate.sh
#   bash scripts/quality-gate.sh --quick

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
QUICK=0

for arg in "$@"; do
  case "${arg}" in
    --quick) QUICK=1 ;;
    --help|-h)
      echo "Usage: $0 [--quick]"
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      exit 2
      ;;
  esac
done

PASS=0
FAIL=0

run_gate() {
  local label="$1"
  shift
  echo "=== ${label} ==="
  if "$@"; then
    echo "PASS: ${label}"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${label}" >&2
    FAIL=$((FAIL + 1))
  fi
  echo ""
}

run_gate "git diff --check" git -C "${ROOT}" diff --check

run_gate "bash syntax" bash -c '
  set -euo pipefail
  root="$1"
  for f in "${root}"/scripts/*.sh; do
    bash -n "${f}"
  done
' -- "${ROOT}"

run_gate "integration config" bash "${ROOT}/scripts/validate-integrations-config.sh"
run_gate "compact schemas" bash "${ROOT}/scripts/validate-compact-schemas.sh" "${ROOT}"
run_gate "doctor" bash "${ROOT}/scripts/doctor.sh" "${ROOT}"

if [[ "${QUICK}" -eq 0 ]]; then
  run_gate "sentinel scan smoke" bash "${ROOT}/scripts/smoke-sentinel-scan.sh"
  run_gate "timeout watchdog smoke" bash "${ROOT}/scripts/smoke-timeout-watchdog.sh"
  run_gate "slack callback smoke" node "${ROOT}/scripts/smoke-slack-callback.mjs"
  run_gate "runner smoke" bash "${ROOT}/scripts/smoke-runner.sh"
  run_gate "template smoke" bash "${ROOT}/scripts/check-template.sh"
fi

echo "─────────────────────────"
echo "Quality Gate: ${PASS} PASS / ${FAIL} FAIL"

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
