#!/usr/bin/env bash
set -euo pipefail

# scripts/smoke-runner.sh (v1.4.4 — inside-context auto-select + permission stall)
#
# 목적: runner abstraction 의 핵심 매트릭스를 1 회 실행으로 검증한다.
#   (a) tmux 밖에서 `company run` 이 sequential 로 자동 폴백하여 완주
#   (b) --runner=sequential 강제 지정 시 동일 경로
#   (c) --runner=tmux --no-fallback 이 tmux 밖에서 실패하는지
#   (d) --runner=codex-native 가 sequential 로 폴백 (slot 러너 graceful 폴백)
#   (e) --runner=cmux 는 opt-in 없으면 hard fail (rc != 0, experimental gate)
#   (f) --runner=cmux --allow-experimental 는 detect 실패 → sequential 폴백
#   (g) preflight.json v4 의 state / allow_experimental / experimental_grant 필드 확인
#   (h) v1.3.9 P1: runner_probe_session_name 함수 단위 (정의/외부/후보 제외)
#   (i) v1.3.9 P2: spawn-readiness-check 의 cmux 분기 (CMUX 미설정 → soft OK)
#   (j) v1.3.9 P2: spawn-readiness 의 tmux/cmux 통합 case 패턴
#   (k) v1.4.2: fake-cmux PATH-prefix contract smoke
#   (l) v1.4.4: inside-cmux auto-select (CMUX_PANEL_ID + fake cmux → cmux 자동 선택, opt-in 면제)
#   (m) v1.4.4: preflight.experimental_grant=inside-context 자동 기록
#   (n) v1.4.4: permission-stall-watchdog 권한 prompt 시그너처 → emit + dedupe
#
# 실행:
#   bash scripts/smoke-runner.sh
#
# 성공 시 종료 코드 0 + 요약 출력. 실패 시 즉시 종료 + 원인 로그.
# macOS/Linux 공용 bash 3.2+. jq 는 필수.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_ROOT="$(mktemp -d /tmp/smoke-runner.XXXXXX)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

install_fresh() {
  local target="$1"
  bash "${KIT_DIR}/scripts/install-into-project.sh" "${target}" \
    --name=Smoke --domain='runner-smoke' --stack=smoke \
    --primary-worker=frontend-engineer --supporting-workers=backend-engineer >/dev/null
  (
    cd "${target}" && git init -q && git config user.email "smoke@t" && git config user.name smoke \
      && git add -A >/dev/null 2>&1 && git commit -qm init >/dev/null 2>&1 || true
  )
}

PASS=0
FAIL=0

check() {
  local label="$1"; shift
  if "$@"; then
    printf '[PASS] %s\n' "${label}"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s\n' "${label}" >&2
    FAIL=$((FAIL + 1))
  fi
}

# ── (a) auto outside tmux → sequential 자동 폴백 ────────────────────────────
echo "=== (a) tmux 밖에서 company run (auto → sequential) ==="
A_ROOT="${TMP_ROOT}/a"
mkdir -p "${A_ROOT}"
install_fresh "${A_ROOT}"
(
  cd "${A_ROOT}"
  unset TMUX TMUX_PANE CMUX_PANEL_ID CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_SOCKET CMUX_PORT CMUX_SURFACE_ID CMUX_BUNDLE_ID
  bash .company-kit/scripts/company run "스모크 A" >/dev/null 2>&1
)
A_PREFLIGHT="$(find "${A_ROOT}/.company-runtime/sessions" -name preflight.json | head -n1)"
check "(a) preflight.json 생성" test -f "${A_PREFLIGHT}"
A_RUNNER="$(jq -r '.runner' "${A_PREFLIGHT}")"
A_SOURCE="$(jq -r '.runner_source' "${A_PREFLIGHT}")"
check "(a) runner=sequential" test "${A_RUNNER}" = "sequential"
check "(a) source=auto" test "${A_SOURCE}" = "auto"
check "(a) runner_selected 이벤트 emit" \
  grep -q '"event":"runner_selected"' "${A_ROOT}/.company-runtime/harness/events.jsonl"
check "(a) spawn_prepared 이벤트 emit" \
  grep -q '"event":"spawn_prepared"' "${A_ROOT}/.company-runtime/harness/events.jsonl"
check "(a) spawn_ready 이벤트 emit (primary)" \
  grep -q '"event":"spawn_ready"' "${A_ROOT}/.company-runtime/harness/events.jsonl"

# ── (b) --runner=sequential 강제 ─────────────────────────────────────────────
echo "=== (b) --runner=sequential 강제 ==="
B_ROOT="${TMP_ROOT}/b"
mkdir -p "${B_ROOT}"
install_fresh "${B_ROOT}"
(
  cd "${B_ROOT}"
  unset TMUX TMUX_PANE CMUX_PANEL_ID CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_SOCKET CMUX_PORT CMUX_SURFACE_ID CMUX_BUNDLE_ID
  bash .company-kit/scripts/company run "스모크 B" --runner=sequential >/dev/null 2>&1
)
B_PREFLIGHT="$(find "${B_ROOT}/.company-runtime/sessions" -name preflight.json | head -n1)"
check "(b) source=flag" test "$(jq -r '.runner_source' "${B_PREFLIGHT}")" = "flag"
check "(b) runner=sequential" test "$(jq -r '.runner' "${B_PREFLIGHT}")" = "sequential"

# ── (c) --runner=tmux --no-fallback 은 tmux 밖에서 실패 ──────────────────────
echo "=== (c) --runner=tmux --no-fallback 밖에서 실패 ==="
C_ROOT="${TMP_ROOT}/c"
mkdir -p "${C_ROOT}"
install_fresh "${C_ROOT}"
set +e
(
  cd "${C_ROOT}"
  unset TMUX TMUX_PANE CMUX_PANEL_ID CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_SOCKET CMUX_PORT CMUX_SURFACE_ID CMUX_BUNDLE_ID
  bash .company-kit/scripts/company run "스모크 C" --runner=tmux --no-fallback >/dev/null 2>&1
)
C_RC=$?
set -e
check "(c) --no-fallback 실패 (rc != 0)" test "${C_RC}" -ne 0

# ── (d) --runner=codex-native (slot) → sequential 폴백 ─────────────────────
# v1.3.8: slot 러너는 여전히 graceful 폴백 (미구현 러너 오타 UX 보호).
# 기존에 이 자리를 차지하던 cmux 는 experimental 로 승격되었으므로 별도 케이스 (e)/(f) 로 이동.
echo "=== (d) --runner=codex-native (slot) → sequential 폴백 ==="
D_ROOT="${TMP_ROOT}/d"
mkdir -p "${D_ROOT}"
install_fresh "${D_ROOT}"
(
  cd "${D_ROOT}"
  unset TMUX TMUX_PANE CMUX_PANEL_ID CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_SOCKET CMUX_PORT CMUX_SURFACE_ID CMUX_BUNDLE_ID
  bash .company-kit/scripts/company run "스모크 D" --runner=codex-native >/dev/null 2>&1
)
D_PREFLIGHT="$(find "${D_ROOT}/.company-runtime/sessions" -name preflight.json | head -n1)"
check "(d) source=fallback" test "$(jq -r '.runner_source' "${D_PREFLIGHT}")" = "fallback"
check "(d) fallback_reason=codex-native-not-available" \
  test "$(jq -r '.fallback_reason' "${D_PREFLIGHT}")" = "codex-native-not-available"

# ── (e) --runner=cmux 는 opt-in 없으면 hard fail ───────────────────────────
# v1.3.8: experimental 러너는 --allow-experimental 없으면 rc=5 로 실패.
#         auto fallback 하지 않으므로 preflight.json 도 생성되지 않는다.
echo "=== (e) --runner=cmux (experimental, opt-in 없음) → hard fail ==="
E_ROOT="${TMP_ROOT}/e"
mkdir -p "${E_ROOT}"
install_fresh "${E_ROOT}"
set +e
(
  cd "${E_ROOT}"
  unset TMUX TMUX_PANE CMUX_PANEL_ID CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_SOCKET CMUX_PORT CMUX_SURFACE_ID CMUX_BUNDLE_ID
  bash .company-kit/scripts/company run "스모크 E" --runner=cmux >/dev/null 2>&1
)
E_RC=$?
set -e
check "(e) opt-in 없이 experimental 러너 요청 → rc != 0" test "${E_RC}" -ne 0
# preflight.json 은 resolve 가 5 로 종료되므로 생성되지 않아야 한다
E_PREFLIGHT="$(find "${E_ROOT}/.company-runtime/sessions" -name preflight.json 2>/dev/null | head -n1)"
check "(e) preflight.json 미생성 (resolve 단계 실패)" test -z "${E_PREFLIGHT}"

# ── (f) --runner=cmux --allow-experimental 는 detect 실패 → sequential 폴백 ─
# CI / 비-cmux 환경에서는 cmux 바이너리/CMUX env 가 없으므로 detect 가 실패 →
# opt-in 은 통과했지만 사용 불가이므로 sequential 로 fallback 된다.
echo "=== (f) --runner=cmux --allow-experimental → sequential 폴백 ==="
F_ROOT="${TMP_ROOT}/f"
mkdir -p "${F_ROOT}"
install_fresh "${F_ROOT}"
(
  cd "${F_ROOT}"
  unset TMUX TMUX_PANE CMUX CMUX_PANEL_ID CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_SOCKET CMUX_PORT CMUX_SURFACE_ID CMUX_BUNDLE_ID
  PATH="$(echo "$PATH" | tr ':' '\n' | grep -v 'cmux.app/Contents/Resources/bin' | paste -sd: -)" \
    bash .company-kit/scripts/company run "스모크 F" --runner=cmux --allow-experimental >/dev/null 2>&1
)
F_PREFLIGHT="$(find "${F_ROOT}/.company-runtime/sessions" -name preflight.json | head -n1)"
check "(f) source=fallback" test "$(jq -r '.runner_source' "${F_PREFLIGHT}")" = "fallback"
check "(f) fallback_reason=cmux-not-available" \
  test "$(jq -r '.fallback_reason' "${F_PREFLIGHT}")" = "cmux-not-available"
check "(f) allow_experimental=true 기록" \
  test "$(jq -r '.allow_experimental' "${F_PREFLIGHT}")" = "true"

# ── (g) preflight.json v4 스키마 필드 존재 ─────────────────────────────────
# v1.4.5 — schema bump v3 → v4, leader wake 필드 추가 (additive).
echo "=== (g) preflight.json v4 state/allow_experimental/experimental_grant 필드 ==="
check "(g.1) version=4" test "$(jq -r '.version' "${A_PREFLIGHT}")" = "4"
check "(g.2) state=stable (auto→sequential)" test "$(jq -r '.state' "${A_PREFLIGHT}")" = "stable"
check "(g.3) allow_experimental=false (default)" \
  test "$(jq -r '.allow_experimental' "${A_PREFLIGHT}")" = "false"
check "(g.4) experimental_grant=null (sequential 은 grant 없음)" \
  test "$(jq -r '.experimental_grant' "${A_PREFLIGHT}")" = "null"

# ── (h) v1.3.9 P1: runner_probe_session_name 단위 ──────────────────────────
echo "=== (h) runner_probe_session_name 단위 ==="
H_ROOT="${TMP_ROOT}/h"
mkdir -p "${H_ROOT}"
install_fresh "${H_ROOT}"
H_OUT="$(
  cd "${H_ROOT}"
  unset TMUX TMUX_PANE CMUX CMUX_PANEL_ID CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_SOCKET CMUX_PORT CMUX_SURFACE_ID CMUX_BUNDLE_ID
  bash -c '
    set -euo pipefail
    source ./.company-kit/scripts/runner-lib.sh
    if ! declare -f runner_probe_session_name >/dev/null 2>&1; then
      printf "no-fn\n"; exit 0
    fi
    out="$(runner_probe_session_name 2>/dev/null || true)"
    if [[ -z "${out}" ]]; then printf "empty\n"; else printf "non-empty: %s\n" "${out}"; fi
  '
)"
check "(h.1) probe 함수 정의 존재" test "${H_OUT}" != "no-fn"
check "(h.2) attached 러너 밖 → 빈 결과" test "${H_OUT}" = "empty"
H_BODY="$(bash -c 'source '"${H_ROOT}"'/.company-kit/scripts/runner-lib.sh && declare -f runner_probe_session_name')"
check "(h.3) probe 가 sequential/manual 을 후보에서 명시 제외" \
  bash -c "printf '%s' \"\$1\" | grep -qE 'sequential[[:space:]]*\\|[[:space:]]*manual[[:space:]]*\\)'" -- "${H_BODY}"

# ── (i) v1.3.9 P2: spawn-readiness-check 의 cmux 분기 ───────────────────────
# CMUX env 가 없을 때는 (cmux 클라이언트 밖) soft OK + 'cmux-not-inside' 로 떨어져야 한다.
echo "=== (i) spawn-readiness-check cmux 외부 → soft OK ==="
I_OUT="$(
  unset TMUX TMUX_PANE CMUX CMUX_PANEL_ID CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_SOCKET CMUX_PORT CMUX_SURFACE_ID CMUX_BUNDLE_ID
  COMPANY_RUNNER=cmux bash "${KIT_DIR}/scripts/spawn-readiness-check.sh" leader 2>&1 || true
)"
check "(i.1) Runner: cmux 보고" \
  bash -c "printf '%s' \"\$1\" | grep -q '^Runner: cmux$'" -- "${I_OUT}"
check "(i.2) Reason Code: cmux-not-inside" \
  bash -c "printf '%s' \"\$1\" | grep -q 'cmux-not-inside'" -- "${I_OUT}"
check "(i.3) Ready: soft (hard fail 아님)" \
  bash -c "printf '%s' \"\$1\" | grep -q 'Ready: soft'" -- "${I_OUT}"

# ── (j) v1.3.9 P2: tmux/cmux case 가 spawn-readiness 에서 통합 디스패치 ───
# 'tmux|cmux)' 패턴이 존재해야 P2 의 DRY 통합이 적용된 것.
echo "=== (j) spawn-readiness 의 tmux/cmux 통합 디스패치 ==="
check "(j.1) tmux|cmux) 통합 case 패턴 존재" \
  grep -q "tmux|cmux)" "${KIT_DIR}/scripts/spawn-readiness-check.sh"

# ── (k) v1.4.2: fake-cmux PATH-prefix contract smoke ───────────────────────
echo "=== (k) fake-cmux contract matrix ==="
FAKE_CMUX_DIR="${KIT_DIR}/tests/fixtures/fake-cmux"
K_ROOT="${TMP_ROOT}/k"
mkdir -p "${K_ROOT}"
install_fresh "${K_ROOT}"

K1_OUT="$(
  cd "${K_ROOT}"
  env PATH="${FAKE_CMUX_DIR}:$PATH" CMUX_PANEL_ID="panel-leader" \
    bash -c 'source ./.company-kit/scripts/runner-lib.sh; runner_load cmux; runner_cmux_detect && printf pass || printf fail'
)"
check "(k.1) CMUX_PANEL_ID 만 있어도 detect 통과" test "${K1_OUT}" = "pass"

check "(k.2) cmux display-message 호출 흔적 없음" \
  bash -c "! awk '/^[[:space:]]*#/ {next} /cmux[[:space:]]+display-message/ {found=1} END {exit found?0:1}' \"\$1\"" -- "${KIT_DIR}/scripts/runners/cmux.sh"
check "(k.3) cmux send-keys 호출 흔적 없음" \
  bash -c "! awk '/^[[:space:]]*#/ {next} /cmux[[:space:]]+send-keys/ {found=1} END {exit found?0:1}' \"\$1\" \"\$2\"" -- "${KIT_DIR}/scripts/runners/cmux.sh" "${KIT_DIR}/scripts/runner-lib.sh"

K4_LOG="${TMP_ROOT}/k4-cmux.log"
K4_WORKER_DIR="${K_ROOT}/.company-runtime/sessions/k-smoke/workers/frontend-engineer"
mkdir -p "${K4_WORKER_DIR}"
printf 'surface:abc\n' > "${K4_WORKER_DIR}/cmux-target"
(
  cd "${K_ROOT}"
  env PATH="${FAKE_CMUX_DIR}:$PATH" CMUX_PANEL_ID="panel-leader" CMUX_WORKSPACE_ID="ws-1" CMUX_FAKE_LOG="${K4_LOG}" \
    bash -c 'source ./.company-kit/scripts/runner-lib.sh; runner_load cmux; runner_cmux_send_worker_message k-smoke frontend-engineer "$PWD" "hello cmux"'
)
check "(k.4) cmux send --surface surface:abc 인자 정확" \
  grep -q '^send --surface surface:abc -- hello cmux$' "${K4_LOG}"
check "(k.4) cmux send-key --surface surface:abc enter 인자 정확" \
  grep -q '^send-key --surface surface:abc enter$' "${K4_LOG}"

check "(k.5) cmux list-panes -F 호출 흔적 없음" \
  bash -c "! awk '/^[[:space:]]*#/ {next} /cmux[[:space:]]+list-panes[^\\n]*[[:space:]]-F([[:space:]]|$)/ {found=1} END {exit found?0:1}' \"\$1\" \"\$2\" \"\$3\"" -- \
    "${KIT_DIR}/scripts/runners/cmux.sh" "${KIT_DIR}/scripts/runner-lib.sh" "${KIT_DIR}/scripts/spawn-readiness-check.sh"

K6_PANES="${TMP_ROOT}/k6-panes.txt"
printf 'surface:leader panel:leader-panel title=leader\n' > "${K6_PANES}"
(
  cd "${K_ROOT}"
  env PATH="${FAKE_CMUX_DIR}:$PATH" CMUX_PANEL_ID="panel-leader" CMUX_WORKSPACE_ID="ws-1" CMUX_FAKE_PANES_FILE="${K6_PANES}" COMPANY_RUNNER=cmux \
    bash .company-kit/scripts/prepare-worker.sh frontend-engineer k6-smoke "$PWD" >/dev/null
)
printf 'surface:leader panel:leader-panel title=leader\nsurface:abc panel:worker-panel title=worker\n' > "${K6_PANES}"
(
  cd "${K_ROOT}"
  env PATH="${FAKE_CMUX_DIR}:$PATH" CMUX_PANEL_ID="panel-leader" CMUX_WORKSPACE_ID="ws-1" CMUX_FAKE_PANES_FILE="${K6_PANES}" COMPANY_RUNNER=cmux \
    bash .company-kit/scripts/verify-worker-spawn.sh k6-smoke frontend-engineer "$PWD" 2 1 >/dev/null
)
check "(k.6) 신규 cmux surface 자동 등록" \
  grep -qx 'surface:abc' "${K_ROOT}/.company-runtime/sessions/k6-smoke/workers/frontend-engineer/cmux-target"

if [[ "${COMPANY_SMOKE_REAL_CMUX:-0}" == "1" ]]; then
  echo "=== (k.real) real cmux opt-in smoke ==="
  if command -v cmux >/dev/null 2>&1 && [[ -n "${CMUX_PANEL_ID:-}${CMUX_WORKSPACE_ID:-}" ]]; then
    K_REAL_OUT="$(bash -c 'source '"${KIT_DIR}"'/scripts/runner-lib.sh; runner_load cmux; runner_cmux_detect && printf pass || printf fail')"
    check "(k.real) real cmux detect" test "${K_REAL_OUT}" = "pass"
  else
    check "(k.real) real cmux opt-in 환경 없음" false
  fi
fi

# ── (l) v1.4.4: inside-cmux auto-select ─────────────────────────────────────
echo "=== (l) inside-cmux auto-select (v1.4.4) ==="
L_ROOT="${TMP_ROOT}/l"
mkdir -p "${L_ROOT}"
install_fresh "${L_ROOT}"

L1_OUT="$(
  cd "${L_ROOT}"
  env PATH="${FAKE_CMUX_DIR}:$PATH" CMUX_PANEL_ID="panel-leader" CMUX_WORKSPACE_ID="ws-1" \
    bash -c '
      source ./.company-kit/scripts/runner-lib.sh
      resolve_runner
      printf "%s|%s|%s|%s|%s" \
        "${RUNNER_SELECTED}" "${RUNNER_SOURCE}" "${RUNNER_SELECTED_STATE}" \
        "${RUNNER_ALLOW_EXPERIMENTAL}" "${RUNNER_EXPERIMENTAL_GRANT}"
    '
)"
check "(l.1) inside-cmux → RUNNER_SELECTED=cmux + source=auto" \
  bash -c "[[ \"\$1\" == cmux\\|auto\\|* ]]" -- "${L1_OUT}"
check "(l.2) inside-cmux 자동 선택 시 allow_experimental=1 (게이트 면제)" \
  bash -c "[[ \"\$1\" == *\\|*\\|*\\|1\\|* ]]" -- "${L1_OUT}"
check "(l.3) inside-cmux 자동 선택 시 experimental_grant=inside-context" \
  bash -c "[[ \"\$1\" == *\\|inside-context ]]" -- "${L1_OUT}"

# inside-cmux 가 아니더라도 outside + --runner=cmux + opt-in 없으면 여전히 hard fail (regression)
L4_RC=0
(
  cd "${L_ROOT}"
  env PATH="${FAKE_CMUX_DIR}:$PATH" \
    bash -c 'source ./.company-kit/scripts/runner-lib.sh; resolve_runner --runner=cmux' >/dev/null 2>&1
) || L4_RC=$?
check "(l.4) outside + --runner=cmux without opt-in → rc=5 유지" \
  test "${L4_RC}" = "5"

# ── (m) v1.4.4: preflight.experimental_grant 필드 자동 기록 ──────────────────
echo "=== (m) preflight.experimental_grant ==="
M_ROOT="${TMP_ROOT}/m"
mkdir -p "${M_ROOT}"
install_fresh "${M_ROOT}"

(
  cd "${M_ROOT}"
  env PATH="${FAKE_CMUX_DIR}:$PATH" CMUX_PANEL_ID="panel-leader" CMUX_WORKSPACE_ID="ws-1" \
    bash -c '
      source ./.company-kit/scripts/runner-lib.sh
      resolve_runner
      runner_write_preflight . m-smoke >/dev/null
    '
)
M_PRE="${M_ROOT}/.company-runtime/sessions/m-smoke/preflight.json"
check "(m.1) preflight.json version=4" \
  bash -c "jq -e '.version == 4' \"\$1\" >/dev/null" -- "${M_PRE}"
check "(m.2) preflight.experimental_grant=inside-context" \
  bash -c "jq -e '.experimental_grant == \"inside-context\"' \"\$1\" >/dev/null" -- "${M_PRE}"
check "(m.3) preflight.allow_experimental=true 자동 활성화" \
  bash -c "jq -e '.allow_experimental == true' \"\$1\" >/dev/null" -- "${M_PRE}"
check "(m.4) preflight.runner_source=auto (명시 opt-in 아님)" \
  bash -c "jq -e '.runner_source == \"auto\"' \"\$1\" >/dev/null" -- "${M_PRE}"

# ── (n) v1.4.4: permission-stall-watchdog ───────────────────────────────────
echo "=== (n) permission-stall-watchdog ==="
N_ROOT="${TMP_ROOT}/n"
N_WORKER="${N_ROOT}/.company-runtime/sessions/n-smoke/workers/worker-a"
mkdir -p "${N_WORKER}"
mkdir -p "${N_ROOT}/.company-runtime/sessions/n-smoke"

# 권한 prompt fixture (시그너처 다중 매칭)
N_FIXTURE="${TMP_ROOT}/n-prompt.txt"
cat > "${N_FIXTURE}" <<'EOF'
$ ls config/

Do you want to make this edit to config.json?
1. Yes
2. No

❯ 1
EOF

# 무 prompt fixture
N_CLEAR_FIXTURE="${TMP_ROOT}/n-clear.txt"
printf '$ ls\nresult.md\n' > "${N_CLEAR_FIXTURE}"

# preflight 작성 + cmux-target 등록
cat > "${N_ROOT}/.company-runtime/sessions/n-smoke/preflight.json" <<'EOF'
{"version":3,"runner":"cmux","runner_source":"auto","state":"experimental","experimental_grant":"inside-context"}
EOF
echo "surface:fake-1" > "${N_WORKER}/cmux-target"

# (n.1) 첫 호출 — detected, 아직 emit 안 됨
N1_OUT="$(
  env PATH="${FAKE_CMUX_DIR}:$PATH" CMUX_PANEL_ID=fake CMUX_WORKSPACE_ID=fake \
      CMUX_FAKE_CAPTURE_FILE="${N_FIXTURE}" \
    bash "${KIT_DIR}/scripts/permission-stall-watchdog.sh" n-smoke "${N_ROOT}" 60
)"
check "(n.1) 시그너처 매칭 + threshold 미초과 → first_seen 기록만" \
  test -f "${N_WORKER}/.permission-stall.first_seen"
check "(n.1) detected=1, emitted=0" \
  bash -c "printf '%s\n' \"\$1\" | grep -q 'detected=1 emitted=0'" -- "${N1_OUT}"

# (n.2) threshold=0 → emit 발생
sleep 1
N2_OUT="$(
  env PATH="${FAKE_CMUX_DIR}:$PATH" CMUX_PANEL_ID=fake CMUX_WORKSPACE_ID=fake \
      CMUX_FAKE_CAPTURE_FILE="${N_FIXTURE}" \
    bash "${KIT_DIR}/scripts/permission-stall-watchdog.sh" n-smoke "${N_ROOT}" 0
)"
check "(n.2) emit 발생 → emitted=1" \
  bash -c "printf '%s\n' \"\$1\" | grep -q 'emitted=1'" -- "${N2_OUT}"
check "(n.2) worker_blocked_on_permission 이벤트 events.jsonl 기록" \
  bash -c "grep -q 'worker_blocked_on_permission' \"\$1\"" -- "${N_ROOT}/.company-runtime/harness/events.jsonl"
check "(n.2) idempotency_key 가 first_seen ts 와 묶임" \
  bash -c "
    fs=\$(cat \"\$1\")
    grep -q \"permission_stall:\${fs}\" \"\$2\"
  " -- "${N_WORKER}/.permission-stall.first_seen" "${N_ROOT}/.company-runtime/harness/events.jsonl"

# (n.3) 동일 first_seen 재호출 → dedupe
N3_LINES_BEFORE=$(wc -l < "${N_ROOT}/.company-runtime/harness/events.jsonl" | tr -d ' ')
env PATH="${FAKE_CMUX_DIR}:$PATH" CMUX_PANEL_ID=fake CMUX_WORKSPACE_ID=fake \
    CMUX_FAKE_CAPTURE_FILE="${N_FIXTURE}" \
  bash "${KIT_DIR}/scripts/permission-stall-watchdog.sh" n-smoke "${N_ROOT}" 0 >/dev/null
N3_LINES_AFTER=$(wc -l < "${N_ROOT}/.company-runtime/harness/events.jsonl" | tr -d ' ')
check "(n.3) 동일 first_seen 재호출 → dedupe (events 줄 수 변화 없음)" \
  test "${N3_LINES_BEFORE}" = "${N3_LINES_AFTER}"

# (n.4) prompt 사라짐 → 마커 클리어
env PATH="${FAKE_CMUX_DIR}:$PATH" CMUX_PANEL_ID=fake CMUX_WORKSPACE_ID=fake \
    CMUX_FAKE_CAPTURE_FILE="${N_CLEAR_FIXTURE}" \
  bash "${KIT_DIR}/scripts/permission-stall-watchdog.sh" n-smoke "${N_ROOT}" 0 >/dev/null
check "(n.4) prompt 사라짐 → first_seen 마커 클리어" \
  bash -c "[[ ! -f \"\$1\" ]]" -- "${N_WORKER}/.permission-stall.first_seen"
check "(n.4) prompt 사라짐 → emitted 마커 클리어" \
  bash -c "[[ ! -f \"\$1\" ]]" -- "${N_WORKER}/.permission-stall.emitted"

# ── 요약 ────────────────────────────────────────────────────────────────────
echo
echo "─────────────────────────"
echo "Smoke Runner: ${PASS} PASS / ${FAIL} FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
