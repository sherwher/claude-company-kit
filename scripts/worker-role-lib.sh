#!/usr/bin/env bash
set -euo pipefail

find_worker_role_brief() {
  local config_path="$1"
  local worker_name="$2"

  while IFS=$'\t' read -r worker_key display_name internal_agents mission outputs questions; do
    [[ -n "${worker_key}" ]] || continue
    if [[ "${worker_key}" == "${worker_name}" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${worker_key}" "${display_name}" "${internal_agents}" "${mission}" "${outputs}" "${questions}"
      return 0
    fi
  done < "${config_path}"

  return 1
}

# validate_worker_brief_line <line>
# 탭 개수가 5개(필드 6개) 미만이면 return 1
validate_worker_brief_line() {
  local line="$1"
  local tab_count
  tab_count="$(printf '%s' "${line}" | tr -cd '\t' | wc -c | tr -d ' ')"
  [[ "${tab_count}" -ge 5 ]]
}

# get_worker_brief_field <briefs-file> <worker-name> <field-index>
# field-index: 1=name 2=display_name 3=internal_agents 4=mission 5=outputs 6=questions
get_worker_brief_field() {
  local briefs_file="$1"
  local worker="$2"
  local field_index="$3"
  local line
  line="$(find_worker_role_brief "${briefs_file}" "${worker}")" || return 1
  [[ -z "${line}" ]] && return 1
  printf '%s' "${line}" | awk -F'\t' -v idx="${field_index}" '{print $idx}'
}

# ── R21: MCP sidecar loader 함수 ──
# sidecar 스키마: worker_id\tsection\ttool\tpayload
# prefetch 행은 5필드: worker_id\tprefetch\ttool\tquery\twhy

# get_worker_mcp_meta <sidecar-file> <worker-name>
# → minimum_call 값 출력 (없으면 빈 문자열)
get_worker_mcp_meta() {
  local sidecar="$1"
  local worker="$2"
  awk -F'\t' -v w="${worker}" '
    $1 == w && $2 == "meta" { gsub(/^minimum_call=/, "", $4); print $4; exit }
  ' "${sidecar}"
}

# get_worker_mcp_preferred <sidecar-file> <worker-name>
# → "tool\trationale\n" 형식으로 출력
get_worker_mcp_preferred() {
  local sidecar="$1"
  local worker="$2"
  awk -F'\t' -v w="${worker}" '
    $1 == w && $2 == "preferred" { printf "%s\t%s\n", $3, $4 }
  ' "${sidecar}"
}

# get_worker_mcp_prefetch <sidecar-file> <worker-name>
# → "tool\tquery\twhy\n" 형식으로 출력
get_worker_mcp_prefetch() {
  local sidecar="$1"
  local worker="$2"
  awk -F'\t' -v w="${worker}" '
    $1 == w && $2 == "prefetch" { printf "%s\t%s\t%s\n", $3, $4, $5 }
  ' "${sidecar}"
}

# get_worker_mcp_deferred <sidecar-file> <worker-name>
# → "tool\treason\tfallback\n" 형식으로 출력 (payload = reason||fallback)
get_worker_mcp_deferred() {
  local sidecar="$1"
  local worker="$2"
  awk -F'\t' -v w="${worker}" '
    $1 == w && $2 == "deferred" {
      payload = $4
      split(payload, parts, "||")
      reason = parts[1]
      fallback = parts[2]
      gsub(/^ +| +$/, "", reason)
      gsub(/^ +| +$/, "", fallback)
      printf "%s\t%s\t%s\n", $3, reason, fallback
    }
  ' "${sidecar}"
}
