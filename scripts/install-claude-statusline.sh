#!/usr/bin/env bash
# Installs the Claude Code status line: copies claude/statusline-command.sh to
# ~/.claude/ and points "statusLine" in ~/.claude/settings.json at it.
# Idempotent; anything it replaces is saved as <file>.bak first.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_DIR/claude/statusline-command.sh"
DEST="$HOME/.claude/statusline-command.sh"
SETTINGS="$HOME/.claude/settings.json"
COMMAND="bash $DEST"

for cmd in jq git; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd is required by the status line." >&2; exit 1; }
done

mkdir -p "$(dirname "$DEST")"

# 1. Install the status line script
if [ -f "$DEST" ] && cmp -s "$SRC" "$DEST"; then
  echo "Status line script already up to date at $DEST"
else
  [ -f "$DEST" ] && cp "$DEST" "$DEST.bak"
  cp "$SRC" "$DEST"
  echo "Installed $DEST"
fi

# 2. Point statusLine at it in settings.json
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
if jq -e --arg c "$COMMAND" '.statusLine.command == $c' "$SETTINGS" >/dev/null 2>&1; then
  echo "statusLine already configured in $SETTINGS"
else
  cp "$SETTINGS" "$SETTINGS.bak"
  jq --arg c "$COMMAND" '.statusLine = {"type":"command","command":$c,"padding":0}' \
    "$SETTINGS.bak" > "$SETTINGS"
  echo "Configured statusLine (backup: $SETTINGS.bak)."
fi
