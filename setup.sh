#!/usr/bin/env bash
# One-time interactive setup for Claude Code account switching.
#
# What this does:
#   1. Saves the currently-active OAuth token to a per-profile Keychain slot.
#   2. Loops you through /logout + /login for any unsaved profiles.
#   3. Installs zshrc aliases:
#        claude-personal / claude-work  - swap token AND launch claude
#        ccs-personal    / ccs-work     - swap token only (mid-air switch)
#        ccs-status / ccs-list          - status helpers
#
# Idempotent: re-run safely, it skips already-saved slots and doesn't duplicate
# zshrc entries.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

PROFILES=("personal" "work")
ZSHRC="${ZSHRC:-$HOME/.zshrc}"
ZSHRC_BEGIN="# >>> claude-switch >>>"
ZSHRC_END="# <<< claude-switch <<<"

require_macos
require_python3

# ----------------------------------------------------------------------------
# Step 1: ensure each profile slot has a saved token.
# ----------------------------------------------------------------------------

save_active_to_profile() {
  local profile="$1" slot
  slot=$(slot_name "$profile")
  local blob
  if ! blob=$(read_slot "$ACTIVE_SLOT"); then
    err "No active Claude Code credentials found in Keychain."
    info "Make sure Claude Code has been launched at least once and you're logged in."
    return 1
  fi
  if [[ -z "$blob" ]]; then
    err "Active token slot is empty."
    return 1
  fi
  write_slot "$slot" "$blob"
  local tier; tier=$(token_tier "$blob")
  ok "Saved current token to '$slot' (subscription: $tier)"

  # Also snapshot the oauthAccount block from ~/.claude.json so the switcher
  # can restore identity (/status banner) along with the token.
  if save_snapshot "$profile" 2>/dev/null; then
    ok "Saved identity snapshot for '$profile' ($(snapshot_summary "$profile"))"
  else
    warn "Could not snapshot oauthAccount from $CLAUDE_JSON for '$profile'."
    info "${C_DIM}The token swap will still work, but /status may show stale identity until the snapshot is captured.${C_RST}"
  fi
}

prompt_yn() {
  local prompt="$1" default="${2:-y}" ans
  local hint="[Y/n]"; [[ "$default" == "n" ]] && hint="[y/N]"
  read -r -p "$prompt $hint " ans
  ans="${ans:-$default}"
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

setup_profiles() {
  step "Saving profile tokens and identity snapshots"
  local p slot need_capture=()

  # Survey what's already saved. A profile is "complete" only when both the
  # Keychain token AND the oauthAccount snapshot are present.
  for p in "${PROFILES[@]}"; do
    slot=$(slot_name "$p")
    local has_token=0 has_snap=0
    slot_exists "$slot" && has_token=1
    snapshot_exists "$p" && has_snap=1

    if (( has_token && has_snap )); then
      local blob; blob=$(read_slot "$slot")
      local tier; tier=$(token_tier "$blob")
      ok "$p already saved ${C_DIM}(tier=$tier, identity=$(snapshot_summary "$p"))${C_RST}"
    else
      need_capture+=("$p")
      if (( has_token && ! has_snap )); then
        info "$p has saved token but no identity snapshot — will capture."
      fi
    fi
  done

  if [[ ${#need_capture[@]} -eq 0 ]]; then
    info "All profiles already have saved tokens and snapshots. Skipping capture."
    return 0
  fi

  # For each missing profile, walk the user through logging into that account
  # and capturing the active token.
  local current_profile=""
  current_profile=$(detect_active_profile "${PROFILES[@]}") || true

  for p in "${need_capture[@]}"; do
    step "Capture: $p"
    if [[ "$current_profile" == "$p" ]]; then
      info "The currently-active account already looks like '$p' based on existing slots — saving it."
    else
      cat <<EOF
The '$p' profile has no saved token yet.

Action required:
  1. Open a new terminal and run:  ${C_CYN}claude${C_RST}
  2. Inside Claude, run:           ${C_CYN}/logout${C_RST}
  3. Then:                         ${C_CYN}/login${C_RST}  and complete the OAuth flow as the **$p** account
  4. Optionally run:               ${C_CYN}/status${C_RST}  to confirm the right account
  5. Exit Claude (${C_CYN}/exit${C_RST} or Ctrl+D)
  6. Return here and press Enter.

EOF
      read -r -p "Press Enter once you've logged in as '$p' and exited Claude... " _
    fi

    # Capture the active token into this profile's slot
    save_active_to_profile "$p"

    # Update what we believe is currently active
    current_profile="$p"
  done

  step "Verification"
  for p in "${PROFILES[@]}"; do
    slot=$(slot_name "$p")
    local token_mark="${C_RED}MISSING${C_RST}"
    local snap_mark="${C_RED}MISSING${C_RST}"
    slot_exists "$slot" && token_mark="${C_GRN}ok${C_RST}"
    snapshot_exists "$p" && snap_mark="${C_GRN}ok${C_RST}"
    info "  $p  token=$token_mark  snapshot=$snap_mark"
  done
}

# ----------------------------------------------------------------------------
# Step 2: install zshrc aliases.
# ----------------------------------------------------------------------------

zshrc_block() {
  cat <<EOF
$ZSHRC_BEGIN
# Managed by claude-switch ($SCRIPT_DIR). Do not edit between markers.
export CLAUDE_SWITCH_DIR="$SCRIPT_DIR"

# Mid-air switch (no claude launch)
alias ccs-personal="\$CLAUDE_SWITCH_DIR/switch.sh personal"
alias ccs-work="\$CLAUDE_SWITCH_DIR/switch.sh work"
alias ccs-status="\$CLAUDE_SWITCH_DIR/switch.sh --status"
alias ccs-list="\$CLAUDE_SWITCH_DIR/switch.sh --list"

# Launch claude as a given profile. Swap token+identity via switch.sh, run
# claude, then sync refreshed token + identity snapshot back to the profile.
_claude_switch() {
  local profile="\$1"; shift
  local slot="Claude Code-\$profile"

  # Use switch.sh to swap Keychain token and restore identity in claude.json
  "\$CLAUDE_SWITCH_DIR/switch.sh" "\$profile" >/dev/null || return 1

  local token_before
  token_before=\$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)

  command claude "\$@"
  local rc=\$?

  # Sync any refreshed token back to the profile slot
  local token_after
  token_after=\$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  if [[ -n "\$token_after" && "\$token_after" != "\$token_before" ]]; then
    security delete-generic-password -s "\$slot" >/dev/null 2>&1
    security add-generic-password -s "\$slot" -a "\$USER" -w "\$token_after"
  fi

  # Refresh the identity snapshot — claude may have updated org/email/seat
  # info in ~/.claude.json during the session.
  ( cd "\$CLAUDE_SWITCH_DIR" && . ./lib.sh && save_snapshot "\$profile" ) >/dev/null 2>&1 || true

  return \$rc
}
alias claude-personal='_claude_switch personal'
alias claude-work='_claude_switch work'
$ZSHRC_END
EOF
}

install_zshrc() {
  step "Installing zshrc aliases"

  if [[ ! -f "$ZSHRC" ]]; then
    warn "$ZSHRC does not exist; creating it."
    : > "$ZSHRC"
  fi

  local new_block; new_block=$(zshrc_block)

  if grep -qF "$ZSHRC_BEGIN" "$ZSHRC"; then
    # Replace existing managed block
    local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/zshrc.XXXXXX")
    awk -v B="$ZSHRC_BEGIN" -v E="$ZSHRC_END" '
      $0 == B { skip=1 }
      !skip   { print }
      $0 == E { skip=0 }
    ' "$ZSHRC" > "$tmp"
    printf "\n%s\n" "$new_block" >> "$tmp"
    mv "$tmp" "$ZSHRC"
    ok "Replaced existing claude-switch block in $ZSHRC"
  else
    {
      printf "\n"
      printf "%s\n" "$new_block"
    } >> "$ZSHRC"
    ok "Appended claude-switch block to $ZSHRC"
  fi

  info ""
  info "Reload your shell to pick up new aliases:"
  info "  ${C_CYN}source $ZSHRC${C_RST}"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

main() {
  step "claude-switch setup"
  info "Profile slots will be stored in macOS Keychain as 'Claude Code-<profile>'."
  info "Configured profiles: ${PROFILES[*]}"

  setup_profiles
  install_zshrc

  step "Done"
  cat <<EOF
Aliases available after ${C_CYN}source $ZSHRC${C_RST}:

  ${C_CYN}claude-personal${C_RST}   Launch claude as personal (swaps token + launches)
  ${C_CYN}claude-work${C_RST}       Launch claude as work     (swaps token + launches)
  ${C_CYN}ccs-personal${C_RST}      Mid-air switch to personal (no launch)
  ${C_CYN}ccs-work${C_RST}          Mid-air switch to work     (no launch)
  ${C_CYN}ccs-status${C_RST}        Show currently active profile
  ${C_CYN}ccs-list${C_RST}          List saved profile slots
EOF
}

main "$@"
