# tmux-claude-resurrect

Setup scripts for [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) and [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum), plus a hook that brings each Claude Code pane back to its own conversation after a restore.

tmux-resurrect restores layouts and working directories, but not the programs running in them. This setup fixes that for Claude Code: if several Claude panes share one folder, each one resumes its own session.

## What's included

| Script | Purpose |
| --- | --- |
| `scripts/install-tmux-resurrect.sh` | Installs TPM (Tmux Plugin Manager) if missing, adds `tmux-resurrect` and `tmux-continuum` to `~/.tmux.conf`, and installs the plugins. |
| `scripts/setup-claude-tmux-resume.sh` | Wires Claude Code sessions into resurrect so each pane resumes with `claude --resume <id>`. |

## Requirements

- tmux 3.x
- git
- jq (for `setup-claude-tmux-resume.sh`)
- Claude Code CLI (`claude`)

## Installation

Run the scripts in order:

```bash
./scripts/install-tmux-resurrect.sh
./scripts/setup-claude-tmux-resume.sh   # optional: Claude session resume
```

### `install-tmux-resurrect.sh`

1. Clones TPM into `~/.tmux/plugins/tpm` if it isn't there yet.
2. Adds these lines to `~/.tmux.conf`, above the TPM `run` line:
   ```tmux
   set -g @plugin 'tmux-plugins/tmux-resurrect'
   set -g @plugin 'tmux-plugins/tmux-continuum'
   set -g @continuum-restore 'on'
   set -g @continuum-save-interval '15'
   ```
3. Installs the plugins. TPM needs a running tmux server with the config loaded, so the script starts a temporary session if none exists and removes it afterwards.

Every step is idempotent. Re-running the script skips anything already in place.

### `setup-claude-tmux-resume.sh`

It creates these files:

- `~/.claude/hooks/tmux-record-session.sh`: a Claude Code `SessionStart` hook. It stores the session ID in the pane's `@claude_session_id` tmux option.
- `~/.tmux/claude-resurrect.sh`: called by resurrect's hooks.
  - `save` writes `~/.claude/tmux-resurrect-claude.tsv`, which maps each pane that is running `claude` to its session ID.
  - `restore` runs `claude --resume <id>` in each recorded pane, skipping panes where Claude is already running.

It also:

- registers the `SessionStart` hook in `~/.claude/settings.json` (the original is saved as `settings.json.bak`), and
- adds `@resurrect-hook-post-save-all` and `@resurrect-hook-post-restore-all` to `~/.tmux.conf`.

## Usage

| Key | Action |
| --- | --- |
| `prefix + Ctrl-s` | Save the tmux session now |
| `prefix + Ctrl-r` | Restore the saved session |
| `prefix + I` | Install plugins from inside tmux (TPM) |

With tmux-continuum, the session is saved every 15 minutes, and it is restored automatically when tmux starts.

## Limitations

- Claude sessions that were already running before the hook was installed are not tagged. Restart them, or resume them once with `claude --resume`.
- If you switch conversations inside a pane (`/clear` or `/resume`), the hook records the new session ID the next time Claude starts. The ID stored at the last save is what gets resumed.
- Restore works by sending keystrokes into the pane's shell, so the pane has to be sitting at a shell prompt.
- The scripts assume the default paths under `$HOME`.
