#!/usr/bin/env bash
# Uninstall claude-switch. Removes everything setup.sh created and restores
# the original ~/.claude.json and ~/.zshrc from the pre-install backups.
#
# The currently-active Keychain slot (Claude Code-credentials) is left alone,
# so you stay logged into whichever account is active. Re-login is only
# needed if that token has been corrupted or revoked.
#
# Flags:
#   --yes / -y      Skip the confirmation prompt
#   --no-restore    Don't restore ~/.claude.json from backup (leave it as-is)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

PROFILES=("personal" "work")
RC_BEGIN="# >>> claude-switch >>>"
RC_END="# <<< claude-switch <<<"
# Setup writes the managed block into ~/.zshrc (zsh) or ~/.bash_profile
# (bash), but a user may have switched shells between install and uninstall,
# or moved the block into a different rc file by hand. Scan every common
# shell startup file on macOS — we only remove blocks that carry our marker,
# so extra candidates can't trigger false positives.
RC_CANDIDATES=(
  "$HOME/.zshrc"
  "$HOME/.zprofile"
  "$HOME/.zshenv"
  "$HOME/.bash_profile"
  "$HOME/.bashrc"
  "$HOME/.profile"
)
CLAUDE_JSON_BAK="${CLAUDE_JSON}.pre-claude-switch.bak"

ASSUME_YES=0
DO_RESTORE_JSON=1

require_macos

usage() {
  cat <<EOF
Usage: $(basename "$0") [--yes|-y] [--no-restore] [--help]

Removes everything claude-switch created:
  - Keychain slots: Claude Code-personal, Claude Code-work
  - Snapshot dir: $SNAPSHOT_DIR
  - Managed block in any of: ${RC_CANDIDATES[*]}

And, unless --no-restore, restores:
  - $CLAUDE_JSON from $CLAUDE_JSON_BAK

The active Keychain slot (Claude Code-credentials) is NOT touched.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)         ASSUME_YES=1; shift ;;
    --no-restore)     DO_RESTORE_JSON=0; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                err "Unknown flag: $1"; usage; exit 2 ;;
  esac
done

# ----------------------------------------------------------------------------
# Plan summary
# ----------------------------------------------------------------------------

step "claude-switch uninstall"
echo "The following will be removed/restored:"
echo

# Keychain
for p in "${PROFILES[@]}"; do
  slot=$(slot_name "$p")
  if slot_exists "$slot"; then
    echo "  ${C_RED}remove${C_RST}    Keychain slot: $slot"
  else
    echo "  ${C_DIM}skip${C_RST}      Keychain slot: $slot ${C_DIM}(absent)${C_RST}"
  fi
done

# Snapshot dir
if [[ -d "$SNAPSHOT_DIR" ]]; then
  echo "  ${C_RED}remove${C_RST}    Snapshot dir: $SNAPSHOT_DIR"
else
  echo "  ${C_DIM}skip${C_RST}      Snapshot dir: $SNAPSHOT_DIR ${C_DIM}(absent)${C_RST}"
fi

# rc blocks — check every candidate, but only mention files that have the
# marker. Absent files would just be noise across 6 candidates.
any_rc_match=0
for rc in "${RC_CANDIDATES[@]}"; do
  if [[ -f "$rc" ]] && grep -qF "$RC_BEGIN" "$rc" 2>/dev/null; then
    echo "  ${C_RED}remove${C_RST}    Managed block in: $rc"
    rc_bak="${rc}.pre-claude-switch.bak"
    if [[ -f "$rc_bak" ]]; then
      echo "  ${C_DIM}note${C_RST}      pre-install backup at: $rc_bak"
    fi
    any_rc_match=1
  fi
done
if (( ! any_rc_match )); then
  echo "  ${C_DIM}skip${C_RST}      Managed block in shell rc files ${C_DIM}(none found)${C_RST}"
fi

# claude.json restore
if (( DO_RESTORE_JSON )); then
  if [[ -f "$CLAUDE_JSON_BAK" ]]; then
    echo "  ${C_GRN}restore${C_RST}   $CLAUDE_JSON ← $CLAUDE_JSON_BAK"
  else
    echo "  ${C_YLW}skip${C_RST}      $CLAUDE_JSON ${C_YLW}(no backup at $CLAUDE_JSON_BAK)${C_RST}"
  fi
else
  echo "  ${C_DIM}skip${C_RST}      $CLAUDE_JSON ${C_DIM}(--no-restore)${C_RST}"
fi

# What's NOT touched
echo
echo "${C_DIM}Not touched:${C_RST}"
echo "  - Keychain slot: Claude Code-credentials (your active login stays)"
echo "  - ~/.claude/ (settings, history, plugins, memory, etc.)"
echo "  - pre-install backups (*.pre-claude-switch.bak — left as safety copies)"

# ----------------------------------------------------------------------------
# Confirm
# ----------------------------------------------------------------------------

if (( ! ASSUME_YES )); then
  echo
  read -r -p "Proceed? [y/N] " ans
  ans=$(printf '%s' "${ans:-}" | tr '[:upper:]' '[:lower:]')
  if [[ "$ans" != "y" && "$ans" != "yes" ]]; then
    info "Aborted."
    exit 0
  fi
fi

# ----------------------------------------------------------------------------
# Execute
# ----------------------------------------------------------------------------

step "Removing"

# Keychain slots
for p in "${PROFILES[@]}"; do
  slot=$(slot_name "$p")
  if slot_exists "$slot"; then
    security delete-generic-password -s "$slot" >/dev/null 2>&1 && ok "Deleted Keychain slot: $slot"
  fi
done

# Snapshot dir
if [[ -d "$SNAPSHOT_DIR" ]]; then
  rm -rf -- "$SNAPSHOT_DIR" && ok "Removed $SNAPSHOT_DIR"
fi

# rc blocks (zshrc and/or bash_profile)
REMOVED_FROM=()
for rc in "${RC_CANDIDATES[@]}"; do
  if [[ -f "$rc" ]] && grep -qF "$RC_BEGIN" "$rc" 2>/dev/null; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/claude-switch-rc.XXXXXX")
    awk -v B="$RC_BEGIN" -v E="$RC_END" '
      $0 == B { skip=1; next }
      $0 == E { skip=0; next }
      !skip   { print }
    ' "$rc" > "$tmp"
    mv "$tmp" "$rc"
    ok "Removed managed block from $rc"
    REMOVED_FROM+=("$rc")
  fi
done

# Restore claude.json
if (( DO_RESTORE_JSON )) && [[ -f "$CLAUDE_JSON_BAK" ]]; then
  cp "$CLAUDE_JSON_BAK" "$CLAUDE_JSON" && ok "Restored $CLAUDE_JSON from backup"
fi

step "Done"
echo "Reload your shell to clear the aliases (or open a new terminal):"
if (( ${#REMOVED_FROM[@]} )); then
  for rc in "${REMOVED_FROM[@]}"; do
    echo "  ${C_CYN}source $rc${C_RST}"
  done
else
  echo "  (no rc files were modified)"
fi

echo
echo "If you don't want the backups anymore:"
for rc in "${RC_CANDIDATES[@]}"; do
  rc_bak="${rc}.pre-claude-switch.bak"
  [[ -f "$rc_bak" ]] && echo "  rm \"$rc_bak\""
done
[[ -f "$CLAUDE_JSON_BAK" ]] && echo "  rm \"$CLAUDE_JSON_BAK\""
