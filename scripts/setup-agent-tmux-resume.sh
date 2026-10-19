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

usage() {
  cat <<'EOF'
Usage: setup-agent-tmux-resume.sh [--install LIST] [--dry-run]

  --install LIST  comma-separated agents to install if missing: opencode,pi
                  (claude is not installed by this script; install it first)
                  default: install nothing, only wire up hooks
  --dry-run       print the install commands without running them
EOF
}

INSTALL_LIST=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL_LIST="${2:?--install needs a value}"; shift 2 ;;
    --install=*) INSTALL_LIST="${1#--install=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "jq is required." >&2; exit 1; }
command -v tmux >/dev/null 2>&1 || { echo "tmux is required." >&2; exit 1; }
echo "Platform: $(uname -s) $(uname -m)"

# pi runs on Node.js >= 22.19. If node or npm is missing (or too old), install the
# official Node LTS tarball into ~/.local, which also brings npm. Nothing needs sudo.
NODE_VERSION="v22.23.3"
LOCAL_BIN="$HOME/.local/bin"

node_ok() {
  command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 || return 1
  node -e 'const [a, b] = process.versions.node.split(".").map(Number); process.exit(a > 22 || (a === 22 && b >= 19) ? 0 : 1)'
}

node_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo x64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo "unsupported CPU architecture: $(uname -m)" >&2; return 1 ;;
  esac
}

ensure_node() {
  if node_ok; then
    echo "node $(node -v) and npm already available"
    return 0
  fi
  local arch base file dir tmp
  arch=$(node_arch) || return 1
  base="https://nodejs.org/dist/$NODE_VERSION"
  file="node-$NODE_VERSION-linux-$arch.tar.xz"
  dir="$HOME/.local/share/node-$NODE_VERSION-linux-$arch"
  if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] download $base/$file, verify SHA256, extract to $dir, link node/npm/npx into $LOCAL_BIN"
    return 0
  fi
  command -v xz >/dev/null 2>&1 || { echo "xz is required to unpack Node.js." >&2; return 1; }
  echo "Installing Node.js $NODE_VERSION ($arch) with npm into $dir"
  tmp=$(mktemp -d)
  curl -fsSL "$base/$file" -o "$tmp/$file"
  curl -fsSL "$base/SHASUMS256.txt" -o "$tmp/SHASUMS256.txt"
  if ! (cd "$tmp" && grep " $file\$" SHASUMS256.txt | sha256sum -c -); then
    rm -rf "$tmp"
    echo "Node.js checksum mismatch; aborting." >&2
    return 1
  fi
  mkdir -p "$dir" "$LOCAL_BIN"
  tar -xJf "$tmp/$file" -C "$dir" --strip-components=1
  rm -rf "$tmp"
  for bin in node npm npx; do ln -sfn "$dir/bin/$bin" "$LOCAL_BIN/$bin"; done
  export PATH="$LOCAL_BIN:$PATH"
  node_ok || { echo "Node.js install did not work." >&2; return 1; }
}

# Installs one agent if it is missing. Official installers pick the right binary
# for the machine's architecture (x86_64 or arm64), so no arch mapping is needed here.
install_agent() {
  local agent="$1" cmd
  if command -v "$agent" >/dev/null 2>&1; then
    echo "$agent already installed: $(command -v "$agent")"
    return 0
  fi
  case "$agent" in
    opencode) cmd="curl -fsSL https://opencode.ai/install | bash" ;;
    pi)       cmd="npm install -g --ignore-scripts --prefix $HOME/.local @earendil-works/pi-coding-agent" ;;
    claude)   echo "claude is not installed by this script; install it first." >&2; return 1 ;;
    *)        echo "unknown agent: $agent (expected opencode or pi)" >&2; return 1 ;;
  esac
  if [ "$DRY_RUN" = 1 ]; then
    [ "$agent" = pi ] && ensure_node
    echo "[dry-run] $cmd"
    return 0
  fi
  if [ "$agent" = pi ]; then
    ensure_node || return 1
  fi
  echo "Installing $agent: $cmd"
  bash -c "$cmd"
  export PATH="$LOCAL_BIN:$PATH"
  command -v "$agent" >/dev/null 2>&1 || { echo "$agent did not appear on PATH after install." >&2; return 1; }
}

if [ -n "$INSTALL_LIST" ]; then
  for agent in ${INSTALL_LIST//,/ }; do
    install_agent "$agent"
  done
fi

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
