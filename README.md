# claude-switch

Fast, non-interactive switching between multiple Claude Code accounts (e.g. personal and work) on macOS.

After a one-time setup, swap accounts with a single shell alias — no `/logout`, no browser, no re-auth.

## Requirements

- macOS
- zsh or bash
- Claude Code installed, logged into at least one account
- Python 3 (preinstalled on macOS)

## Setup

```bash
./setup.sh
# then, for your shell:
source ~/.zshrc    # zsh
source ~/.bashrc   # bash
```

The script saves each account's OAuth token + identity to per-profile Keychain slots and installs aliases into the rc file matching your shell (`$SHELL`): `~/.zshrc` for zsh, `~/.bashrc` for bash. Override detection with `CLAUDE_SWITCH_SHELL=zsh` or `CLAUDE_SWITCH_SHELL=bash` if needed. Safe to re-run.

For bash on macOS, `~/.bashrc` isn't read by login shells (Terminal.app, iTerm, ssh) — only by non-login interactive shells like the VS Code terminal. If `~/.bash_profile` doesn't already source `~/.bashrc`, setup prompts you (press Enter) to append a managed source line so the aliases work everywhere.

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

A running Claude session loads its OAuth token **into memory at startup** and never re-reads it. So, `ccs-personal` while a work session is open → that session keeps billing **work** until you exit, even though `/status` shows personal.

**The pattern that works:**

```bash
# In the stuck session:
/exit

# Then:
ccs-personal
claude -c          # continues the same conversation, now billing personal
```

## Customising

Profiles are hardcoded as `personal` and `work`. To add or rename, edit `PROFILES=(...)` in `setup.sh` and `switch.sh`, then re-run setup.

## Uninstall

```bash
./clean.sh
```

Removes the saved Keychain slots, snapshot files, and the managed block from `~/.zshrc` and/or `~/.bash_profile`, then restores `~/.claude.json` from the pre-install backup. The currently-active login (`Claude Code-credentials`) is left alone, so you stay signed in.

Flags: `--yes` to skip the confirmation prompt, `--no-restore` to leave `~/.claude.json` as-is.

## Status line integration

The companion [`ccstatus-go`](https://github.com/Mirage20/ccstatus-go) will show the active profile in the status line after https://github.com/Mirage20/ccstatus-go/pull/2 this PR is merged. (cyan `personal` / magenta `work`). Cached for 60s by default.
