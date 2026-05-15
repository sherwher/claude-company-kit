#!/usr/bin/env bash
# smoke-slack-dispatch.sh — R23 Slack outbound E2E smoke (mock webhook)
#
# 목적: event-flush.mjs --once 를 실제 실행하여 mock HTTP server 가
#       POST 를 최소 1 건 수신하는지 검증. DLQ 0, cursor append 3 조건 전수.
#
# 의존성:
#   - node (event-flush.mjs 실행)
#   - python3 (mock HTTP server — harness 기존 의존)
#   - bash scripts/generate-slack-routes-json.sh (routes.json 생성)
#
# 사용:
#   bash scripts/smoke-slack-dispatch.sh
#
# 환경 변수:
#   SMOKE_PORT=18765   mock webhook 포트 (override 가능)
#
# 성공 조건:
#   1. mock webhook POST 최소 1 건 수신
#   2. DLQ 0 건 (파일 없거나 비어있음)
#   3. cursor append 확인 (state.jsonl 에 "kind":"cursor" 존재)
#
# opt-in 상태와 무관하게 SLACK_WEBHOOK_URL 을 localhost mock 으로 강제 설정하여
# 실제 Slack workspace 호출 0 건 유지.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PORT="${SMOKE_PORT:-18765}"
FLUSH_SCRIPT="${KIT_DIR}/scripts/integrations/slack/event-flush.mjs"
GEN_SCRIPT="${KIT_DIR}/scripts/generate-slack-routes-json.sh"

PASS_COUNT=0
FAIL_COUNT=0

smoke_pass() { echo "  PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
smoke_fail() { echo "  FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo "[smoke-slack-dispatch] R23 outbound E2E smoke 시작"
echo ""

# ── 사전 조건 확인 ──────────────────────────────────────────────────────────
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node 미설치 — smoke 건너뜀 (opt-in OFF 회귀 0 원칙 유지)" >&2
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 미설치 — smoke 건너뜀" >&2
  exit 0
fi
if [[ ! -f "${FLUSH_SCRIPT}" ]]; then
  echo "FAIL: event-flush.mjs 없음: ${FLUSH_SCRIPT}" >&2
  exit 1
fi

# ── 임시 디렉토리 설정 ──────────────────────────────────────────────────────
TMPDIR_SMOKE="$(mktemp -d)"
SMOKE_RUNTIME="${TMPDIR_SMOKE}/.company-runtime"
SMOKE_HARNESS="${SMOKE_RUNTIME}/harness"
SMOKE_RELAY="${SMOKE_RUNTIME}/relay"
SMOKE_DLQ="${SMOKE_RUNTIME}/dlq"
SMOKE_CAPTURE="${TMPDIR_SMOKE}/captured-payload.json"
SMOKE_SERVER_LOG="${TMPDIR_SMOKE}/server.log"

mkdir -p "${SMOKE_HARNESS}" "${SMOKE_RELAY}" "${SMOKE_DLQ}"

# R26 Phase 4b: slack-thread.env fixture — event-flush 가 thread_ts 를 payload 에 주입하는지 검증.
# 세션 ID 는 합성 events.jsonl 의 session_id="smoke-test" 와 일치시킨다.
SMOKE_SESSION_DIR="${SMOKE_RUNTIME}/sessions/smoke-test"
mkdir -p "${SMOKE_SESSION_DIR}"
SMOKE_THREAD_TS="1700000000.999999"
SMOKE_CHANNEL_ID="C_R26_SMOKE"
cat > "${SMOKE_SESSION_DIR}/slack-thread.env" <<EOF
# R26 Phase 4b smoke fixture
SLACK_SESSION_ID=smoke-test
SLACK_THREAD_TS=${SMOKE_THREAD_TS}
SLACK_CHANNEL_ID=${SMOKE_CHANNEL_ID}
SLACK_MESSAGE_TS=1700000000.000001
SLACK_PERSISTED_AT=2026-04-09T00:00:00.000Z
EOF
chmod 600 "${SMOKE_SESSION_DIR}/slack-thread.env"

_SMOKE_FINAL_RC=0
cleanup() {
  # SERVER_PID 가 0 또는 미설정이면 kill/wait 스킵 (wait 0 = 전체 bg 프로세스 대기 방지)
  if [[ "${SERVER_PID:-0}" -gt 0 ]]; then
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
  rm -rf "${TMPDIR_SMOKE}"
  # trap 내부 명령 exit code 가 최종 exit code 를 오염시키지 않도록 명시 강제
  exit "${_SMOKE_FINAL_RC}"
}
trap cleanup EXIT

# ── routes.json 생성 ────────────────────────────────────────────────────────
echo "[smoke] routes.json 생성..."
SLACK_ROUTES_OUTPUT="${SMOKE_HARNESS}/slack-routes.json" \
  bash "${GEN_SCRIPT}" "${KIT_DIR}" > /dev/null
if [[ ! -f "${SMOKE_HARNESS}/slack-routes.json" ]]; then
  echo "FAIL: slack-routes.json 생성 실패" >&2
  exit 1
fi

# ── 합성 events.jsonl 생성 (spawn_success 이벤트 1 건) ─────────────────────
echo "[smoke] 합성 events.jsonl 생성..."
cat > "${SMOKE_HARNESS}/events.jsonl" <<'EOF'
{"ts":"2026-04-09T00:00:00Z","event":"spawn_success","session_id":"smoke-test","worker":"test-worker","severity":"P3","summary_ko":"워커 기동 이행 완료"}
EOF

# ── python3 mock webhook server (1 회 POST 수신 후 종료) ────────────────────
echo "[smoke] mock webhook server 기동 (port=${PORT})..."

python3 - "${PORT}" "${SMOKE_CAPTURE}" "${SMOKE_SERVER_LOG}" <<'PYEOF' &
import http.server
import json
import os
import sys
import socket

port = int(sys.argv[1])
capture_path = sys.argv[2]
log_path = sys.argv[3]
ready_path = capture_path + '.ready'

received_count = [0]

class MockWebhookHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('content-length', 0))
        body = self.rfile.read(length).decode('utf-8')
        with open(capture_path, 'w') as f:
            f.write(body)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'ok')
        received_count[0] += 1

    def log_message(self, fmt, *args):
        with open(log_path, 'a') as f:
            f.write(fmt % args + '\n')

try:
    server = http.server.HTTPServer(('127.0.0.1', port), MockWebhookHandler)
    # ready 파일 생성 → bash 가 bind 완료 확인
    with open(ready_path, 'w') as f:
        f.write('ready\n')
    # 최대 10 초 대기 (event-flush --once 는 수 초 내 완료)
    server.timeout = 10.0
    server.handle_request()
except Exception as e:
    with open(log_path, 'a') as f:
        f.write(f'ERROR: {e}\n')
    sys.exit(1)
PYEOF

SERVER_PID=$!
READY_FLAG="${SMOKE_CAPTURE}.ready"

# ready 파일 등장까지 대기 (최대 5 초)
for _i in $(seq 1 50); do
  if [[ -f "${READY_FLAG}" ]]; then
    break
  fi
  sleep 0.1
done

if [[ ! -f "${READY_FLAG}" ]]; then
  echo "FAIL: mock webhook server bind 실패 (5초 타임아웃)" >&2
  exit 1
fi

# ── event-flush --once 실행 ─────────────────────────────────────────────────
echo "[smoke] event-flush --once 실행..."
COMPANY_RUNTIME_ROOT="${SMOKE_RUNTIME}" \
COMPANY_EVENTS_PATH="${SMOKE_HARNESS}/events.jsonl" \
SLACK_ROUTES_PATH="${SMOKE_HARNESS}/slack-routes.json" \
EVENT_FLUSH_STATE_PATH="${SMOKE_RELAY}/state.jsonl" \
EVENT_FLUSH_DLQ_PATH="${SMOKE_DLQ}/slack-events.jsonl" \
EVENT_FLUSH_BOOTSTRAP_MODE="beginning" \
SLACK_WEBHOOK_URL="http://127.0.0.1:${PORT}/" \
  node "${FLUSH_SCRIPT}" --once
FLUSH_RC=$?

# server 는 handle_request() 완료 후 이미 종료됐거나 flush --once 가 종료됨
# wait 의 non-zero exit (SIGTERM 등) 는 smoke assertion 에 영향 없으므로 흡수
wait "${SERVER_PID}" 2>/dev/null || true
SERVER_PID=0

echo ""
echo "── assertion ──"

# ── 조건 1: mock webhook POST 수신 ──────────────────────────────────────────
if [[ "${FLUSH_RC}" -ne 0 ]]; then
  smoke_fail "event-flush --once exit code: ${FLUSH_RC}"
elif [[ -s "${SMOKE_CAPTURE}" ]]; then
  smoke_pass "mock webhook POST 수신 OK"
else
  smoke_fail "mock webhook 수신 0 건 (capture 파일 비어있음)"
fi

# ── 조건 2: block-kit payload 존재 ──────────────────────────────────────────
if [[ -s "${SMOKE_CAPTURE}" ]]; then
  if python3 -c "
import json, sys
data = json.load(open('${SMOKE_CAPTURE}'))
assert 'blocks' in data or 'text' in data, 'block-kit 필드 없음'
print('payload fields:', list(data.keys()))
" 2>/dev/null; then
    smoke_pass "block-kit payload 구조 확인 OK"
  else
    smoke_fail "block-kit payload 구조 이상 (blocks/text 필드 없음)"
  fi
fi

# ── 조건 3: DLQ 0 건 ─────────────────────────────────────────────────────────
DLQ_FILE="${SMOKE_DLQ}/slack-events.jsonl"
if [[ ! -f "${DLQ_FILE}" ]] || [[ ! -s "${DLQ_FILE}" ]]; then
  smoke_pass "DLQ 0 건 OK"
else
  DLQ_LINES="$(wc -l < "${DLQ_FILE}" | tr -d ' ')"
  smoke_fail "DLQ ${DLQ_LINES} 건 존재: $(head -1 "${DLQ_FILE}")"
fi

# ── 조건 4: cursor append 확인 ───────────────────────────────────────────────
STATE_FILE="${SMOKE_RELAY}/state.jsonl"
if [[ -f "${STATE_FILE}" ]] && grep -q '"kind":"cursor"' "${STATE_FILE}" 2>/dev/null; then
  smoke_pass "cursor append 확인 OK"
else
  smoke_fail "cursor append 없음 (state.jsonl 미생성 또는 kind:cursor 없음)"
fi

# ── 조건 5 (R26 Phase 4b): payload 에 thread_ts 주입됐는지 확인 ──────────────
if [[ -s "${SMOKE_CAPTURE}" ]]; then
  if python3 -c "
import json, sys
data = json.load(open('${SMOKE_CAPTURE}'))
assert data.get('thread_ts') == '${SMOKE_THREAD_TS}', f'thread_ts 불일치: {data.get(\"thread_ts\")}'
print('thread_ts OK:', data['thread_ts'])
" 2>/dev/null; then
    smoke_pass "thread_ts 주입 확인 OK (R26 Phase 4b)"
  else
    smoke_fail "thread_ts 누락 또는 불일치 — 기대값=${SMOKE_THREAD_TS}"
  fi
fi

# ── 결과 요약 ────────────────────────────────────────────────────────────────
echo ""
if [[ "${FAIL_COUNT}" -eq 0 ]]; then
  echo "PASS: smoke-slack-dispatch — ${PASS_COUNT} 조건 전수 통과 (DLQ 0, cursor append, block-kit payload, thread_ts 주입)"
  _SMOKE_FINAL_RC=0
else
  echo "FAIL: smoke-slack-dispatch — ${FAIL_COUNT} 조건 실패 / ${PASS_COUNT} 통과" >&2
  _SMOKE_FINAL_RC=1
fi
