#!/usr/bin/env bash
# Mid-air Claude Code account switcher.
# Swaps the active Keychain token to the named profile. No claude launch.
#
# Usage:
#   switch.sh <profile>     # e.g. switch.sh work
#   switch.sh --status      # show which profile is currently active
#   switch.sh --list        # list configured profile slots

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

PROFILES=("personal" "work")

require_macos

usage() {
  cat <<EOF
Usage:
  $(basename "$0") <profile>     Switch the active Claude Code account
  $(basename "$0") --status      Show the currently active profile
  $(basename "$0") --list        List configured profile slots
  $(basename "$0") --help        This help

Configured profiles: ${PROFILES[*]}
EOF
}

cmd_status() {
  local active_blob current tier
  active_blob=$(read_slot "$ACTIVE_SLOT") || true
  if [[ -z "${active_blob:-}" ]]; then
    err "No active Claude Code credentials in Keychain."
    return 1
  fi
  current=$(detect_active_profile "${PROFILES[@]}")
  tier=$(token_tier "$active_blob")
  if [[ -z "$current" || "$current" == "unknown" ]]; then
    info "Active: ${C_YLW}unknown${C_RST} (subscription: $tier)"
    info "${C_DIM}The active token doesn't match any saved profile slot.${C_RST}"
  else
    info "Active: ${C_GRN}$current${C_RST} (subscription: $tier)"
  fi
}

cmd_list() {
  local p slot tier blob
  for p in "${PROFILES[@]}"; do
    slot=$(slot_name "$p")
    if blob=$(read_slot "$slot"); then
      tier=$(token_tier "$blob")
      ok "$p  ${C_DIM}($slot, tier=$tier)${C_RST}"
    else
      warn "$p  ${C_DIM}($slot — NOT SAVED, run setup.sh)${C_RST}"
    fi
  done
}

cmd_switch() {
  local target="$1" slot saved active tier

  # Validate target is configured
  local known=0 p
  for p in "${PROFILES[@]}"; do [[ "$p" == "$target" ]] && known=1; done
  if (( ! known )); then
    err "Unknown profile: $target"
    info "Configured: ${PROFILES[*]}"
    return 2
  fi

  slot=$(slot_name "$target")
  if ! saved=$(read_slot "$slot"); then
    err "No saved token for profile '$target' (Keychain slot: $slot)"
    info "Run setup.sh while logged into the $target account to save it."
    return 1
  fi

  # If already active, no-op
  active=$(read_slot "$ACTIVE_SLOT") || true
  if [[ -n "${active:-}" && "$active" == "$saved" ]]; then
    tier=$(token_tier "$saved")
    info "Already active: ${C_GRN}$target${C_RST} (subscription: $tier)"
    return 0
  fi

  write_slot "$ACTIVE_SLOT" "$saved"
  tier=$(token_tier "$saved")
  ok "Switched to ${C_GRN}$target${C_RST} (subscription: $tier)"
  info "${C_DIM}New 'claude' sessions use this account. Running sessions keep the old token until restart.${C_RST}"
}

main() {
  if [[ $# -eq 0 ]]; then usage; exit 1; fi
  case "$1" in
    -h|--help)    usage ;;
    -s|--status)  cmd_status ;;
    -l|--list)    cmd_list ;;
    -*)           err "Unknown flag: $1"; usage; exit 2 ;;
    *)            cmd_switch "$1" ;;
  esac
}

main "$@"
