#!/bin/bash
# Claude Code status line. Reads the session JSON on stdin, prints one line.
# Needs only bash, jq and git (no python3).
session=$(cat)
LC_NUMERIC=C

CTX_WARN_PCT=90        # context usage that turns the bar into a warning
RATE_RED_PCT=80
RATE_YELLOW_PCT=50
BAR_WIDTH=8

# ── Helpers (results go in globals, so no subshell forks) ──────────────────────
round_pct() {  # "42.6" -> 43
  printf -v ROUNDED '%.0f' "${1:-0}" 2>/dev/null || ROUNDED=0
}

progress_bar() {  # pct width -> BAR
  local filled=$(( ($1 * $2 + 50) / 100 )) spaces
  (( filled > $2 )) && filled=$2
  (( filled < 0 )) && filled=0
  printf -v spaces '%*s' "$filled" ''
  BAR="${spaces// /█}"
  printf -v spaces '%*s' "$(( $2 - filled ))" ''
  BAR="$BAR${spaces// /░}"
}

color_for_pct() {  # pct -> COLOR
  if   (( $1 >= RATE_RED_PCT ));    then COLOR='\e[38;5;203m'   # red
  elif (( $1 >= RATE_YELLOW_PCT )); then COLOR='\e[38;5;221m'   # yellow
  else COLOR='\e[38;5;114m'; fi                                  # green
}

format_remaining() {  # resets_at (epoch seconds or date string) -> REMAINING, empty if past
  REMAINING=""
  local at=$1 now left
  [[ -z "$at" ]] && return
  [[ "$at" =~ ^[0-9]+$ ]] || at=$(date -d "$at" +%s 2>/dev/null) || return
  printf -v now '%(%s)T' -1
  left=$(( at - now ))
  (( left <= 0 )) && return
  if   (( left >= 86400 )); then REMAINING="$(( left / 86400 ))d $(( left % 86400 / 3600 ))h"
  elif (( left >= 3600 ));  then REMAINING="$(( left / 3600 ))h $(( left % 3600 / 60 ))m"
  elif (( left >= 60 ));    then REMAINING="$(( left / 60 ))m"
  else REMAINING="<1m"; fi
}

rate_segment() {  # label pct resets_at
  [[ -z "$2" || "$2" == null ]] && return
  local pct c
  round_pct "$2"; pct=$ROUNDED
  color_for_pct "$pct"; c=$COLOR
  progress_bar "$pct" "$BAR_WIDTH"
  format_remaining "$3"
  printf "$SEP\e[38;5;245m%s \e[m${c}%s %s%%\e[m" "$1" "$BAR" "$pct"
  [[ -n "$REMAINING" ]] && printf ' \e[38;5;108m↻ %s\e[m' "$REMAINING"
}

# ── Extract session fields (one jq call) ───────────────────────────────────────
IFS=$'\x1f' read -r cwd model_name model_id output_style ctx_pct ctx_size \
  five_pct five_reset week_pct week_reset cost_usd duration_ms < <(
  jq -r '[
    (.cwd // ""), (.model.display_name // ""), (.model.id // ""), (.output_style.name // ""),
    (.context_window.used_percentage // ""), (.context_window.context_window_size // ""),
    (.rate_limits.five_hour.used_percentage // ""), (.rate_limits.five_hour.resets_at // ""),
    (.rate_limits.seven_day.used_percentage // ""), (.rate_limits.seven_day.resets_at // ""),
    (.cost.total_cost_usd // ""), (.cost.total_duration_ms // "")
  ] | map(tostring) | join("\u001f")' <<<"$session" 2>/dev/null
)

[ -z "$cwd" ] && cwd="$(pwd)"
if [ -z "$model_name" ] && [ -n "$model_id" ]; then
  model_name=${model_id#claude-}
  model_name=${model_name%-20[0-9][0-9][0-9][0-9][0-9][0-9]}
fi

# ── Git: branch, dirty, ahead/behind, line counts ──────────────────────────────
git_branch="" git_dirty="" git_ahead="" git_behind="" git_added="" git_removed=""
if git_status=$(git --no-optional-locks -C "$cwd" status --porcelain=v2 --branch 2>/dev/null); then
  oid=""
  while IFS= read -r line; do
    case "$line" in
      "# branch.oid "*)  oid=${line#\# branch.oid } ;;
      "# branch.head "*) git_branch=${line#\# branch.head } ;;
      "# branch.ab "*)
        read -r _ _ ab_ahead ab_behind <<<"$line"
        (( ${ab_ahead#+} > 0 ))  && git_ahead=${ab_ahead#+}
        (( ${ab_behind#-} > 0 )) && git_behind=${ab_behind#-}
        ;;
      "#"*) ;;
      *) git_dirty="●" ;;
    esac
  done <<<"$git_status"
  [ "$git_branch" = "(detached)" ] && git_branch=${oid:0:7}

  # Inserted / deleted line counts (staged + unstaged vs HEAD)
  git_diffstat=$(git --no-optional-locks -C "$cwd" diff --shortstat HEAD 2>/dev/null)
  [[ "$git_diffstat" =~ ([0-9]+)\ insertion ]] && git_added=${BASH_REMATCH[1]}
  [[ "$git_diffstat" =~ ([0-9]+)\ deletion ]]  && git_removed=${BASH_REMATCH[1]}
fi

# ── Format helpers ─────────────────────────────────────────────────────────────
ctx_size_fmt=""
if [[ "$ctx_size" =~ ^[0-9]+ ]]; then
  size=${BASH_REMATCH[0]}
  (( size >= 1000 )) && ctx_size_fmt="$(( size / 1000 ))k" || ctx_size_fmt="$size"
fi

duration_fmt=""
if [[ "$duration_ms" =~ ^[0-9]+ ]]; then
  mins=$(( ${BASH_REMATCH[0]} / 60000 ))
  (( mins >= 60 )) && printf -v duration_fmt '%dh%02dm' $(( mins / 60 )) $(( mins % 60 )) \
                   || duration_fmt="${mins}m"
fi

# ── Render ──────────────────────────────────────────────────────────────────────

# Dimmed spacer between segments
SEP="\e[38;5;240m   \e[m"

# 1. Current dir (bold blue, last 2 components only)
tilde='~'
short_cwd="${cwd/#$HOME/$tilde}"
IFS=/ read -ra parts <<<"$short_cwd"
(( ${#parts[@]} > 2 )) && short_cwd="${parts[-2]}/${parts[-1]}"
printf '\e[1;38;5;75m %s\e[m' "$short_cwd"

# 2. Git branch (+ dirty marker, ahead/behind, line counts)
if [ -n "$git_branch" ]; then
  printf "$SEP\e[38;5;176m %s\e[m" "$git_branch"
  [ -n "$git_dirty" ]   && printf '\e[38;5;221m %s\e[m' "$git_dirty"
  [ -n "$git_ahead" ]   && printf '\e[38;5;114m ↑%s\e[m' "$git_ahead"
  [ -n "$git_behind" ]  && printf '\e[38;5;203m ↓%s\e[m' "$git_behind"
  [ -n "$git_added" ]   && printf '\e[38;5;114m +%s\e[m' "$git_added"
  [ -n "$git_removed" ] && printf '\e[38;5;203m -%s\e[m' "$git_removed"
fi

# 3. Model + context size
if [ -n "$model_name" ]; then
  printf "$SEP\e[38;5;80m✦ %s\e[m" "$model_name"
  [ -n "$ctx_size_fmt" ] && printf '\e[38;5;240m·%s\e[m' "$ctx_size_fmt"
fi

# 3b. Output style (only when non-default)
if [ -n "$output_style" ] && [ "$output_style" != "default" ]; then
  printf "$SEP\e[38;5;245m◈ %s\e[m" "$output_style"
fi

# 4. Context bar (bold red with a warning sign near the limit)
if [ -n "$ctx_pct" ] && [ "$ctx_pct" != "null" ]; then
  round_pct "$ctx_pct"; pct=$ROUNDED
  color_for_pct "$pct"; c=$COLOR
  warn=""
  if (( pct >= CTX_WARN_PCT )); then c='\e[1;38;5;203m'; warn=" ⚠"; fi
  progress_bar "$pct" "$BAR_WIDTH"
  printf "$SEP\e[38;5;245mctx \e[m${c}%s %s%%%s\e[m" "$BAR" "$pct" "$warn"
fi

# 5. 5-hour and 7-day rate bars, with time until reset
rate_segment "5h" "$five_pct" "$five_reset"
rate_segment "7d" "$week_pct" "$week_reset"

# 6. Session duration and cost
if [ -n "$duration_fmt" ] || [ -n "$cost_usd" ]; then
  printf "$SEP\e[38;5;245m"
  [ -n "$duration_fmt" ] && printf '⏱ %s' "$duration_fmt"
  if [[ "$cost_usd" =~ ^[0-9.]+$ ]]; then
    [ -n "$duration_fmt" ] && printf ' '
    printf '$%.2f' "$cost_usd"
  fi
  printf '\e[m'
fi

printf ' '
