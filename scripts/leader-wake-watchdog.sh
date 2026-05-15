#!/usr/bin/env bash
# scripts/leader-wake-watchdog.sh (v1.4.5 신규)
#
# 목적: 워커가 compact-result.md 를 쓰거나 leader-inbox/*.md 메시지를 남겼는데도
#       메인(리더, Claude main pane) 이 다음 사용자 입력 전까지 그 사실을 모르는
#       "메인 멍 상태" 를 해소한다. permission-stall-watchdog 의 정반대 케이스.
#
# 정책 (permission-stall-watchdog 와 동일 운영 모델):
#   - one-shot 스캔만 수행. HTTP/sleep loop/daemon 금지 — cron/launchd 또는
#     UserPromptSubmit hook 에서 호출하는 패턴.
#   - emit 은 best-effort. 실패해도 메인 흐름을 막지 않는다.
#   - 사람용 알림(`tmux display-message`) 과 LLM 용 알림(pending marker → hook
#     이 system-reminder 로 주입) 은 **분리**된 두 채널이다.
#
# 사용:
#   bash scripts/leader-wake-watchdog.sh <session_id> [project_root] [--dry-run] [--quiet]
#
# 동작:
#   1. session 의 모든 워커 디렉토리 + leader-inbox 디렉토리 스캔.
#   2. 각 후보 파일에 대해 idempotency_key 계산:
#        <sid>:<source_type>:<source_id>:<artifact>:<mtime_epoch>:<size>:<sha256_head>
#      (mtime+size+hash 모두 키에 포함 → 파일이 재기록(같은 worker, 같은 파일)
#       돼도 새 wake 로 인식)
#   3. dedupe state (TSV) 와 비교. 처음 본 key 면:
#        - events.jsonl 에 leader_wake_ready + 소스별 이벤트 emit
#        - pending marker 파일 추가 (Notification/UserPromptSubmit hook 이 읽음)
#        - tmux display-message 1회 알림 (사람용; in-tmux 일 때만)
#   4. 종료 시 dedupe state 갱신.
#
# 멱등성:
#   같은 (mtime, size, sha256_head) 조합은 1회만 emit + marker 작성. 파일이
#   덮어써져 mtime 또는 hash 가 바뀌면 새 key → 다시 emit. 사용자가 hook 으로
#   소비하면 marker 가 consumed 디렉토리로 옮겨져 dedupe state 와 분리 추적.
#
# 사람용 알림 (tmux display-message):
#   - $TMUX 안에서만 실행. 1회 표시, 무한 갱신 금지 (anti-pattern).
#   - banner 카피: `[INBOX] 결과 1건 도착 — /rw 로 리더 동기화하세요.`

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SESSION_ID=""
PROJECT_ROOT="."
DRY_RUN=0
QUIET=0

for _arg in "$@"; do
  case "${_arg}" in
    --dry-run) DRY_RUN=1 ;;
    --quiet)   QUIET=1 ;;
    --help|-h)
      sed -n '2,38p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    -*)
      echo "leader-wake-watchdog: unknown option: ${_arg}" >&2
      exit 1
      ;;
    *)
      if [[ -z "${SESSION_ID}" ]]; then
        SESSION_ID="${_arg}"
      else
        PROJECT_ROOT="${_arg}"
      fi
      ;;
  esac
done

if [[ -z "${SESSION_ID}" ]]; then
  echo "Usage: $0 <session_id> [project_root] [--dry-run] [--quiet]" >&2
  exit 1
fi

SESSION_DIR="${PROJECT_ROOT}/.company-runtime/sessions/${SESSION_ID}"
WORKERS_DIR="${SESSION_DIR}/workers"
INBOX_DIR="${SESSION_DIR}/leader-inbox"
WAKE_DIR="${SESSION_DIR}/leader-wake"
PENDING_DIR="${WAKE_DIR}/pending"
CONSUMED_DIR="${WAKE_DIR}/consumed"
STATE_FILE="${WAKE_DIR}/state.tsv"   # key\tfirst_seen_iso\tlast_emitted_iso

if [[ ! -d "${SESSION_DIR}" ]]; then
  [[ "${QUIET}" -eq 1 ]] || echo "leader-wake-watchdog: session dir 없음 — session=${SESSION_ID} (정상 무동작)"
  exit 0
fi

mkdir -p "${WAKE_DIR}" "${PENDING_DIR}" "${CONSUMED_DIR}"

# ── helpers ────────────────────────────────────────────────────────────────
file_mtime_epoch() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

file_size() {
  wc -c < "$1" 2>/dev/null | tr -d ' '
}

# sha256 (head 64KB) — 큰 파일에서도 빠른 fingerprint
file_hash_head() {
  local _f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    head -c 65536 "${_f}" 2>/dev/null | sha256sum | cut -c1-12
  elif command -v shasum >/dev/null 2>&1; then
    head -c 65536 "${_f}" 2>/dev/null | shasum -a 256 | cut -c1-12
  else
    # fallback: cksum (정확도는 떨어지지만 dedupe 용도로는 충분)
    head -c 65536 "${_f}" 2>/dev/null | cksum | awk '{print $1}'
  fi
}

state_seen() {
  local _key="$1"
  [[ -f "${STATE_FILE}" ]] || return 1
  awk -F'\t' -v k="${_key}" '$1==k {found=1; exit} END {exit found?0:1}' "${STATE_FILE}"
}

state_record() {
  local _key="$1"
  local _first="$2"
  local _emitted="$3"
  local _tmp
  _tmp="$(mktemp 2>/dev/null || mktemp -t lwwd)"
  if [[ -f "${STATE_FILE}" ]]; then
    awk -F'\t' -v k="${_key}" '$1!=k' "${STATE_FILE}" > "${_tmp}" 2>/dev/null || true
  fi
  printf '%s\t%s\t%s\n' "${_key}" "${_first}" "${_emitted}" >> "${_tmp}"
  mv "${_tmp}" "${STATE_FILE}"
}

# pending marker 파일 — UserPromptSubmit hook 이 읽어 system-reminder 로 주입.
# 파일명: <epoch>-<source_type>-<source_id>.txt (정렬 친화)
write_pending() {
  local _key="$1"
  local _source_type="$2"
  local _source_id="$3"
  local _artifact="$4"
  local _now_epoch
  _now_epoch="$(date -u +%s)"
  local _safe_id
  _safe_id="$(printf '%s' "${_source_id}" | tr -c 'A-Za-z0-9_.-' '_')"
  local _name="${_now_epoch}-${_source_type}-${_safe_id}.txt"
  printf 'source_type=%s\nsource_id=%s\nartifact=%s\nkey=%s\nemitted_at=%s\n' \
    "${_source_type}" "${_source_id}" "${_artifact}" "${_key}" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "${PENDING_DIR}/${_name}"
}

# 사람용 banner — in-tmux 일 때만, 1회 표시.
human_banner() {
  local _count="$1"
  if [[ -z "${TMUX:-}" ]] || ! command -v tmux >/dev/null 2>&1; then
    return 0
  fi
  local _msg="[INBOX] 결과 ${_count}건 도착 — /rw 로 리더 동기화하세요."
  tmux display-message "${_msg}" 2>/dev/null || true
}

scan_source() {
  local _source_type="$1"   # worker | inbox
  local _source_id="$2"     # worker name | message file basename
  local _file="$3"
  local _artifact="$4"      # compact-result | compact-plan | inbox

  [[ -f "${_file}" ]] || return 0
  local _sz
  _sz="$(file_size "${_file}")"
  # 너무 작은 파일은 템플릿 placeholder 일 가능성 → skip (result-collector 기준)
  if [[ "${_artifact}" == "compact-result" || "${_artifact}" == "compact-plan" ]]; then
    [[ "${_sz:-0}" -ge 200 ]] || return 0
  fi

  local _mt _hash _key _now_iso
  _mt="$(file_mtime_epoch "${_file}")"
  _hash="$(file_hash_head "${_file}")"
  _key="${SESSION_ID}:${_source_type}:${_source_id}:${_artifact}:${_mt}:${_sz}:${_hash}"
  _now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if state_seen "${_key}"; then
    return 0
  fi

  if [[ "${QUIET}" -eq 0 ]]; then
    echo "leader-wake-watchdog: WAKE — source=${_source_type} id=${_source_id} artifact=${_artifact} size=${_sz} mtime=${_mt}"
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi

  # canonical umbrella + 소스별 이벤트
  bash "${SCRIPT_DIR}/company-emit.sh" "leader_wake_ready" "${SESSION_ID}" "${PROJECT_ROOT}" \
    "source_type=${_source_type}" \
    "source_id=${_source_id}" \
    "artifact=${_artifact}" \
    "mtime=${_mt}" \
    "size=${_sz}" \
    "hash_head=${_hash}" \
    "idempotency_key=${_key}" \
    >/dev/null 2>&1 || true

  case "${_source_type}" in
    worker)
      bash "${SCRIPT_DIR}/company-emit.sh" "leader_compact_result_ready" "${SESSION_ID}" "${PROJECT_ROOT}" \
        "worker=${_source_id}" \
        "artifact=${_artifact}" \
        "mtime=${_mt}" "size=${_sz}" "hash_head=${_hash}" \
        "idempotency_key=${_key}" \
        >/dev/null 2>&1 || true
      ;;
    inbox)
      bash "${SCRIPT_DIR}/company-emit.sh" "leader_inbox_message_ready" "${SESSION_ID}" "${PROJECT_ROOT}" \
        "message=${_source_id}" \
        "mtime=${_mt}" "size=${_sz}" "hash_head=${_hash}" \
        "idempotency_key=${_key}" \
        >/dev/null 2>&1 || true
      ;;
  esac

  write_pending "${_key}" "${_source_type}" "${_source_id}" "${_artifact}"
  state_record "${_key}" "${_now_iso}" "${_now_iso}"
  return 0
}

# ── scan: workers (compact-result, compact-plan) ────────────────────────────
emitted_count=0
if [[ -d "${WORKERS_DIR}" ]]; then
  while IFS= read -r _worker_dir; do
    [[ -d "${_worker_dir}" ]] || continue
    _worker="$(basename "${_worker_dir}")"
    for _artifact in compact-result compact-plan; do
      _file="${_worker_dir}/${_artifact}.md"
      if [[ -f "${_file}" ]]; then
        before="$(ls "${PENDING_DIR}" 2>/dev/null | wc -l | tr -d ' ')"
        scan_source "worker" "${_worker}" "${_file}" "${_artifact}"
        after="$(ls "${PENDING_DIR}" 2>/dev/null | wc -l | tr -d ' ')"
        if (( after > before )); then
          emitted_count=$((emitted_count + 1))
        fi
      fi
    done
  done < <(find "${WORKERS_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
fi

# ── scan: leader-inbox (선택적; 디렉토리 없으면 skip) ────────────────────────
if [[ -d "${INBOX_DIR}" ]]; then
  while IFS= read -r _msg; do
    [[ -f "${_msg}" ]] || continue
    _id="$(basename "${_msg}")"
    before="$(ls "${PENDING_DIR}" 2>/dev/null | wc -l | tr -d ' ')"
    scan_source "inbox" "${_id}" "${_msg}" "inbox"
    after="$(ls "${PENDING_DIR}" 2>/dev/null | wc -l | tr -d ' ')"
    if (( after > before )); then
      emitted_count=$((emitted_count + 1))
    fi
  done < <(find "${INBOX_DIR}" -mindepth 1 -maxdepth 1 -type f -name "*.md" 2>/dev/null | sort)
fi

if (( emitted_count > 0 )); then
  human_banner "${emitted_count}"
fi

if [[ "${QUIET}" -eq 0 ]]; then
  echo "leader-wake-watchdog: session=${SESSION_ID} new_wakes=${emitted_count} pending=$(ls "${PENDING_DIR}" 2>/dev/null | wc -l | tr -d ' ')"
fi

exit 0
