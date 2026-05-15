#!/usr/bin/env bash

strip_comment_and_trim() {
  local line="$1"
  line="${line%%#*}"
  line="$(printf '%s' "${line}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s\n' "${line}"
}

read_nonempty_lines() {
  local file_path="$1"
  [[ -f "${file_path}" ]] || return 0

  while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    local line
    line="$(strip_comment_and_trim "${raw_line}")"
    [[ -n "${line}" ]] && printf '%s\n' "${line}"
  done < "${file_path}"
}
