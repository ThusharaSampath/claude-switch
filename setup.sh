#!/usr/bin/env bash
# One-time interactive setup for Claude Code account switching.
#
# What this does:
#   1. Saves the currently-active OAuth token to a per-profile Keychain slot.
#   2. Loops you through /logout + /login for any unsaved profiles.
#   3. Installs shell aliases (zsh -> ~/.zshrc, bash -> ~/.bash_profile):
#        claude-personal / claude-work  - swap token AND launch claude
#        ccs-personal    / ccs-work     - swap token only (mid-air switch)
#        ccs-status / ccs-list          - status helpers
#
# Idempotent: re-run safely, it skips already-saved slots and doesn't duplicate
# rc entries. Shell auto-detected from $SHELL (override: CLAUDE_SWITCH_SHELL).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

PROFILES=("personal" "work")

require_macos
require_python3

# Detect which shell rc file to manage.
SHELL_RC="$(detect_shell_rc)" || exit 1
SHELL_KIND="${SHELL_RC%%:*}"
RC="${SHELL_RC#*:}"
RC_BEGIN="# >>> claude-switch >>>"
RC_END="# <<< claude-switch <<<"
RC_BAK="${RC}.pre-claude-switch.bak"
CLAUDE_JSON_BAK="${CLAUDE_JSON}.pre-claude-switch.bak"

# ----------------------------------------------------------------------------
# Step 0: take one-shot backups of files we'll modify, so clean.sh can revert.
# ----------------------------------------------------------------------------

take_backups() {
  step "Pre-install backups"
  if [[ -f "$RC" && ! -f "$RC_BAK" ]]; then
    cp "$RC" "$RC_BAK"
    ok "Backed up $RC → $RC_BAK"
  elif [[ -f "$RC_BAK" ]]; then
    info "$RC_BAK already exists, keeping original backup."
  fi

  if [[ -f "$CLAUDE_JSON" && ! -f "$CLAUDE_JSON_BAK" ]]; then
    cp "$CLAUDE_JSON" "$CLAUDE_JSON_BAK"
    ok "Backed up $CLAUDE_JSON → $CLAUDE_JSON_BAK"
  elif [[ -f "$CLAUDE_JSON_BAK" ]]; then
    info "$CLAUDE_JSON_BAK already exists, keeping original backup."
  fi
}

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
  ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
  [[ "$ans" == "y" || "$ans" == "yes" ]]
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
# Step 2: install shell rc aliases.
# ----------------------------------------------------------------------------

rc_block() {
  cat <<EOF
$RC_BEGIN
# Managed by claude-switch ($SCRIPT_DIR). Do not edit between markers.
export CLAUDE_SWITCH_DIR="$SCRIPT_DIR"

# Mid-air switch (no claude launch)
alias ccs-personal="\$CLAUDE_SWITCH_DIR/switch.sh personal"
alias ccs-work="\$CLAUDE_SWITCH_DIR/switch.sh work"
alias ccs-status="\$CLAUDE_SWITCH_DIR/switch.sh --status"
alias ccs-list="\$CLAUDE_SWITCH_DIR/switch.sh --list"

# Launch claude as a given profile. Swap token+identity via switch.sh, run
# claude, then refresh the profile slot only if it's safe (no mid-air
# switch to a different account happened during the session).
_claude_switch() {
  local profile="\$1"; shift
  local slot="Claude Code-\$profile"

  # Use switch.sh to swap Keychain token and restore identity in claude.json
  "\$CLAUDE_SWITCH_DIR/switch.sh" "\$profile" >/dev/null || return 1

  command claude "\$@"
  local rc=\$?

  # Sync any refreshed token back to the profile slot, but ONLY if the
  # active slot still represents this profile. If a mid-air ccs-* switch
  # changed the active account during our session, writing it back would
  # clobber a different profile's token (and lose its refresh token).
  ( cd "\$CLAUDE_SWITCH_DIR" && . ./lib.sh
    saved_active=\$(read_slot "\$ACTIVE_SLOT") || exit 0
    saved_profile=\$(read_slot "\$slot")        || exit 0
    [[ -z "\$saved_active" || -z "\$saved_profile" ]] && exit 0

    # Compare refresh tokens — they're stable across access-token refreshes
    # but differ between accounts. If they match, this is a refresh of the
    # same account and it's safe to update the profile slot.
    refresh_active=\$(printf "%s" "\$saved_active"  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("claudeAiOauth",{}).get("refreshToken",""))')
    refresh_saved=\$(printf "%s"  "\$saved_profile" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("claudeAiOauth",{}).get("refreshToken",""))')

    if [[ -n "\$refresh_active" && "\$refresh_active" == "\$refresh_saved" ]]; then
      if [[ "\$saved_active" != "\$saved_profile" ]]; then
        # Same account, but access token changed (refresh happened) — update.
        write_slot "\$slot" "\$saved_active"
      fi
      # Refresh identity snapshot too
      save_snapshot "\$profile" >/dev/null 2>&1 || true
    fi
  ) >/dev/null 2>&1 || true

  return \$rc
}
alias claude-personal='_claude_switch personal'
alias claude-work='_claude_switch work'
$RC_END
EOF
}

# For bash, the alias block lives in ~/.bashrc — but macOS login shells
# (Terminal.app, iTerm, ssh) only read ~/.bash_profile and won't see it
# unless ~/.bash_profile sources ~/.bashrc. Make sure that's wired up.
ensure_bash_profile_sources_bashrc() {
  [[ "$SHELL_KIND" == "bash" ]] || return 0

  local bp="$HOME/.bash_profile"

  step "Linking ~/.bash_profile → ~/.bashrc"

  # If our own marker block is already in .bash_profile, we wrote it on a
  # previous run — leave it alone (idempotent).
  if [[ -f "$bp" ]] && grep -qF "$RC_BEGIN" "$bp" 2>/dev/null; then
    info "claude-switch source block already present in $bp."
    return 0
  fi

  # If .bash_profile already sources .bashrc by some non-comment line, the
  # user has already wired it up — don't add a competing source line.
  if [[ -f "$bp" ]] && grep -vE '^[[:space:]]*#' "$bp" | grep -qF '.bashrc'; then
    ok "$bp already references ~/.bashrc — no change needed."
    return 0
  fi

  cat <<EOF

Login shells on macOS (Terminal.app, iTerm, ssh) read ~/.bash_profile but
NOT ~/.bashrc. The claude-switch aliases just installed in ~/.bashrc won't
be visible in those terminals unless ~/.bash_profile sources ~/.bashrc.

claude-switch will append the following managed block to $bp
(wrapped in claude-switch markers, removable by clean.sh):

  ${C_CYN}[[ -r ~/.bashrc ]] && . ~/.bashrc${C_RST}

EOF
  read -r -p "Press Enter to append it (Ctrl+C to skip)... " _

  # Backup .bash_profile before mutating it. RC_BAK already covers .bashrc,
  # not .bash_profile, so we take a separate snapshot here.
  local bp_bak="${bp}.pre-claude-switch.bak"
  if [[ -f "$bp" && ! -f "$bp_bak" ]]; then
    cp "$bp" "$bp_bak"
    ok "Backed up $bp → $bp_bak"
  fi

  [[ -f "$bp" ]] || : > "$bp"
  {
    printf "\n%s\n" "$RC_BEGIN"
    printf "%s\n" "# Added by claude-switch so login shells (Terminal.app/iTerm/ssh)"
    printf "%s\n" "# pick up the aliases defined in ~/.bashrc."
    printf "%s\n" "[[ -r ~/.bashrc ]] && . ~/.bashrc"
    printf "%s\n" "$RC_END"
  } >> "$bp"
  ok "Appended source block to $bp"
}

install_rc() {
  step "Installing $SHELL_KIND aliases into $RC"

  if [[ ! -f "$RC" ]]; then
    warn "$RC does not exist; creating it."
    : > "$RC"
  fi

  local new_block; new_block=$(rc_block)

  if grep -qF "$RC_BEGIN" "$RC"; then
    # Replace existing managed block
    local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/claude-switch-rc.XXXXXX")
    awk -v B="$RC_BEGIN" -v E="$RC_END" '
      $0 == B { skip=1 }
      !skip   { print }
      $0 == E { skip=0 }
    ' "$RC" > "$tmp"
    printf "\n%s\n" "$new_block" >> "$tmp"
    mv "$tmp" "$RC"
    ok "Replaced existing claude-switch block in $RC"
  else
    {
      printf "\n"
      printf "%s\n" "$new_block"
    } >> "$RC"
    ok "Appended claude-switch block to $RC"
  fi

  info ""
  info "Reload your shell to pick up new aliases:"
  info "  ${C_CYN}source $RC${C_RST}"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

main() {
  step "claude-switch setup"
  info "Profile slots will be stored in macOS Keychain as 'Claude Code-<profile>'."
  info "Configured profiles: ${PROFILES[*]}"
  info "Detected shell: ${C_CYN}$SHELL_KIND${C_RST} (rc file: $RC)"

  take_backups
  setup_profiles
  install_rc
  ensure_bash_profile_sources_bashrc

  step "Done"
  cat <<EOF
Aliases available after ${C_CYN}source $RC${C_RST}:

  ${C_CYN}claude-personal${C_RST}   Launch claude as personal (swaps token + launches)
  ${C_CYN}claude-work${C_RST}       Launch claude as work     (swaps token + launches)
  ${C_CYN}ccs-personal${C_RST}      Mid-air switch to personal (no launch)
  ${C_CYN}ccs-work${C_RST}          Mid-air switch to work     (no launch)
  ${C_CYN}ccs-status${C_RST}        Show currently active profile
  ${C_CYN}ccs-list${C_RST}          List saved profile slots
EOF
}

main "$@"
