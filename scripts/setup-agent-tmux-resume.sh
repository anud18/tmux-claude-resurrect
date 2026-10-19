#!/usr/bin/env bash
# Makes tmux-resurrect bring back each AI agent pane (Claude Code, opencode, pi)
# with its own session, even when several panes share one folder.
#
#   each agent records its session id on its tmux pane (pane option)
#   resurrect post-save-all    -> agent-resurrect.sh save    (pane -> session id)
#   resurrect post-restore-all -> agent-resurrect.sh restore (resume each pane)
#
# No binaries are downloaded here, so the script is architecture-independent
# (x86_64 and arm64 alike). Install the agents with their own installers.
set -euo pipefail

TMUX_CONF="$HOME/.tmux.conf"
HELPER="$HOME/.tmux/agent-resurrect.sh"
CLAUDE_HOOK="$HOME/.claude/hooks/tmux-record-session.sh"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
OPENCODE_PLUGIN="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugin/tmux-record-session.js"
PI_EXTENSION="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/extensions/tmux-record-session.ts"

command -v jq >/dev/null 2>&1 || { echo "jq is required." >&2; exit 1; }
command -v tmux >/dev/null 2>&1 || { echo "tmux is required." >&2; exit 1; }
echo "Platform: $(uname -s) $(uname -m)"

mkdir -p "$(dirname "$CLAUDE_HOOK")" "$(dirname "$HELPER")" "$(dirname "$OPENCODE_PLUGIN")" "$(dirname "$PI_EXTENSION")"

# 1. Claude Code: SessionStart hook writes the session id to the pane option
cat > "$CLAUDE_HOOK" <<'EOF'
#!/usr/bin/env bash
# Claude Code SessionStart hook: remember this pane's session id in tmux.
[ -n "${TMUX_PANE:-}" ] || exit 0
id=$(jq -r '.session_id // empty')
[ -n "$id" ] && tmux set-option -p -t "$TMUX_PANE" @claude_session_id "$id" 2>/dev/null
exit 0
EOF
chmod +x "$CLAUDE_HOOK"

if jq -e --arg c "$CLAUDE_HOOK" '[.hooks.SessionStart[]?.hooks[]? | select(.command == $c)] | length > 0' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
  echo "Claude SessionStart hook already registered."
else
  cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak"
  jq --arg c "$CLAUDE_HOOK" '.hooks.SessionStart = ((.hooks.SessionStart // []) + [{"hooks":[{"type":"command","command":$c}]}])' \
    "$CLAUDE_SETTINGS.bak" > "$CLAUDE_SETTINGS"
  echo "Registered Claude SessionStart hook (backup: $CLAUDE_SETTINGS.bak)."
fi

# 2. opencode: plugin listens for session events and writes the id to the pane option
mkdir -p "$(dirname "$OPENCODE_PLUGIN")"
cat > "$OPENCODE_PLUGIN" <<'EOF'
// Records the opencode session id on the tmux pane so tmux-resurrect can resume it.
import { execFile } from "node:child_process"

export const TmuxRecordSession = async () => {
  let last = ""
  return {
    event: async ({ event }) => {
      if (event.type !== "session.created" && event.type !== "session.updated") return
      const info = event.properties?.info
      const pane = process.env.TMUX_PANE
      if (!info?.id || info.parentID || !pane || info.id === last) return
      last = info.id
      execFile("tmux", ["set-option", "-p", "-t", pane, "@opencode_session_id", info.id], () => {})
    },
  }
}
EOF
echo "Installed opencode plugin: $OPENCODE_PLUGIN"

# 3. pi: extension writes the session id to the pane option on every session start
cat > "$PI_EXTENSION" <<'EOF'
// Records the pi session id on the tmux pane so tmux-resurrect can resume it.
export default function (pi: any) {
  pi.on("session_start", async (_event: any, ctx: any) => {
    const pane = process.env.TMUX_PANE
    const id = ctx.sessionManager?.getSessionId?.()
    if (!pane || !id) return
    await pi.exec("tmux", ["set-option", "-p", "-t", pane, "@pi_session_id", id])
  })
}
EOF
echo "Installed pi extension: $PI_EXTENSION"

# 4. Save/restore helper, called by tmux-resurrect hooks
cat > "$HELPER" <<'EOF'
#!/usr/bin/env bash
# Usage: agent-resurrect.sh save|restore
STATE="$HOME/.tmux/agent-resurrect.tsv"
# agent : pane option holding its session id
KINDS="claude:@claude_session_id opencode:@opencode_session_id pi:@pi_session_id"

resume_cmd() {
  case "$1" in
    claude)   echo "claude --resume" ;;
    opencode) echo "opencode -s" ;;
    pi)       echo "pi --session" ;;
  esac
}

case "${1:-}" in
  save)
    tmp="$STATE.tmp"
    : > "$tmp"
    tmux list-panes -a -F '#{session_name}|#{window_index}|#{pane_index}|#{pane_id}|#{pane_current_command}' |
    while IFS='|' read -r sess win pane pane_id cmd; do
      for entry in $KINDS; do
        kind=${entry%%:*}; opt=${entry#*:}
        id=$(tmux show-options -pqv -t "$pane_id" "$opt")
        [ -n "$id" ] || continue
        # Only keep panes where the agent is still running (ignore stale ids).
        # pi is a node script, so its process may show up as "node".
        case "$kind:$cmd" in
          claude:claude|opencode:opencode|pi:pi|pi:node) ;;
          *) continue ;;
        esac
        printf '%s|%s|%s|%s|%s\n' "$sess" "$win" "$pane" "$kind" "$id" >> "$tmp"
      done
    done
    mv "$tmp" "$STATE"
    ;;
  restore)
    [ -s "$STATE" ] || exit 0
    while IFS='|' read -r sess win pane kind id; do
      target="$sess:$win.$pane"
      cmd=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null) || continue
      # Only type into an idle shell, never into a program that is already running.
      case "$cmd" in bash|zsh|sh|fish|dash) ;; *) continue ;; esac
      tmux send-keys -t "$target" "$(resume_cmd "$kind") $id" Enter
    done < "$STATE"
    ;;
  *) echo "usage: $0 save|restore" >&2; exit 1 ;;
esac
EOF
chmod +x "$HELPER"

# 5. tmux.conf: point the resurrect hooks at the helper (replaces the older claude-only helper)
sed -i "s#$HOME/.tmux/claude-resurrect.sh#$HELPER#g" "$TMUX_CONF"
rm -f "$HOME/.tmux/claude-resurrect.sh"

add_conf_line() {
  local match="$1" line="$2"
  if grep -qF "$match" "$TMUX_CONF"; then
    echo "Already in $TMUX_CONF: $match"
  else
    echo "Adding to $TMUX_CONF: $line"
    sed -i "/set -g @plugin 'tmux-plugins\/tpm'/a $line" "$TMUX_CONF"
  fi
}
add_conf_line "@resurrect-hook-post-restore-all" "set -g @resurrect-hook-post-restore-all '$HELPER restore'"
add_conf_line "@resurrect-hook-post-save-all" "set -g @resurrect-hook-post-save-all '$HELPER save'"

if [ -n "${TMUX:-}" ]; then
  tmux source-file "$TMUX_CONF"
  echo "Reloaded tmux config."
fi

echo
echo "Agents found on PATH:"
for a in claude opencode pi; do
  if command -v "$a" >/dev/null 2>&1; then echo "  $a: $(command -v "$a")"; else echo "  $a: not installed"; fi
done
echo
echo "Done. Sessions are tagged when they start or resume after this setup."
echo "Agents that were already running need to be resumed once to be tagged."
