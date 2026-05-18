# claude-switch

Fast, non-interactive switching between multiple Claude Code accounts (e.g. personal and work) on macOS.

Claude Code stores its OAuth credentials in the macOS Keychain under a single fixed entry (`Claude Code-credentials`). That means `CLAUDE_CONFIG_DIR` alone can't separate accounts — both configs end up reading the same token. This tool works around that by saving each account's full OAuth token (access + refresh) to its own Keychain slot, and swapping the active slot on demand.

Once both slots are saved, switching is fully non-interactive — no re-login, no browser prompt. The refresh token in each saved slot keeps the account authenticated indefinitely.

## Requirements

- macOS (uses `security` CLI for Keychain access)
- zsh (the setup writes aliases to `~/.zshrc`)
- Claude Code already installed and logged into at least one account

## One-time setup

```bash
./setup.sh
```

The script:

1. Saves the currently-active OAuth token to a per-profile Keychain slot.
2. For any profile not yet saved, walks you through logging into that account in Claude (`/logout` → `/login`) and captures the token afterwards.
3. Appends a managed block to `~/.zshrc` with the aliases below.

Re-running is safe — it skips already-saved slots and replaces the existing `~/.zshrc` block instead of duplicating it.

After setup, reload your shell:

```bash
source ~/.zshrc
```

## Aliases installed

| Alias              | Action                                                                                  |
| ------------------ | --------------------------------------------------------------------------------------- |
| `claude-personal`  | Swap Keychain token to personal, **launch** `claude`, then sync any refreshed token back |
| `claude-work`      | Swap Keychain token to work,     **launch** `claude`, then sync any refreshed token back |
| `ccs-personal`     | Mid-air switch to personal (swap token only, no launch)                                 |
| `ccs-work`         | Mid-air switch to work     (swap token only, no launch)                                 |
| `ccs-status`       | Show which profile is currently active                                                  |
| `ccs-list`         | List all saved profile slots and their subscription tier                                |

### When to use which

- `claude-personal` / `claude-work` — starting a new Claude session as a specific account. The token-refresh sync after exit keeps the profile slot's refresh token current.
- `ccs-personal` / `ccs-work` — you've got Claude running and want subsequent `claude` invocations (in other terminals, or after restart) to use a different account. Existing running sessions keep the token they loaded at startup; restart them to pick up the new account.

## How it works

Three Keychain slots:

- `Claude Code-credentials` — the live slot Claude reads. Always reflects the *currently active* account.
- `Claude Code-personal`   — saved snapshot of the personal account token.
- `Claude Code-work`       — saved snapshot of the work account token.

Switching = copy a snapshot slot into the live slot. That's it. The access token (~8h lifetime) and refresh token (long-lived) come along for the ride.

When Claude refreshes the access token in-process, it writes the new token back to `Claude Code-credentials`. The `_claude_switch` shell function (used by `claude-personal` / `claude-work`) detects this on exit and syncs the refreshed token back to the profile slot so backups stay current.

## Status line integration

The companion [`ccstatus-go`](../ccstatus-go) status line includes an `account` component that detects which profile is active and renders a colored label (cyan `personal` / magenta `work`). It reads the Keychain via the same slot scheme.

The component caches detection for 60s per session (configurable via `providers.account.cache.ttl` in `ccstatus.yaml`). After a mid-air `ccs-*` switch, statuslines in already-running sessions take up to 60s to reflect the change; new sessions pick it up immediately.

## Files

- `setup.sh`  — interactive one-time setup
- `switch.sh` — non-interactive switcher (the `ccs-*` aliases call this)
- `lib.sh`    — shared helpers (Keychain read/write, color output, profile detection)

## Customising

Profiles are hardcoded as `personal` and `work` in both scripts. To add or rename profiles, edit the `PROFILES=(...)` line near the top of `setup.sh` and `switch.sh`, then re-run `setup.sh`.

The Keychain service name prefix and active-slot name are overridable via environment variables (see `lib.sh`):

```bash
ACTIVE_SLOT="Claude Code-credentials"   # the live slot
PROFILE_SLOT_PREFIX="Claude Code-"      # joined with profile name
```

## Reverting

```bash
# Remove the managed block from ~/.zshrc:
sed -i '' '/^# >>> claude-switch >>>$/,/^# <<< claude-switch <<<$/d' ~/.zshrc

# Delete the saved snapshots (the live slot is left alone):
security delete-generic-password -s "Claude Code-personal"
security delete-generic-password -s "Claude Code-work"
```

A backup of your original `~/.zshrc` is at `~/.zshrc.pre-claude-switch.bak` (created by the initial install).
