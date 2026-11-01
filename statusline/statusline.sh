#!/usr/bin/env bash
# Claude Code status line: "{model} {effort} | 5h … 7d … | ctx … | $…",
# or "{model} {effort} | {7d %} | ctx … | $…" on a plan without a 5h limit
# Reads the session JSON Claude Code pipes to stdin (documented at
# https://code.claude.com/docs/en/statusline.md). Makes no network calls.
# Writes, under $XDG_CACHE_HOME/claude-code/ or else ~/.cache/claude-code/
# (README.md has the details):
#   usage.json                    rate limits merged across sessions, for a widget
#   sessions/<session_id>.json    each session's own figures
# and, with STATUSLINE_WRITE_LOGS=on, two logs:
#   statusline-last.json          the raw input, for debugging
#   usage-log.tsv                 history, appended only when something changed

# ---- configuration --------------------------------------------------------------
# Set these in the environment, e.g. in the statusLine command in settings.json:
#   "command": "STATUSLINE_SHOW_PROJECTION=on ~/git/claude-config/statusline/statusline.sh"
# STATUSLINE_SHOW_PROJECTION: "on"  = show current % and a →NN% projection of usage at window end
#                             "off" = show only the current % (the default)
# Either way the colour reflects the projected end-of-window value (uncoloured
# while a window is too young to project).
# STATUSLINE_THRESH_LOW, STATUSLINE_THRESH_HIGH: colour thresholds in percent,
# 80 and 95 by default: green below LOW, yellow below HIGH, red otherwise. They
# must be whole numbers, since the shell compares them as integers.
# STATUSLINE_WRITE_LOGS: "on" also writes the two logs listed above; "off" (the
# default) leaves them out. usage.json and sessions/ are written either way.
SHOW_PROJECTION=${STATUSLINE_SHOW_PROJECTION:-off}
THRESH_LOW=${STATUSLINE_THRESH_LOW:-80}
THRESH_HIGH=${STATUSLINE_THRESH_HIGH:-95}
WRITE_LOGS=${STATUSLINE_WRITE_LOGS:-off}

# The cache can hold session titles, working directories and costs, so keep it
# private. A umask only applies when a file is created, and usage-log.tsv is
# only ever appended to, so files from before this change keep their old modes.
# Keeping the directory itself at 0700 shuts other users out of them anyway.
umask 077

input=$(cat)
command -v jq >/dev/null || { echo "statusline.sh: jq not found"; exit 0; }
# Honour XDG_CACHE_HOME, but only an absolute path: the XDG spec says to ignore
# a relative one.
case $XDG_CACHE_HOME in
  /*) cache="$XDG_CACHE_HOME/claude-code" ;;
  *) cache="$HOME/.cache/claude-code" ;;
esac
# STATUSLINE_DRY_RUN=1 renders without touching the cache files or logs (for
# testing). It starts from a copy of the real usage.json, because whether the
# plan has a 5h limit is read from there.
if [ -n "$STATUSLINE_DRY_RUN" ]; then
  real_cache=$cache cache=$(mktemp -d) && trap 'rm -rf "$cache"' EXIT
  [ -f "$real_cache/usage.json" ] && cp "$real_cache/usage.json" "$cache/"
fi
mkdir -p "$cache" && chmod 700 "$cache"
[ "$WRITE_LOGS" = on ] && printf '%s' "$input" > "$cache/statusline-last.json"

# ---- fields from the payload (one jq pass) ---------------------------------
# Joined with \x1f, not spaces: read collapses a run of whitespace separators,
# so an empty field would shift every field after it.
IFS=$'\x1f' read -r session_id model effort ctx \
    five five_reset five_row week week_reset week_row cost <<<"$(printf '%s' "$input" | jq -r '
  def pct: if . == null then "-" else (. | floor | tostring) + "%" end;
  # a usage-history row, "window<TAB>used_pct<TAB>resets_at", or "" without data
  def row($w): .rate_limits[$w]
    | if (.used_percentage | type) == "number"
      then "\($w)\t\(.used_percentage * 100 | round / 100)\t\(.resets_at)" else "" end;
  [ .session_id // "",
    .model.display_name // .model.id // "?",
    .effort.level // "-",
    (.context_window.used_percentage | pct),
    (.rate_limits.five_hour.used_percentage | pct),
    .rate_limits.five_hour.resets_at // 0,
    row("five_hour"),
    (.rate_limits.seven_day.used_percentage | pct),
    .rate_limits.seven_day.resets_at // 0,
    row("seven_day"),
    .cost.total_cost_usd // ""
  ] | map(tostring) | join("\u001f")')"

# time until a Unix-epoch reset, as "1h05m" / "3d02h"
time_left() {
  local d=$(( $1 - $(date +%s) ))
  [ "$1" -le 0 ] || [ "$d" -le 0 ] && { echo ""; return; }
  if [ "$d" -ge 86400 ]; then printf '%dd%02dh' $((d/86400)) $((d%86400/3600))
  else printf '%dh%02dm' $((d/3600)) $((d%3600/60)); fi
}

# ---- cache file helpers --------------------------------------------------------
json_object() {  # file -> its JSON object, or {} if it is missing, empty or corrupt
  # Treating a bad file as empty means it gets overwritten instead of failing
  # every run from then on. (For a missing file jq prints {} and still fails,
  # so the fallback replaces its output rather than adding to it.)
  local obj
  obj=$(jq -cs 'if length == 1 and (.[0] | type) == "object" then .[0] else {} end' "$1" 2>/dev/null) \
    || obj='{}'
  printf '%s\n' "$obj"
}
write_json() {  # file < json: replace the file atomically; fails, writing nothing, on empty input
  # Per-process temp name: writers sharing one name can interleave their output.
  local tmp="$1.tmp.$$"
  cat > "$tmp"
  [ -s "$tmp" ] && mv -f "$tmp" "$1" && return 0
  rm -f "$tmp"; return 1
}

# ---- this session's record -----------------------------------------------------
# sessions/<session_id>.json holds this session's own figures. Only this session
# writes it, and only when something in it changed, so updated_at is the time of
# the last change and an idle session leaves it alone. A record unchanged for two
# days is deleted; if that session is still open, its next refresh rewrites it.
# cost_usd is Claude Code's own figure, kept at the highest value seen: its
# counter has dropped to $0 mid-session (after /login, and when an IDE session
# restarted).
sessions="$cache/sessions"
if [ -n "$session_id" ]; then
  mkdir -p "$sessions"
  printf '%s' "$input" | jq -c --argjson prev "$(json_object "$sessions/$session_id.json")" '
    {model: .model.display_name, effort: .effort.level,
     context_pct: .context_window.used_percentage,
     cost_usd: ([.cost.total_cost_usd, $prev.cost_usd] | max)}
    | if . == ($prev | del(.updated_at)) then empty else . + {updated_at: now | floor} end' \
    | write_json "$sessions/$session_id.json"
fi
# Also sweep up temp files left by a run that was killed mid-write.
find "$cache" -maxdepth 2 \( -path "$sessions/*.json" -o -name '*.json.tmp.*' \) -mtime +1 -delete 2>/dev/null

# ---- usage.json: rate limits for a widget ----------------------------------------
# Other sessions write this file too. Within one block (same resets_at) usage
# only rises, so keep whichever snapshot is higher. A later resets_at starts a
# new block and replaces. An earlier one is ignored, in case a session reports
# a block that has already reset; current Claude Code drops a window from the
# payload once it resets, so this is only a guard. The file is rewritten only
# when the merged limits change, so updated_at is the time of the last change.
#
# Some plans have no 5h limit, and the API then reports the 7d window alone.
# A payload without five_hour can't show that by itself, since Claude Code also
# drops the window once its block ends, until a request starts the next one.
# But on a plan with a 5h limit every response carries both windows, so the
# merged limits can't change after a 5h block ends without a new block coming
# too. When they do (updated_at past that block's resets_at) the response had
# no 5h window, and five_hour is dropped from usage.json. Five minutes' grace
# covers a reading taken just before the block ended but merged just after.
printf '%s' "$input" | jq -c --argjson old "$(json_object "$cache/usage.json")" '
  def fresher($w): (.rate_limits[$w]) as $n | ($old.rate_limits[$w]) as $o
    | if $n == null then $o
      elif $o == null or $n.resets_at > $o.resets_at then $n
      elif $n.resets_at < $o.resets_at then $o
      elif $o.used_percentage > $n.used_percentage then $o else $n end;
  ($old.rate_limits // {}) as $prev
  | {five_hour: fresher("five_hour"), seven_day: fresher("seven_day")} | with_entries(select(.value != null))
  | (if . == $prev then $old.updated_at else now | floor end) as $changed
  | if .five_hour and .five_hour.resets_at + 300 < $changed then del(.five_hour) else . end
  | if . == $prev then empty else {updated_at: now | floor, rate_limits: .} end' \
  | write_json "$cache/usage.json"

# ---- usage history -------------------------------------------------------------
# With STATUSLINE_WRITE_LOGS=on, append a row whenever a window's figures change
# for THIS session:
#   ts<TAB>session_id<TAB>window<TAB>used_pct<TAB>resets_at
# Each session logs the reading from its own latest API response, so an idle
# session's last row lags the others. Within one resets_at usage only rises, so
# consumers should take the max per resets_at and time bucket.
if [ "$WRITE_LOGS" = on ]; then
  ulog="$cache/usage-log.tsv"
  [ -f "$ulog" ] || printf 'ts\tsession_id\twindow\tused_pct\tresets_at\n' > "$ulog"
  for row in "$five_row" "$week_row"; do
    [ -z "$row" ] && continue
    w=${row%%$'\t'*}
    last=$(awk -F'\t' -v s="$session_id" -v w="$w" \
      '$2 == s && $3 == w { r = $3 FS $4 FS $5 } END { print r }' "$ulog")
    [ "$row" != "$last" ] && printf '%s\t%s\t%s\n' "$(date +%s)" "$session_id" "$row" >> "$ulog"
  done
fi

# ---- projected usage at window end -------------------------------------------
# Extrapolate linearly from the fraction of the window elapsed so far, taking
# window start = resets_at - window length. Colour: green below THRESH_LOW,
# yellow below THRESH_HIGH, red otherwise.
GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
project_pct() {  # used_pct resets_at window_seconds min_elapsed_seconds -> integer projected % at window end, or ""
  local used=$1 reset=$2 win=$3 min=$4 now elapsed
  [ "$used" = "-" ] || [ "$reset" -le 0 ] && { echo ""; return; }
  now=$(date +%s); elapsed=$(( now - (reset - win) ))
  [ "$elapsed" -lt "$min" ] && { echo ""; return; }
  awk -v u="${used%\%}" -v e="$elapsed" -v w="$win" 'BEGIN{printf "%d", u*w/e}'
}
colour_for() {  # integer percent -> ANSI colour code
  if [ "$1" -lt "$THRESH_LOW" ]; then printf '%s' "$GREEN"
  elif [ "$1" -lt "$THRESH_HIGH" ]; then printf '%s' "$YELLOW"
  else printf '%s' "$RED"; fi
}
window_usage() {  # used_pct resets_at window_seconds min_elapsed -> rendered "NN%[→PP%]"
  # The colour always reflects the projected end-of-window value; "on" also prints it.
  local used=$1 proj col
  [ "$used" = "-" ] && { printf -- '-'; return; }
  proj=$(project_pct "$@")
  col=""; [ -n "$proj" ] && col=$(colour_for "$proj")
  if [ "$SHOW_PROJECTION" = on ]; then
    printf '%s%s→%s%s' "$used" "$col" "${proj:-?}${proj:+%}" "$RESET"
  else
    printf '%s%s%s' "$col" "$used" "$RESET"
  fi
}

# ---- render -------------------------------------------------------------------
# Without a Pro or Max plan (an API key, Bedrock, Vertex) there is no
# rate_limits, so both windows show "-". Most organisations want token spending
# kept down, so a natural replacement there is a spending target: a daily or
# weekly budget set in the environment and coloured with the same thresholds.
# sessions/*.json has each session's cost, but summing them needs care: records
# last two days, and a continued session's cost already includes its parent's.
# Behind a Claude apps gateway with a spend limit, Claude Code already sends
# rate_limits.spend_limit (used_percentage, resets_at), which could be shown
# like a third window.
week_usage=$(window_usage "$week" "$week_reset" $((7*86400)) $((6*3600)))
# No 5h limit (usage.json has a 7d window but no 5h one; see above): only the
# 7d %, with no "7d" label and no time left.
if [ "$five" = "-" ] && jq -e '.rate_limits | has("seven_day") and (has("five_hour") | not)' \
     "$cache/usage.json" >/dev/null 2>&1; then
  usage=$week_usage
else
  usage="5h $(window_usage "$five" "$five_reset" $((5*3600)) 600)"
  r=$(time_left "$five_reset"); [ -n "$r" ] && usage="$usage($r)"
  usage="$usage 7d $week_usage"
  r=$(time_left "$week_reset"); [ -n "$r" ] && usage="$usage($r)"
fi
usage="$usage | ctx $ctx"
[ -n "$cost" ] && usage="$usage | \$$(awk -v c="$cost" 'BEGIN{printf "%.2f", c}')"

printf '%s %s | %s\n' "$model" "$effort" "$usage"
