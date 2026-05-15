#!/usr/bin/env bash
set -euo pipefail

# cmux-submit-worker-message.sh
#
# Submit a message to an already launched cmux worker pane.
# This intentionally goes through runner_cmux_send_worker_message so the text
# send and Enter keypress stay in one tested path. Do not replace this with
# ad-hoc `cmux send ... --press Enter`; cmux treats that as literal text.
#
# v1.5.6 — 기본 모드는 'reference': 큰 worker-request.md 본문을 cmux send 로
# 전부 밀어넣지 않고, 워커가 절대경로로 직접 Read 하도록 짧은 1-line 지시문만
# 보낸다. 본문을 그대로 보내고 싶으면 --inline 또는 환경변수
# COMPANY_CMUX_SUBMIT_MODE=inline 로 옵트인. inline 모드는 큰 본문에서
# 'cmux send' timeout 위험이 있으므로 reference 가 안전 default.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./git-worktree-lib.sh
source "${SCRIPT_DIR}/git-worktree-lib.sh"
# shellcheck source=./runner-lib.sh
source "${SCRIPT_DIR}/runner-lib.sh"

SUBMIT_MODE="${COMPANY_CMUX_SUBMIT_MODE:-reference}"
POSITIONAL=()
for _arg in "$@"; do
  case "${_arg}" in
    --inline)    SUBMIT_MODE="inline" ;;
    --reference) SUBMIT_MODE="reference" ;;
    *)           POSITIONAL+=("${_arg}") ;;
  esac
done

SESSION_ID="${POSITIONAL[0]:-}"
WORKER_NAME="${POSITIONAL[1]:-}"
PROJECT_ROOT_ARG="${POSITIONAL[2]:-.}"
MESSAGE_FILE="${POSITIONAL[3]:-}"

if [[ -z "${SESSION_ID}" || -z "${WORKER_NAME}" ]]; then
  echo "Usage: $0 <session_id> <worker_name> [project_root] [message_file] [--inline|--reference]" >&2
  echo "  --reference (default): worker reads the file via absolute path (avoids cmux send timeout on large bodies)" >&2
  echo "  --inline:              full body is sent through cmux (legacy; may timeout on >2KB messages)" >&2
  exit 1
fi

PROJECT_ROOT="$(resolve_shared_project_root "${PROJECT_ROOT_ARG}")"
WORKER_DIR="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}"
TARGET_FILE="${WORKER_DIR}/cmux-target"

if [[ ! -d "${WORKER_DIR}" ]]; then
  echo "cmux-submit-worker-message: worker dir not found: ${WORKER_DIR}" >&2
  exit 2
fi
if [[ -z "${MESSAGE_FILE}" ]]; then
  MESSAGE_FILE="${WORKER_DIR}/worker-request.md"
fi
if [[ ! -s "${MESSAGE_FILE}" ]]; then
  echo "cmux-submit-worker-message: message file not found or empty: ${MESSAGE_FILE}" >&2
  exit 3
fi
if [[ ! -s "${TARGET_FILE}" ]]; then
  echo "cmux-submit-worker-message: cmux target missing: ${TARGET_FILE}" >&2
  echo "Write one line such as 'surface:24' or run cmux-start-worker.sh first." >&2
  exit 4
fi

runner_load cmux 2>/dev/null || true
if ! declare -f runner_cmux_send_worker_message >/dev/null 2>&1; then
  echo "cmux-submit-worker-message: cmux runner functions unavailable" >&2
  exit 5
fi

# v1.5.6: reference 모드 (default) — 워커가 절대경로로 worker-request.md 를
# 직접 Read 하도록 짧은 지시문만 보낸다. inline 모드는 본문 전체 send (legacy).
case "${SUBMIT_MODE}" in
  reference)
    MESSAGE="$(printf 'Please read this worker request file using absolute path and follow it: %s\n\nAlso read context.md in the same directory: %s/context.md' \
      "${MESSAGE_FILE}" \
      "$(dirname "${MESSAGE_FILE}")")"
    ;;
  inline)
    MESSAGE="$(cat "${MESSAGE_FILE}")"
    _byte_size="$(wc -c < "${MESSAGE_FILE}" | tr -d ' ')"
    if [[ "${_byte_size}" -gt 2048 ]]; then
      echo "[WARN] inline mode with ${_byte_size} bytes — cmux send may timeout on >2KB. Consider --reference." >&2
    fi
    ;;
  *)
    echo "cmux-submit-worker-message: unknown submit mode: ${SUBMIT_MODE}" >&2
    exit 6
    ;;
esac

runner_cmux_send_worker_message "${SESSION_ID}" "${WORKER_NAME}" "${PROJECT_ROOT}" "${MESSAGE}"
echo "Submitted ${MESSAGE_FILE} to ${WORKER_NAME} ($(grep -E '^(surface|panel):' "${TARGET_FILE}" | head -n1)) [mode=${SUBMIT_MODE}]."
