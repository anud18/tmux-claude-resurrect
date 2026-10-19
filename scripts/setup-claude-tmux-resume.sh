#!/usr/bin/env bash
# Makes tmux-resurrect restore each Claude Code pane to its own conversation.
#
#   Claude SessionStart hook -> tags the tmux pane with @claude_session_id
#   resurrect post-save-all  -> dumps "pane position <-> session id" to a file
#   resurrect post-restore-all -> runs `claude --resume <id>` in each pane
set -euo pipefail

HOOK_DIR="$HOME/.claude/hooks"
RECORD="$HOOK_DIR/tmux-record-session.sh"
HELPER="$HOME/.tmux/claude-resurrect.sh"
SETTINGS="$HOME/.claude/settings.json"
TMUX_CONF="$HOME/.tmux.conf"

command -v jq >/dev/null 2>&1 || { echo "jq is required." >&2; exit 1; }
mkdir -p "$HOOK_DIR" "$(dirname "$HELPER")"

# 1. SessionStart hook: tag the pane with the session id
cat > "$RECORD" <<'EOF'
#!/usr/bin/env bash
# Claude Code SessionStart hook: remember this pane's session id in tmux.
[ -n "${TMUX_PANE:-}" ] || exit 0
id=$(jq -r '.session_id // empty')
[ -n "$id" ] && tmux set-option -p -t "$TMUX_PANE" @claude_session_id "$id" 2>/dev/null
exit 0
EOF
chmod +x "$RECORD"

# 2. Save/restore helper called by tmux-resurrect hooks
cat > "$HELPER" <<'EOF'
#!/usr/bin/env bash
# Usage: claude-resurrect.sh save|restore
STATE="$HOME/.claude/tmux-resurrect-claude.tsv"

case "${1:-}" in
  save)
    tmux list-panes -a -F \
      '#{session_name}	#{window_index}	#{pane_index}	#{pane_current_command}	#{@claude_session_id}' |
      awk -F'\t' '$4 == "claude" && $5 != "" { print $1 "\t" $2 "\t" $3 "\t" $5 }' > "$STATE.tmp" &&
      mv "$STATE.tmp" "$STATE"
    ;;
  restore)
    [ -s "$STATE" ] || exit 0
    while IFS=$'\t' read -r sess win pane id; do
      target="$sess:$win.$pane"
      cmd=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null) || continue
      [ "$cmd" = "claude" ] && continue   # already running
      tmux send-keys -t "$target" "claude --resume $id" Enter
    done < "$STATE"
    ;;
  *) echo "usage: $0 save|restore" >&2; exit 1 ;;
esac
EOF
chmod +x "$HELPER"

# 3. Register the SessionStart hook in Claude settings (idempotent, backs up first)
if jq -e --arg c "$RECORD" '[.hooks.SessionStart[]?.hooks[]? | select(.command == $c)] | length > 0' "$SETTINGS" >/dev/null 2>&1; then
  echo "SessionStart hook already registered."
else
  cp "$SETTINGS" "$SETTINGS.bak"
  jq --arg c "$RECORD" '.hooks.SessionStart = ((.hooks.SessionStart // []) + [{"hooks":[{"type":"command","command":$c}]}])' \
    "$SETTINGS.bak" > "$SETTINGS"
  echo "Registered SessionStart hook (backup: $SETTINGS.bak)."
fi

# 4. Register resurrect hooks in tmux.conf, above the TPM run line
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
echo "Done. Claude sessions started from now on are tracked per pane."
echo "Sessions that were already running need to be restarted (or /resume'd) once to be tagged."
