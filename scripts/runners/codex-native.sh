#!/usr/bin/env bash
# scripts/runners/codex-native.sh (v1.3.7 slot)
#
# codex-native runner — Codex native sub-agent 런타임용 어댑터 슬롯.
# 실제 CLI 계약과 세션 라이프사이클을 이 프로젝트에서 직접 검증하기 전까지는
# detect 가 unavailable 을 반환한다.

runner_codex_native_detect() {
  # codex 바이너리 존재 + native-agent 하위 커맨드 지원 여부까지 검증해야 함.
  # 현재는 의도적으로 unavailable.
  return 1
}

runner_codex_native_current_session_name() { printf ''; }

runner_codex_native_spawn_worker() {
  echo "codex-native runner: spawn_worker not implemented (adapter slot)" >&2
  return 64
}
runner_codex_native_send_worker_message() {
  echo "codex-native runner: send_worker_message not implemented (adapter slot)" >&2
  return 64
}
runner_codex_native_check_worker_status() {
  echo "unknown"; return 64
}
runner_codex_native_collect_worker_outputs() {
  echo "codex-native runner: collect_worker_outputs not implemented (adapter slot)" >&2
  return 64
}
runner_codex_native_stop_worker() {
  echo "codex-native runner: stop_worker not implemented (adapter slot)" >&2
  return 64
}

# Phase 5 D4-B: doctor process check.
# return: 2 = INDETERMINATE (codex-native adapter slot — Phase 6 trigger 대기).
runner_codex_native_check_alive() {
  return 2
}
