# claude-switch

Fast, non-interactive switching between multiple Claude Code accounts (e.g. personal and work) on macOS.

After a one-time setup, swap accounts with a single shell alias — no `/logout`, no browser, no re-auth.

## Requirements

- macOS
- zsh
- Claude Code installed, logged into at least one account
- Python 3 (preinstalled on macOS)

## Setup

```bash
./setup.sh
source ~/.zshrc
```

The script saves each account's OAuth token + identity to per-profile Keychain slots and installs aliases. Safe to re-run.

## Aliases

| Alias              | Action                                              |
| ------------------ | --------------------------------------------------- |
| `claude-personal`  | Swap to personal **and launch** `claude`            |
| `claude-work`      | Swap to work **and launch** `claude`                |
| `ccs-personal`     | Mid-air swap to personal (no launch)                |
| `ccs-work`         | Mid-air swap to work (no launch)                    |
| `ccs-status`       | Show currently active profile                       |
| `ccs-list`         | List all saved profiles                             |

## Important limitation: mid-air switches don't affect running sessions

A running Claude session loads its OAuth token **into memory at startup** and never re-reads it. So:

- `ccs-personal` while a work session is open → that session keeps billing **work** until you exit, even though `/status` shows personal.
- If work hits its rate limit, you **cannot** mid-air switch and keep going — the running process is stuck on the old token.

**The pattern that works:**

```bash
# In the stuck session:
/exit

# Then:
ccs-personal
claude -c          # continues the same conversation, now billing personal
```

`ccs-*` swaps take effect on the **next** `claude` invocation. Already-running sessions need a restart.

## Status line integration

The companion [`ccstatus-go`](../ccstatus-go) shows the active profile in the status line (cyan `personal` / magenta `work`). Cached for 60s by default.

## Customising

Profiles are hardcoded as `personal` and `work`. To add or rename, edit `PROFILES=(...)` in `setup.sh` and `switch.sh`, then re-run setup.

## Reverting

```bash
# Remove aliases:
sed -i '' '/^# >>> claude-switch >>>$/,/^# <<< claude-switch <<<$/d' ~/.zshrc

# Delete saved tokens (the live slot is left alone):
security delete-generic-password -s "Claude Code-personal"
security delete-generic-password -s "Claude Code-work"
rm -rf ~/.config/claude-switch
```

A backup of your original `~/.zshrc` is at `~/.zshrc.pre-claude-switch.bak`.
