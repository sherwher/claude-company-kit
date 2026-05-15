#!/usr/bin/env bash
# scripts/worker-definition-lib.sh
#
# (Phase 1, 2026-05-12) renamed from worker-manifest-lib.sh.
# 본 파일은 worker DEFINITION lookup utility (ROUTING_MATRIX 의 worker alias →
# canonical worker name). 워커 INSTANCE 상태 SSOT 는 별도 파일
# scripts/worker-registry-lib.sh 가 다룬다.
#
# 분리 근거: docs/decisions/2026-05-12-worker-registry-ssot.md v0.3 D1
# (Phase 0 accepted), docs/decisions/2026-05-12-worker-registry-phase1.md v0.3 D1
# (Phase 1 accepted).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./manifest-lib.sh
source "${SCRIPT_DIR}/manifest-lib.sh"
# shellcheck source=./skill-pack-lib.sh
source "${SCRIPT_DIR}/skill-pack-lib.sh"

find_worker_definition() {
  local config_path="$1"
  local requested_worker="$2"

  while IFS=$'\t' read -r aliases canonical_worker profile_doc starter_template work_hints; do
    [[ -n "${aliases}" && -n "${canonical_worker}" ]] || continue

    while IFS= read -r alias_name; do
      if [[ "${alias_name}" == "${requested_worker}" ]]; then
        printf '%s\t%s\t%s\t%s\n' \
          "${canonical_worker}" \
          "${profile_doc}" \
          "${starter_template}" \
          "${work_hints}"
        return 0
      fi
    done < <(csv_to_lines "${aliases}")
  done < <(read_nonempty_lines "${config_path}")

  return 1
}
