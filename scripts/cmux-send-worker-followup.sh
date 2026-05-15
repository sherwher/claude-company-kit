#!/usr/bin/env bash
set -euo pipefail

# cmux-send-worker-followup.sh
#
# 워커 pane 에 후속 임의 메시지를 보낸다. cmux-submit-worker-message.sh 는
# worker-request.md 1회 전달 전용이며, 이후 리더 → 워커 임의 텍스트는 본
# 헬퍼 경유로만 보낸다 (CLAUDE.md 규칙 7). cmux 호환 차이는 cmux-lib.sh 의
# `cmux_submit_text` 단일 진실에 머문다 — 호출자는 surface 형식, send-key
# Enter 호환 분기를 신경쓰지 않는다.
#
# Usage:
#   cmux-send-worker-followup.sh <session> <worker> [project_root] -- <text>
#   cmux-send-worker-followup.sh <session> <worker> [project_root] -f <file>
#   echo 'message' | cmux-send-worker-followup.sh <session> <worker> [project_root]
#
# v1.5.11 신설.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./git-worktree-lib.sh
source "${SCRIPT_DIR}/git-worktree-lib.sh"
# shellcheck source=./runner-lib.sh
source "${SCRIPT_DIR}/runner-lib.sh"

MESSAGE_FILE=""
INLINE_TEXT=""
POSITIONAL=()

while (($# > 0)); do
  case "$1" in
    -f|--file)
      MESSAGE_FILE="${2:-}"
      shift 2
      ;;
    --)
      shift
      INLINE_TEXT="$*"
      break
      ;;
    -h|--help)
      sed -n '4,20p' "$0"
      exit 0
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

SESSION_ID="${POSITIONAL[0]:-}"
WORKER_NAME="${POSITIONAL[1]:-}"
PROJECT_ROOT_ARG="${POSITIONAL[2]:-.}"

if [[ -z "${SESSION_ID}" || -z "${WORKER_NAME}" ]]; then
  echo "Usage: $0 <session_id> <worker_name> [project_root] (-f <file> | -- <text>)" >&2
  echo "       echo 'msg' | $0 <session_id> <worker_name> [project_root]" >&2
  exit 1
fi

# 메시지 본문 결정 우선순위: --, -f, stdin
if [[ -n "${INLINE_TEXT}" ]]; then
  MESSAGE="${INLINE_TEXT}"
elif [[ -n "${MESSAGE_FILE}" ]]; then
  if [[ ! -s "${MESSAGE_FILE}" ]]; then
    echo "cmux-send-worker-followup: file not found or empty: ${MESSAGE_FILE}" >&2
    exit 3
  fi
  MESSAGE="$(cat "${MESSAGE_FILE}")"
elif [[ ! -t 0 ]]; then
  MESSAGE="$(cat)"
else
  echo "cmux-send-worker-followup: no message provided (-- <text> | -f <file> | stdin)" >&2
  exit 4
fi

if [[ -z "${MESSAGE}" ]]; then
  echo "cmux-send-worker-followup: empty message" >&2
  exit 5
fi

PROJECT_ROOT="$(resolve_shared_project_root "${PROJECT_ROOT_ARG}")"
WORKER_DIR="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers/${WORKER_NAME}"
TARGET_FILE="${WORKER_DIR}/cmux-target"

if [[ ! -d "${WORKER_DIR}" ]]; then
  echo "cmux-send-worker-followup: worker dir not found: ${WORKER_DIR}" >&2
  exit 2
fi
if [[ ! -s "${TARGET_FILE}" ]]; then
  echo "cmux-send-worker-followup: cmux target missing: ${TARGET_FILE}" >&2
  echo "Run cmux-start-worker.sh first." >&2
  exit 4
fi

runner_load cmux 2>/dev/null || true
if ! declare -f runner_cmux_send_worker_message >/dev/null 2>&1; then
  echo "cmux-send-worker-followup: cmux runner functions unavailable" >&2
  exit 5
fi

# 큰 본문은 cmux send 가 timeout 날 수 있다. 2KB 초과 시 경고.
_byte_size="$(printf '%s' "${MESSAGE}" | wc -c | tr -d ' ')"
if [[ "${_byte_size}" -gt 2048 ]]; then
  echo "[WARN] followup message ${_byte_size} bytes — cmux send may timeout on >2KB. 큰 본문은 파일로 떨어뜨린 뒤 절대경로를 메시지로 보내고 워커가 Read 하도록 하세요." >&2
fi

runner_cmux_send_worker_message "${SESSION_ID}" "${WORKER_NAME}" "${PROJECT_ROOT}" "${MESSAGE}"
echo "Sent followup to ${WORKER_NAME} ($(grep -E '^(surface|panel):' "${TARGET_FILE}" | head -n1)) [${_byte_size}B]."
