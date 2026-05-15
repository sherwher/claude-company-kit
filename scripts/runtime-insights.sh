#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./git-worktree-lib.sh
source "${SCRIPT_DIR}/git-worktree-lib.sh"

PROJECT_ROOT="$(resolve_shared_project_root "${ROOT}")"
HISTORY_FILE="${PROJECT_ROOT}/.company-runtime/pattern-memory/session-history.tsv"
TELEMETRY_FILE="${PROJECT_ROOT}/.company-runtime/telemetry/spawn-telemetry.tsv"
ROUTING_FEEDBACK_FILE="${PROJECT_ROOT}/.company-project/routing-feedback.md"
EVENTS_FILE="${PROJECT_ROOT}/.company-runtime/harness/events.jsonl"

echo "# Runtime Insights"
echo

# v1.3.7: 상단 Runtime Summary — 사용자가 한눈에 러너 상태를 보도록 2줄 요약.
# 가장 최근(마지막) preflight.json 을 우선 사용하고, 없으면 events.jsonl 의
# 마지막 runner_selected 이벤트를 fallback 으로 읽는다.
_LATEST_PREFLIGHT=""
if [[ -d "${PROJECT_ROOT}/.company-runtime/sessions" ]]; then
  _LATEST_PREFLIGHT="$(find "${PROJECT_ROOT}/.company-runtime/sessions" -maxdepth 2 -name preflight.json 2>/dev/null \
    | xargs -I{} stat -f '%m %N' {} 2>/dev/null \
    | sort -nr | head -n1 | cut -d' ' -f2-)"
fi
_RUNTIME_RUNNER="(unknown)"
_RUNTIME_SOURCE=""
_RUNTIME_REASON=""
_RUNTIME_PARALLEL="unknown"
_RUNTIME_STATE=""
_RUNTIME_ALLOW_EXP=""
if [[ -n "${_LATEST_PREFLIGHT}" && -f "${_LATEST_PREFLIGHT}" ]] && command -v jq >/dev/null 2>&1; then
  _RUNTIME_RUNNER="$(jq -r '.runner // "unknown"' "${_LATEST_PREFLIGHT}" 2>/dev/null)"
  _RUNTIME_SOURCE="$(jq -r '.runner_source // empty' "${_LATEST_PREFLIGHT}" 2>/dev/null)"
  _RUNTIME_REASON="$(jq -r '.fallback_reason // empty' "${_LATEST_PREFLIGHT}" 2>/dev/null)"
  _RUNTIME_PARALLEL="$(jq -r 'if .parallel_available then "Available" else "N/A" end' "${_LATEST_PREFLIGHT}" 2>/dev/null)"
  _RUNTIME_STATE="$(jq -r '.state // empty' "${_LATEST_PREFLIGHT}" 2>/dev/null)"
  _RUNTIME_ALLOW_EXP="$(jq -r 'if .allow_experimental == true then "on" else "off" end' "${_LATEST_PREFLIGHT}" 2>/dev/null)"
elif [[ -f "${EVENTS_FILE}" ]] && command -v jq >/dev/null 2>&1; then
  _last="$(grep '"event":"runner_selected"' "${EVENTS_FILE}" 2>/dev/null | tail -n1)"
  if [[ -n "${_last}" ]]; then
    _RUNTIME_RUNNER="$(printf '%s' "${_last}" | jq -r '.runner // "unknown"' 2>/dev/null)"
    _RUNTIME_SOURCE="$(printf '%s' "${_last}" | jq -r '.runner_source // empty' 2>/dev/null)"
    _RUNTIME_REASON="$(printf '%s' "${_last}" | jq -r '.fallback_reason // empty' 2>/dev/null)"
    _RUNTIME_PARALLEL="$(printf '%s' "${_last}" | jq -r 'if .parallel_available == "true" then "Available" else "N/A" end' 2>/dev/null)"
    _RUNTIME_STATE="$(printf '%s' "${_last}" | jq -r '.state // empty' 2>/dev/null)"
    _RUNTIME_ALLOW_EXP="$(printf '%s' "${_last}" | jq -r 'if .allow_experimental == "1" then "on" else "off" end' 2>/dev/null)"
  fi
fi

# v1.3.8: state 에 따라 아이콘 prefix 를 붙여 사용자가 한눈에 신뢰도 파악.
_STATE_ICON=""
case "${_RUNTIME_STATE}" in
  stable)       _STATE_ICON="✔" ;;
  experimental) _STATE_ICON="⚠" ;;
  slot)         _STATE_ICON="◌" ;;
  *)            _STATE_ICON="·" ;;
esac

echo "## Runtime Summary"
echo "- [Runner] ${_STATE_ICON} ${_RUNTIME_RUNNER}${_RUNTIME_SOURCE:+ (source=${_RUNTIME_SOURCE})}  |  Parallel: ${_RUNTIME_PARALLEL}"
if [[ -n "${_RUNTIME_STATE}" ]]; then
  _state_line="[State] ${_RUNTIME_STATE}"
  [[ -n "${_RUNTIME_ALLOW_EXP}" ]] && _state_line="${_state_line}  |  allow_experimental=${_RUNTIME_ALLOW_EXP}"
  echo "- ${_state_line}"
fi
if [[ -n "${_RUNTIME_REASON}" && "${_RUNTIME_REASON}" != "null" ]]; then
  echo "- [Detail] Fallback Reason: ${_RUNTIME_REASON}"
else
  echo "- [Detail] Fallback Reason: N/A"
fi
echo

# v1.1.0 (C4): Harness Events 섹션 — events.jsonl을 on-demand 계산.
# 상태 머신 파일 없음. 필요할 때만 jsonl을 한 번 읽는다.
echo "## Harness Events"
if [[ -f "${EVENTS_FILE}" ]]; then
  total_events=$(wc -l < "${EVENTS_FILE}" | tr -d ' ')
  # grep -c는 매치 0건일 때 exit 1을 반환하므로 || 로 0을 강제. echo 누적 회피.
  prepared_count=$(grep -c '"event":"session_prepared"' "${EVENTS_FILE}" 2>/dev/null) || prepared_count=0
  spawn_count=$(grep -c '"event":"spawn_attempt"' "${EVENTS_FILE}" 2>/dev/null) || spawn_count=0
  # v1.3.7 canonical events
  spawn_prepared_count=$(grep -c '"event":"spawn_prepared"' "${EVENTS_FILE}" 2>/dev/null) || spawn_prepared_count=0
  spawn_started_count=$(grep -c '"event":"spawn_started"' "${EVENTS_FILE}" 2>/dev/null) || spawn_started_count=0
  spawn_ready_count=$(grep -c '"event":"spawn_ready"' "${EVENTS_FILE}" 2>/dev/null) || spawn_ready_count=0
  output_ready_count=$(grep -c '"event":"worker_output_ready"' "${EVENTS_FILE}" 2>/dev/null) || output_ready_count=0
  approved_count=$(grep -c '"event":"approved"' "${EVENTS_FILE}" 2>/dev/null) || approved_count=0
  closed_ok=$(grep -c '"event":"session_closed".*"result":"ok"' "${EVENTS_FILE}" 2>/dev/null) || closed_ok=0
  closed_fail=$(grep -c '"event":"session_closed".*"result":"fail"' "${EVENTS_FILE}" 2>/dev/null) || closed_fail=0
  echo "- 총 이벤트: ${total_events}"
  echo "- session_prepared: ${prepared_count}"
  echo "- spawn_attempt (legacy): ${spawn_count}"
  echo "- spawn_prepared: ${spawn_prepared_count}"
  echo "- spawn_started: ${spawn_started_count}"
  echo "- spawn_ready: ${spawn_ready_count}"
  echo "- worker_output_ready: ${output_ready_count}"
  echo "- approved: ${approved_count}"
  echo "- session_closed (ok): ${closed_ok}"
  echo "- session_closed (fail): ${closed_fail}"
  echo
  echo "## 최근 이벤트 (마지막 10건)"
  if command -v jq >/dev/null 2>&1; then
    tail -n 10 "${EVENTS_FILE}" | jq -r '"- \(.ts) | \(.event) | \(.session_id)\(if .worker then " | " + .worker else "" end)"' 2>/dev/null || tail -n 10 "${EVENTS_FILE}"
  else
    tail -n 10 "${EVENTS_FILE}"
  fi
  echo

  # 막힌 세션 감지: spawn_attempt는 있는데 approved도 session_closed도 없는 세션
  echo "## 막힌 세션"
  stuck_sessions=$(awk '
    /"event":"spawn_attempt"/ { match($0, /"session_id":"[^"]*"/); sid=substr($0, RSTART+14, RLENGTH-15); spawn[sid]=1; ts[sid]=$0 }
    /"event":"approved"/ { match($0, /"session_id":"[^"]*"/); sid=substr($0, RSTART+14, RLENGTH-15); approved[sid]=1 }
    /"event":"session_closed"/ { match($0, /"session_id":"[^"]*"/); sid=substr($0, RSTART+14, RLENGTH-15); closed[sid]=1 }
    END { for (s in spawn) if (!approved[s] && !closed[s]) print s }
  ' "${EVENTS_FILE}")
  if [[ -n "${stuck_sessions}" ]]; then
    while IFS= read -r sid; do
      echo "- ⚠️  ${sid} — spawn 후 approved/closed 이벤트 없음 (워커 pane 또는 compact-plan 확인 필요)"
    done <<< "${stuck_sessions}"
  else
    echo "- 막힌 세션 없음"
  fi
  echo

  # v1.4.4: 권한 prompt 에 막혀 있는 워커 (worker_blocked_on_permission emit 후
  # 같은 세션에 후속 worker_output_ready 또는 session_closed 가 없으면 여전히 막힘)
  echo "## 권한으로 막힌 워커"
  blocked_lines=$(awk '
    /"event":"worker_blocked_on_permission"/ {
      match($0, /"session_id":"[^"]*"/); sid=substr($0, RSTART+14, RLENGTH-15)
      match($0, /"worker":"[^"]*"/); w=(RSTART>0 ? substr($0, RSTART+10, RLENGTH-11) : "?")
      match($0, /"first_seen_ts":"[^"]*"/); fs=(RSTART>0 ? substr($0, RSTART+17, RLENGTH-18) : "?")
      key=sid"|"w
      blocked[key]=1; first[key]=fs
    }
    /"event":"worker_output_ready"/ {
      match($0, /"session_id":"[^"]*"/); sid=substr($0, RSTART+14, RLENGTH-15)
      match($0, /"worker":"[^"]*"/); w=(RSTART>0 ? substr($0, RSTART+10, RLENGTH-11) : "?")
      key=sid"|"w
      delete blocked[key]
    }
    /"event":"session_closed"/ {
      match($0, /"session_id":"[^"]*"/); sid=substr($0, RSTART+14, RLENGTH-15)
      for (k in blocked) {
        split(k, parts, "|")
        if (parts[1] == sid) delete blocked[k]
      }
    }
    END {
      for (k in blocked) {
        split(k, parts, "|")
        printf "- ⛔ %s | worker=%s | first_seen=%s\n", parts[1], parts[2], first[k]
      }
    }
  ' "${EVENTS_FILE}")
  if [[ -n "${blocked_lines}" ]]; then
    printf '%s\n' "${blocked_lines}"
    echo "  → 워커 panel 에서 권한 prompt 응답 후 동일 세션을 다시 진행하세요."
  else
    echo "- 권한 stall 신호 없음"
  fi
  echo

  # v1.5.6: cmux leader-watcher 가 emit 한 권한 게이트 대기 — 워커 pane 안에서
  # 'Do you want to proceed?' 같은 권한 prompt 가 떠 있는 상태. 사용자가 cmux GUI
  # 로 직접 응답하기 전까지 워커는 멈춰 있다.
  echo "## 권한 게이트 대기 (cmux leader-watcher)"
  gate_lines=$(awk '
    /"event":"permission_gate_pending"/ {
      ts=""; sid=""; w=""; ex=""
      match($0, /"ts":"[^"]*"/);            if (RSTART>0) ts=substr($0, RSTART+6, RLENGTH-7)
      match($0, /"session_id":"[^"]*"/);    if (RSTART>0) sid=substr($0, RSTART+14, RLENGTH-15)
      match($0, /"worker":"[^"]*"/);        if (RSTART>0) w=substr($0, RSTART+10, RLENGTH-11)
      match($0, /"gate_excerpt":"[^"]*"/);  if (RSTART>0) ex=substr($0, RSTART+16, RLENGTH-17)
      key=sid"|"w
      pending[key]=ts"|"ex
    }
    /"event":"approved"/ {
      match($0, /"session_id":"[^"]*"/); if (RSTART>0) sid=substr($0, RSTART+14, RLENGTH-15)
      match($0, /"worker":"[^"]*"/);     if (RSTART>0) w=substr($0, RSTART+10, RLENGTH-11)
      delete pending[sid"|"w]
    }
    /"event":"session_closed"/ {
      match($0, /"session_id":"[^"]*"/); if (RSTART>0) sid=substr($0, RSTART+14, RLENGTH-15)
      for (k in pending) { split(k, p, "|"); if (p[1] == sid) delete pending[k] }
    }
    END {
      for (k in pending) {
        split(k, p, "|"); split(pending[k], v, "|")
        printf "- 🔔 session=%s | worker=%s | first_seen=%s | gate=%s\n", p[1], p[2], v[1], v[2]
      }
    }
  ' "${EVENTS_FILE}")
  if [[ -n "${gate_lines}" ]]; then
    printf '%s\n' "${gate_lines}"
    echo "  → cmux GUI 의 워커 pane 에서 직접 1/2 응답하거나, 'company approve <session>' 으로 진행하세요."
  else
    echo "- 권한 게이트 대기 없음"
  fi
  echo

  # v1.4.5: 리더 깨움 대기 — leader_wake_ready emit 됐는데 같은 idempotency_key 의
  # leader_wake_consumed 가 없으면 메인이 아직 모르는 상태.
  echo "## 리더 깨움 대기 (워커→리더 wake)"
  wake_lines=$(awk '
    /"event":"leader_wake_ready"/ {
      ts=""; sid=""; src=""; sid_id=""; art=""; key=""
      match($0, /"ts":"[^"]*"/);              if (RSTART>0) ts=substr($0, RSTART+6, RLENGTH-7)
      match($0, /"session_id":"[^"]*"/);      if (RSTART>0) sid=substr($0, RSTART+14, RLENGTH-15)
      match($0, /"source_type":"[^"]*"/);     if (RSTART>0) src=substr($0, RSTART+15, RLENGTH-16)
      match($0, /"source_id":"[^"]*"/);       if (RSTART>0) sid_id=substr($0, RSTART+13, RLENGTH-14)
      match($0, /"artifact":"[^"]*"/);        if (RSTART>0) art=substr($0, RSTART+12, RLENGTH-13)
      match($0, /"idempotency_key":"[^"]*"/); if (RSTART>0) key=substr($0, RSTART+18, RLENGTH-19)
      if (key != "") { ready[key]=ts"|"src"|"sid_id"|"art"|"sid }
    }
    /"event":"leader_wake_consumed"/ {
      match($0, /"idempotency_key":"[^"]*"/)
      if (RSTART>0) {
        k=substr($0, RSTART+18, RLENGTH-19)
        delete ready[k]
      }
    }
    END {
      for (k in ready) {
        n=split(ready[k], f, "|")
        printf "- ⏰ %-20s | %-6s | %-15s | %s | %s\n", f[3], f[2], f[4], f[1], f[5]
      }
    }
  ' "${EVENTS_FILE}")
  if [[ -n "${wake_lines}" ]]; then
    echo "  WORKER/INBOX         | SOURCE | ARTIFACT        | EMITTED_AT | SESSION"
    printf '%s\n' "${wake_lines}"
    echo "  → bash scripts/hooks/claude-userpromptsubmit-leader-wake.sh 가 .claude/settings.json 에 UserPromptSubmit 으로 등록돼 있는지 확인하세요."
  else
    echo "- 리더 깨움 대기 없음 (모든 wake 가 hook 으로 소비됐거나 새 wake 미발생)"
  fi
  echo

  # 리더 직접 작성 위반 신호: spawn_attempt는 0인데 git working tree에 변경이 있음
  if [[ "${spawn_count}" -eq 0 && "${total_events}" -gt 0 ]]; then
    echo "## ⚠️  리더 직접 작성 위반 신호"
    echo "- 이벤트가 ${total_events}건 기록됐지만 spawn_attempt가 0건입니다."
    echo "- 리더가 워커 위임 없이 직접 작업했을 가능성이 있습니다 (rule 위반)."
    echo
  fi
else
  echo "- events.jsonl 없음 (아직 세션이 실행되지 않았거나 jq 미설치)"
  echo
fi

if [[ -f "${HISTORY_FILE}" ]]; then
  echo "## Recent Sessions"
  awk -F'\t' '
    { print "- " $2 " | mode=" $3 " | workers=" $4 " | topic=" $5 " | feedback=" $6 }
  ' "${HISTORY_FILE}" | tail -n 5
  echo

  echo "## Cost Mode Distribution"
  awk -F'\t' '
    {
      if ($3 == "cheap") cheap++
      else if ($3 == "balanced") balanced++
      else if ($3 == "deep") deep++
    }
    END {
      printf "- cheap: %d\n", cheap + 0
      printf "- balanced: %d\n", balanced + 0
      printf "- deep: %d\n", deep + 0
    }
  ' "${HISTORY_FILE}"
  echo

  echo "## Session Feedback Counts"
  awk -F'\t' '
    {
      if ($6 ~ /feedback=`good`/) good++
      else if ($6 ~ /feedback=`overkill`/) overkill++
      else if ($6 ~ /feedback=`insufficient`/) insufficient++
      else if ($6 ~ /feedback=`wrong-worker`/) wrong++
    }
    END {
      printf "- good: %d\n", good + 0
      printf "- overkill: %d\n", overkill + 0
      printf "- insufficient: %d\n", insufficient + 0
      printf "- wrong-worker: %d\n", wrong + 0
    }
  ' "${HISTORY_FILE}"
  echo
else
  echo "## Recent Sessions"
  echo "- no session history"
  echo
fi

if [[ -f "${ROUTING_FEEDBACK_FILE}" ]]; then
  echo "## Worker Feedback Snapshot"
  awk '
    /^- / {
      worker=""
      feedback=""
      if (match($0, /primary=`[^`]+`/)) {
        worker = substr($0, RSTART + 9, RLENGTH - 10)
      }
      if (match($0, /feedback=`[^`]+`/)) {
        feedback = substr($0, RSTART + 10, RLENGTH - 11)
      }
      if (worker != "" && feedback != "") {
        total[worker]++
        if (feedback == "good") good[worker]++
        else if (feedback == "overkill") overkill[worker]++
        else if (feedback == "insufficient") insufficient[worker]++
        else if (feedback == "wrong-worker") wrong[worker]++
      }
    }
    END {
      shown = 0
      for (worker in total) {
        printf "- %s | total=%d | good=%d | overkill=%d | insufficient=%d | wrong=%d\n",
          worker, total[worker], good[worker] + 0, overkill[worker] + 0, insufficient[worker] + 0, wrong[worker] + 0
        shown++
      }
      if (shown == 0) print "- no worker feedback yet"
    }
  ' "${ROUTING_FEEDBACK_FILE}" | sort
  echo

  echo "## Worker Recommendation Accuracy"
  awk '
    /^- / {
      worker=""
      feedback=""
      if (match($0, /primary=`[^`]+`/)) {
        worker = substr($0, RSTART + 9, RLENGTH - 10)
      }
      if (match($0, /feedback=`[^`]+`/)) {
        feedback = substr($0, RSTART + 10, RLENGTH - 11)
      }
      if (worker != "" && feedback != "") {
        total[worker]++
        if (feedback == "good") good[worker]++
      }
    }
    END {
      shown = 0
      for (worker in total) {
        rate = 0
        if (total[worker] > 0) {
          rate = int((good[worker] + 0) * 100 / total[worker])
        }
        printf "- %s | hit_rate=%d%% | good=%d/%d\n",
          worker, rate, good[worker] + 0, total[worker]
        shown++
      }
      if (shown == 0) print "- no accuracy data yet"
    }
  ' "${ROUTING_FEEDBACK_FILE}" | sort -t'=' -k2,2nr
  echo
else
  echo "## Worker Feedback Snapshot"
  echo "- no routing feedback"
  echo
  echo "## Worker Recommendation Accuracy"
  echo "- no accuracy data yet"
  echo
fi

if [[ -f "${TELEMETRY_FILE}" ]]; then
  echo "## Spawn Telemetry"
  awk -F'\t' '
    {
      if ($7 == "success") success++
      else if ($7 == "failure") {
        failure++
        reasons[$8]++
      }
    }
    END {
      printf "- success: %d\n", success + 0
      printf "- failure: %d\n", failure + 0
      for (reason in reasons) {
        printf "- failure_reason[%s]: %d\n", reason, reasons[reason]
      }
    }
  ' "${TELEMETRY_FILE}"
  echo

  echo "## Recent Spawn Failures"
  recent_failures="$(awk -F'\t' '$7 == "failure" { print "- " $2 " | worker=" $3 " | session=" $4 " | window=" $5 " | pane_count=" $6 " | reason=" $8 }' "${TELEMETRY_FILE}" | tail -n 5)"
  if [[ -n "${recent_failures}" ]]; then
    printf '%s\n' "${recent_failures}"
  else
    echo "- no recent failures"
  fi
  echo
else
  echo "## Spawn Telemetry"
  echo "- no telemetry"
  echo
fi

# v1.4 Phase 2: Subagent 누수 표면화
# compact-plan/result 안에 Agent/Task/EnterPlanMode 호출 흔적이 있는 세션 카운트.
# sentinel-scan.sh 가 같은 패턴을 detect 하지만 여기는 cross-session 누적 보고.
echo "## Subagent Leak Signals"
SUBAGENT_PATTERN='Agent\(|Task\(|oh-my-claudecode:|EnterPlanMode|ExitPlanMode'
_leak_sessions=0
_leak_files=0
if [[ -d "${PROJECT_ROOT}/.company-runtime/sessions" ]]; then
  while IFS= read -r -d '' f; do
    if grep -q -E "${SUBAGENT_PATTERN}" "${f}" 2>/dev/null; then
      _leak_files=$((_leak_files + 1))
    fi
  done < <(find "${PROJECT_ROOT}/.company-runtime/sessions" -type f \( -name "compact-plan.*" -o -name "compact-result.*" \) -print0 2>/dev/null)
  _leak_sessions=$(find "${PROJECT_ROOT}/.company-runtime/sessions" -type f \( -name "compact-plan.*" -o -name "compact-result.*" \) -exec grep -l -E "${SUBAGENT_PATTERN}" {} + 2>/dev/null | awk -F'/sessions/' '{print $2}' | awk -F'/' '{print $1}' | sort -u | wc -l | tr -d ' ')
fi
if [[ "${_leak_files:-0}" -gt 0 ]]; then
  echo "- ⚠️  세션 ${_leak_sessions}개 / 파일 ${_leak_files}건에서 Agent/Task/EnterPlanMode 흔적 발견 — Sonnet 비용 제한 우회 가능성"
  echo "- bash .company-kit/scripts/sentinel-scan.sh <session_id> 로 세부 위치 확인"
else
  echo "- subagent 누수 흔적 없음"
fi
echo

echo "## Suggested Actions"
if [[ -f "${HISTORY_FILE}" ]] && grep -q 'feedback=`insufficient`' "${HISTORY_FILE}"; then
  echo "- 비슷한 주제에서 worker 수 또는 cost mode를 올릴지 검토하세요."
fi
if [[ -f "${HISTORY_FILE}" ]] && grep -q 'feedback=`overkill`' "${HISTORY_FILE}"; then
  echo "- 작은 주제에서는 cheap 또는 fewer workers를 우선 검토하세요."
fi
if [[ -f "${TELEMETRY_FILE}" ]] && grep -q $'\tfailure\tno-pane-added$' "${TELEMETRY_FILE}"; then
  echo "- tmux teammate pane 생성이 자주 실패하므로 spawn 경로를 다시 점검하세요."
fi
if [[ -f "${ROUTING_FEEDBACK_FILE}" ]] && grep -q 'feedback=`wrong-worker`' "${ROUTING_FEEDBACK_FILE}"; then
  echo "- wrong-worker 피드백이 있었던 topic은 route-topic으로 다시 worker 조합을 확인하세요."
fi
if [[ -f "${ROUTING_FEEDBACK_FILE}" ]] && awk '/^-/ && /primary=`/ && /feedback=`/ { if ($0 ~ /feedback=`good`/) good++; total++ } END { exit !(total > 0 && (good * 100 / total) < 60) }' "${ROUTING_FEEDBACK_FILE}"; then
  echo "- worker 추천 적중률이 낮습니다. 유사 topic 기준으로 routing-feedback를 더 자주 남기세요."
fi
if [[ ! -f "${HISTORY_FILE}" && ! -f "${TELEMETRY_FILE}" ]]; then
  echo "- 아직 runtime 데이터가 없습니다. session을 1개 이상 실행한 뒤 다시 확인하세요."
fi
