#!/usr/bin/env bash
# Shared helpers for claude-switch scripts. Source, don't execute.

set -u

ACTIVE_SLOT="${ACTIVE_SLOT:-Claude Code-credentials}"
PROFILE_SLOT_PREFIX="${PROFILE_SLOT_PREFIX:-Claude Code-}"
CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude.json}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-switch}"

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

require_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    err "python3 not found on PATH."
    err "claude-switch uses python3 to parse Claude's JSON configs."
    err "macOS ships with /usr/bin/python3; ensure your shell's PATH includes it."
    err "(If you're inside a tool like gvm that scrubs PATH, run from a fresh shell.)"
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

snapshot_path() {
  printf "%s/%s.account.json" "$SNAPSHOT_DIR" "$1"
}

# Print "email / org" extracted from a JSON file containing an oauthAccount
# object. Prints "<unreadable>" on any failure.
_summarize_oauth_file() {
  local path="$1"
  [[ -s "$path" ]] || { printf "<missing>"; return; }
  python3 - "$path" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(f'{d.get("emailAddress", "?")} / {d.get("organizationName", "?")}')
except Exception:
    print("<unreadable>")
PYEOF
}

# Read the oauthAccount block out of ~/.claude.json. Prints JSON on success,
# empty string + non-zero return if missing / unreadable.
read_oauth_account() {
  [[ -f "$CLAUDE_JSON" ]] || return 1
  python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
oa = d.get("oauthAccount")
if not oa:
    sys.exit(2)
json.dump(oa, sys.stdout, sort_keys=True, indent=2)
' "$CLAUDE_JSON" 2>/dev/null
}

# Replace the oauthAccount block in ~/.claude.json with the given JSON content.
# Writes atomically (temp file + rename). Returns non-zero on any failure.
write_oauth_account() {
  local new_block="$1"
  [[ -f "$CLAUDE_JSON" ]] || { err "$CLAUDE_JSON not found"; return 1; }
  [[ -n "$new_block" ]] || { err "Refusing to write empty oauthAccount block"; return 1; }

  python3 - "$CLAUDE_JSON" <<'PYEOF'
import json, os, sys, tempfile
path = sys.argv[1]
new_block = json.loads(sys.stdin.read())
with open(path) as f:
    data = json.load(f)
data["oauthAccount"] = new_block
dir_ = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(prefix=".claude.json.", dir=dir_)
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)
except Exception:
    os.unlink(tmp)
    raise
PYEOF
}

# Save the current oauthAccount block to a profile snapshot file.
save_snapshot() {
  local profile="$1" content
  if ! content=$(read_oauth_account); then
    err "Could not read oauthAccount from $CLAUDE_JSON"
    return 1
  fi
  [[ -n "$content" ]] || { err "Empty oauthAccount block; refusing to save"; return 1; }
  mkdir -p "$SNAPSHOT_DIR"
  printf "%s\n" "$content" > "$(snapshot_path "$profile")"
}

snapshot_exists() {
  [[ -s "$(snapshot_path "$1")" ]]
}

# Pretty-print a snapshot's email/org for logging.
snapshot_summary() {
  local profile="$1" path
  path=$(snapshot_path "$profile")
  [[ -s "$path" ]] || { printf "<no snapshot>"; return; }
  _summarize_oauth_file "$path"
}

# Pretty-print the live identity stored in ~/.claude.json.
claude_json_summary() {
  [[ -f "$CLAUDE_JSON" ]] || { printf "<no claude.json>"; return; }
  python3 - "$CLAUDE_JSON" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    oa = d.get("oauthAccount") or {}
    if not oa:
        print("<no oauthAccount block>")
    else:
        print(f'{oa.get("emailAddress", "?")} / {oa.get("organizationName", "?")}')
except Exception:
    print("<unreadable>")
PYEOF
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
