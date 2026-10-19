#!/usr/bin/env bash
# Installs TPM (Tmux Plugin Manager) if missing, then installs tmux-resurrect via TPM.
set -euo pipefail

TPM_DIR="$HOME/.tmux/plugins/tpm"
TMUX_CONF="$HOME/.tmux.conf"

command -v tmux >/dev/null 2>&1 || { echo "tmux is not installed. Install it first." >&2; exit 1; }
command -v git  >/dev/null 2>&1 || { echo "git is not installed. Install it first." >&2; exit 1; }

# 1. Install TPM if missing
if [ -d "$TPM_DIR" ]; then
  echo "TPM already installed at $TPM_DIR"
else
  echo "Installing TPM..."
  git clone https://github.com/tmux-plugins/tpm "$TPM_DIR"
fi

# 2. Ensure ~/.tmux.conf exists
touch "$TMUX_CONF"

# 3. Add TPM block, tmux-resurrect and tmux-continuum to config (idempotent)
if ! grep -q "tmux-plugins/tpm" "$TMUX_CONF"; then
  echo "Adding TPM to $TMUX_CONF..."
  cat >> "$TMUX_CONF" <<'EOF'

# List of plugins
set -g @plugin 'tmux-plugins/tpm'

# Initialize TMUX plugin manager (keep this line at the very bottom of tmux.conf)
run '~/.tmux/plugins/tpm/tpm'
EOF
fi

# Insert each line right after the TPM plugin line so it stays above the run line
add_conf_line() {
  local match="$1" line="$2"
  if grep -qF "$match" "$TMUX_CONF"; then
    echo "Already in $TMUX_CONF: $match"
  else
    echo "Adding to $TMUX_CONF: $line"
    sed -i "/set -g @plugin 'tmux-plugins\/tpm'/a $line" "$TMUX_CONF"
  fi
}

add_conf_line "@continuum-save-interval" "set -g @continuum-save-interval '15'"
add_conf_line "@continuum-restore" "set -g @continuum-restore 'on'"
add_conf_line "tmux-plugins/tmux-continuum" "set -g @plugin 'tmux-plugins/tmux-continuum'"
add_conf_line "tmux-plugins/tmux-resurrect" "set -g @plugin 'tmux-plugins/tmux-resurrect'"

# 4. Install plugins via TPM (needs a tmux server that has loaded the config)
echo "Installing plugins..."
STARTED_TMP_SERVER=0
if ! tmux info >/dev/null 2>&1; then
  tmux new-session -d -s tpm-install-tmp
  STARTED_TMP_SERVER=1
fi
tmux source-file "$TMUX_CONF"
"$TPM_DIR/bin/install_plugins"
if [ "$STARTED_TMP_SERVER" = 1 ]; then
  tmux kill-session -t tpm-install-tmp
fi

# 5. Reload config if inside a tmux session
if [ -n "${TMUX:-}" ]; then
  tmux source-file "$TMUX_CONF"
  echo "Reloaded tmux config."
fi

echo
echo "Done. Usage inside tmux:"
echo "  prefix + Ctrl-s  save session"
echo "  prefix + Ctrl-r  restore session"
echo "tmux-continuum auto-saves every 15 min and restores on tmux start."
