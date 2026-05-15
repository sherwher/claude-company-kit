#!/usr/bin/env bash

# cmux-lib.sh
#
# Single compatibility layer for cmux CLI calls used by company-kit.
# Keep all surface/panel id normalization and Enter-key behavior here so
# leader scripts do not each learn a different cmux dialect.

cmux_target_kind() {
  local target="$1"
  case "${target}" in
    surface:*) printf 'surface\n' ;;
    panel:*)   printf 'panel\n' ;;
    *)
      echo "cmux target must start with surface: or panel: (got: ${target})" >&2
      return 2
      ;;
  esac
}

cmux_target_id() {
  local target="$1"
  case "${target}" in
    surface:*) printf '%s\n' "${target#surface:}" ;;
    panel:*)   printf '%s\n' "${target#panel:}" ;;
    *)
      echo "cmux target must start with surface: or panel: (got: ${target})" >&2
      return 2
      ;;
  esac
}

cmux_send_text() {
  local target="$1"
  local text="${2:-}"
  local kind id
  kind="$(cmux_target_kind "${target}")" || return $?
  id="$(cmux_target_id "${target}")" || return $?

  case "${kind}" in
    surface)
      cmux send --surface "${target}" -- "${text}" 2>/dev/null \
        || cmux send --surface "${id}" -- "${text}"
      ;;
    panel)
      cmux send-panel --panel "${target}" -- "${text}" 2>/dev/null \
        || cmux send-panel --panel "${id}" -- "${text}"
      ;;
  esac
}

cmux_send_enter() {
  local target="$1"
  local kind id
  kind="$(cmux_target_kind "${target}")" || return $?
  id="$(cmux_target_id "${target}")" || return $?

  case "${kind}" in
    surface)
      cmux send-key --surface "${target}" enter 2>/dev/null \
        || cmux send-key --surface "${id}" enter 2>/dev/null \
        || cmux send-key --surface "${target}" Enter 2>/dev/null \
        || cmux send-key --surface "${id}" Enter
      ;;
    panel)
      cmux send-key-panel --panel "${target}" enter 2>/dev/null \
        || cmux send-key-panel --panel "${id}" enter 2>/dev/null \
        || cmux send-key-panel --panel "${target}" Enter 2>/dev/null \
        || cmux send-key-panel --panel "${id}" Enter
      ;;
  esac
}

cmux_submit_text() {
  local target="$1"
  local text="${2:-}"
  [[ -n "${text}" ]] || return 0
  cmux_send_text "${target}" "${text}"
  cmux_send_enter "${target}"
}

cmux_new_split_surface() {
  local direction="${1:-right}"
  case "${direction}" in
    right|left|up|down) ;;
    *) echo "cmux_new_split_surface: invalid direction: ${direction}" >&2; return 2 ;;
  esac

  local out surface
  out="$(cmux new-split "${direction}" 2>&1)" || {
    printf '%s\n' "${out}" >&2
    return 1
  }
  surface="$(printf '%s\n' "${out}" | grep -Eo 'surface:[A-Za-z0-9._:-]+' | head -n1 || true)"
  if [[ -z "${surface}" ]]; then
    echo "cmux_new_split_surface: could not parse surface id from cmux output:" >&2
    printf '%s\n' "${out}" >&2
    return 3
  fi
  printf '%s\n' "${surface}"
}
