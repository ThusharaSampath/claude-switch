#!/usr/bin/env bash
# Shared helpers for claude-switch scripts. Source, don't execute.

set -u

ACTIVE_SLOT="${ACTIVE_SLOT:-Claude Code-credentials}"
PROFILE_SLOT_PREFIX="${PROFILE_SLOT_PREFIX:-Claude Code-}"

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
  C_CYN=$'\033[36m'; C_MAG=$'\033[35m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_CYN=""; C_MAG=""; C_DIM=""; C_RST=""
fi

info()  { printf "%s\n" "$*"; }
ok()    { printf "%s✓%s %s\n" "$C_GRN" "$C_RST" "$*"; }
warn()  { printf "%s!%s %s\n" "$C_YLW" "$C_RST" "$*" >&2; }
err()   { printf "%s✗%s %s\n" "$C_RED" "$C_RST" "$*" >&2; }
step()  { printf "\n%s== %s ==%s\n" "$C_CYN" "$*" "$C_RST"; }

require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    err "This script only works on macOS (uses the Keychain)."
    exit 1
  fi
}

slot_name() { printf "%s%s" "$PROFILE_SLOT_PREFIX" "$1"; }

read_slot() {
  security find-generic-password -s "$1" -w 2>/dev/null
}

write_slot() {
  local slot="$1" secret="$2"
  security delete-generic-password -s "$slot" >/dev/null 2>&1 || true
  security add-generic-password -s "$slot" -a "$USER" -w "$secret"
}

slot_exists() {
  security find-generic-password -s "$1" >/dev/null 2>&1
}

# Print subscriptionType embedded in an OAuth token JSON blob, or "?".
token_tier() {
  local blob="$1"
  printf "%s" "$blob" | python3 -c '
import sys, json
try:
    print(json.load(sys.stdin).get("claudeAiOauth", {}).get("subscriptionType", "?"))
except Exception:
    print("?")
' 2>/dev/null || printf "?"
}

# Print which configured profile matches the active token, or "unknown",
# or empty if no active token.
detect_active_profile() {
  local active
  active=$(read_slot "$ACTIVE_SLOT") || return 0
  [[ -z "$active" ]] && return 0
  local p saved
  for p in "$@"; do
    saved=$(read_slot "$(slot_name "$p")") || continue
    if [[ "$saved" == "$active" ]]; then
      printf "%s" "$p"
      return 0
    fi
  done
  printf "unknown"
}
