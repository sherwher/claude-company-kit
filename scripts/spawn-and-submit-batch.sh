#!/usr/bin/env bash
set -euo pipefail

# spawn-and-submit-batch.sh
#
# 다수 워커를 한 번에 spawn 하고 첫 입력(worker-request.md)까지 submit 한다.
# 이전에는 리더가 워커마다 cmux-start-worker → sleep → verify → submit 을
# sequential chain 으로 직접 짰는데, harness 는 sleep 체이닝을 차단한다 →
# supporting 워커 submit 이 중간에 끊긴다 (R-2026-05-08 회귀).
#
# 본 스크립트는 cmux-start-worker.sh 의 ready-wait + verify 를 워커별로 한
# 번씩 돌고 곧바로 cmux-submit-worker-message.sh 를 호출하므로, 리더는 단일
# 호출만으로 N 명을 spawn+submit 할 수 있다.
#
# split direction 은 right → down → left → up 으로 자동 회전. 한 워커가
# split 실패하면 다음 direction 으로 1회 재시도하고 그래도 실패면 명단에
# 모아 끝에 보고하고 비-0 exit.
#
# Usage:
#   spawn-and-submit-batch.sh <session> <project_root> <worker1> [worker2 ...]
#
# Env:
#   COMPANY_WORKER_PERMISSION_MODE  cmux-start-worker 권한 모드 (기본 acceptEdits)
#   COMPANY_BATCH_DIRECTIONS        공백 구분 direction 회전 순서 (기본 "right down left up")
#
# v1.5.11 신설.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./git-worktree-lib.sh
source "${SCRIPT_DIR}/git-worktree-lib.sh"

SESSION_ID="${1:-}"
PROJECT_ROOT_ARG="${2:-}"
shift 2 || true
WORKERS=("$@")

if [[ -z "${SESSION_ID}" || -z "${PROJECT_ROOT_ARG}" || ${#WORKERS[@]} -eq 0 ]]; then
  echo "Usage: $0 <session_id> <project_root> <worker1> [worker2 ...]" >&2
  exit 1
fi

PROJECT_ROOT="$(resolve_shared_project_root "${PROJECT_ROOT_ARG}")"

# direction 회전 순서
read -r -a _DIRS <<< "${COMPANY_BATCH_DIRECTIONS:-right down left up}"
_DIR_COUNT=${#_DIRS[@]}

failed_workers=()
spawn_count=0
submit_count=0

for worker in "${WORKERS[@]}"; do
  worker="$(printf '%s' "${worker}" | xargs)"
  [[ -n "${worker}" ]] || continue

  worker_dir="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}/workers/${worker}"
  if [[ ! -d "${worker_dir}" ]]; then
    echo "[ERROR] worker not prepared: ${worker} (run prepare-worker.sh 먼저)" >&2
    failed_workers+=("${worker}:not-prepared")
    continue
  fi

  # spawn — direction 1차 시도 후 실패 시 다음 direction 으로 1회 재시도
  spawn_ok=0
  for _try in 0 1; do
    direction="${_DIRS[$(( (spawn_count + _try) % _DIR_COUNT ))]}"
    echo "[batch] spawn ${worker} (direction=${direction}, try=$((_try + 1)))"
    if bash "${SCRIPT_DIR}/cmux-start-worker.sh" \
         "${SESSION_ID}" "${worker}" "${PROJECT_ROOT}" "${direction}"; then
      spawn_ok=1
      break
    fi
    echo "[batch] spawn ${worker} failed on direction=${direction}, 다음 direction 으로 재시도" >&2
  done

  if [[ "${spawn_ok}" != "1" ]]; then
    failed_workers+=("${worker}:spawn-failed")
    continue
  fi
  spawn_count=$((spawn_count + 1))

  # submit — cmux-start-worker 가 ready-polling 까지 끝낸 직후라 곧바로 보낸다
  if bash "${SCRIPT_DIR}/cmux-submit-worker-message.sh" \
       "${SESSION_ID}" "${worker}" "${PROJECT_ROOT}"; then
    submit_count=$((submit_count + 1))
    echo "[batch] submitted worker-request to ${worker}"
  else
    failed_workers+=("${worker}:submit-failed")
  fi
done

echo
echo "[batch] summary: spawn=${spawn_count} submit=${submit_count} failed=${#failed_workers[@]}"
if (( ${#failed_workers[@]} > 0 )); then
  printf '[batch] failures:\n'
  for f in "${failed_workers[@]}"; do
    printf '  - %s\n' "${f}"
  done
  exit 6
fi

exit 0
