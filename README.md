# tmux-claude-resurrect

Setup scripts for [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) and [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum), plus hooks that bring each AI agent pane back to its own session after a restore.

tmux-resurrect restores layouts and working directories, but not the programs running in them. This setup fixes that for **Claude Code**, **opencode** and **pi**: if several panes share one folder, each one resumes its own session.

## What's included

| Script | Purpose |
| --- | --- |
| `scripts/install-tmux-resurrect.sh` | Installs TPM (Tmux Plugin Manager) if missing, adds `tmux-resurrect` and `tmux-continuum` to `~/.tmux.conf`, and installs the plugins. |
| `scripts/setup-agent-tmux-resume.sh` | Makes each agent pane resume its own session after restore (Claude Code, opencode, pi). |
| `scripts/install-claude-statusline.sh` | Installs the Claude Code status line (`claude/statusline-command.sh`) and sets `statusLine` in `~/.claude/settings.json`. |

## Supported agents

| Agent | How the session ID is recorded | Resume command |
| --- | --- | --- |
| Claude Code | `SessionStart` hook in `~/.claude/settings.json` | `claude --resume <id>` |
| opencode | plugin in `~/.config/opencode/plugin/` (`session.created` / `session.updated`) | `opencode -s <id>` |
| pi | extension in `~/.pi/agent/extensions/` (`session_start`) | `pi --session <id>` |

Agents you don't have installed are simply skipped. The setup script still installs their hooks, so they work as soon as you install them.

## Requirements

- tmux 3.x
- git
- jq (for `setup-agent-tmux-resume.sh`)
- At least one agent: `claude`, `opencode` or `pi` (or let the script install `opencode` and `pi`)

The scripts don't download any binaries, so they work the same on x86_64 and arm64. Install the agents with their own installers.

## Installation

Run the scripts in order:

```bash
./scripts/install-tmux-resurrect.sh
./scripts/setup-agent-tmux-resume.sh                     # wire up hooks only
./scripts/setup-agent-tmux-resume.sh --install opencode,pi   # also install missing agents
./scripts/setup-agent-tmux-resume.sh --install opencode,pi --dry-run   # print install commands only
./scripts/install-claude-statusline.sh                   # optional: Claude Code status line
```

`--install` takes a comma-separated list of `opencode` and `pi`. Agents already on `PATH` are skipped. Without `--install`, the script installs nothing.

| Agent | Install command |
| --- | --- |
| opencode | `curl -fsSL https://opencode.ai/install \| bash` (official installer, picks the binary for your architecture) |
| pi | If `node` (22.19+) and `npm` are missing, the script installs Node.js v22.23.3 with npm into `~/.local` (official tarball from nodejs.org, SHA256-checked, x64 or arm64). Then it runs `npm install -g --ignore-scripts --prefix ~/.local @earendil-works/pi-coding-agent`. No sudo needed. |

If `~/.local/bin` is not on your `PATH`, add it to your shell profile.

Claude Code is not installed by this script. Install it first.

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

### `setup-agent-tmux-resume.sh`

It creates these files:

- `~/.claude/hooks/tmux-record-session.sh`: Claude Code `SessionStart` hook. It stores the session ID in the pane option `@claude_session_id`.
- `~/.config/opencode/plugin/tmux-record-session.js`: opencode plugin. It stores the session ID in the pane option `@opencode_session_id`. Child sessions are ignored.
- `~/.pi/agent/extensions/tmux-record-session.ts`: pi extension. It stores the session ID in the pane option `@pi_session_id`.
- `~/.tmux/agent-resurrect.sh`: called by resurrect's hooks.
  - `save` writes `~/.tmux/agent-resurrect.tsv`, which lists each pane that is still running an agent, with its session ID.
  - `restore` types the resume command into each recorded pane that is sitting at an idle shell.

It also:

- registers the Claude `SessionStart` hook in `~/.claude/settings.json` (the original is saved as `settings.json.bak`), and
- sets `@resurrect-hook-post-save-all` and `@resurrect-hook-post-restore-all` in `~/.tmux.conf`. If you installed an earlier version, these now point to `agent-resurrect.sh`.

### `install-claude-statusline.sh`

Copies `claude/statusline-command.sh` to `~/.claude/statusline-command.sh` and sets `statusLine` in `~/.claude/settings.json` to run it. Replaced files are saved as `.bak`, and re-running changes nothing. It needs `jq` and `git`.

The status line shows:

- the last two directory components,
- git branch, dirty marker, ahead/behind (`↑2↓1`) and +/- line counts,
- model and context window size, and the output style (if not default),
- a context bar that turns bold red with `⚠` from 90%,
- 5-hour and 7-day usage bars with the time until reset (`↻2h13m`). Bars are green, yellow from 50% and red from 80%,
- session duration and cost.

Segments with no data are left out. It runs on bash builtins plus one `jq` and two `git` calls per render.

To set it up by hand instead, copy the script to `~/.claude/statusline-command.sh` and add this to `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "bash ~/.claude/statusline-command.sh",
  "padding": 0
}
```

The installer writes the absolute path instead of `~`. The branch icon needs a Nerd Font or Powerline font.

## Usage

| Key | Action |
| --- | --- |
| `prefix + Ctrl-s` | Save the tmux session now |
| `prefix + Ctrl-r` | Restore the saved session |
| `prefix + I` | Install plugins from inside tmux (TPM) |

With tmux-continuum, the session is saved every 15 minutes, and it is restored automatically when tmux starts.

## Testing status

- **Claude Code**: the record, save and restore steps were tested with a stand-in `claude` binary.
- **opencode**: tested end to end on aarch64 with opencode 1.19.3. The session was recorded, saved, and resumed into the same session after the tmux server was restarted.
- **pi**: the extension and the resume command were written from pi's documentation and type declarations. It has not been run yet.
- **x86_64**: the scripts don't contain architecture-specific code, but this was not run on an x86_64 machine.

## Limitations

- Agent sessions that were already running before the hooks were installed are not tagged. Restart them, or resume them once.
- If you switch conversations inside a pane (`/clear`, `/resume`, `/new`), the hook records the new session ID the next time the agent starts a session. The ID stored at the last save is what gets resumed.
- Restore works by typing into the pane's shell, so the pane has to be sitting at a shell prompt.
- The scripts assume the default paths under `$HOME` and the default `XDG_CONFIG_HOME` / `PI_CODING_AGENT_DIR`.
