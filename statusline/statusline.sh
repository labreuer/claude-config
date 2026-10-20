#!/usr/bin/env bash
# Claude Code status line: "{model} {effort} | 5h … 7d … | ctx … | Σ…eq $…"
# Reads the session JSON Claude Code pipes to stdin (documented at
# https://code.claude.com/docs/en/statusline.md). Makes no network calls.
# Writes, under ~/.cache/claude-code/ (README.md has the details):
#   statusline-last.json          the raw input, for debugging
#   usage.json                    rate limits merged across sessions, for a widget
#   sessions/<session_id>.json    each session's own figures
#   usage-log.tsv, cost-log.tsv   history, appended only when something changed

# ---- configuration --------------------------------------------------------------
# SHOW_PROJECTION: "on"  = show current % and a →NN% projection of usage at window end
#                  "off" = show only the current %
# Either way the colour reflects the projected end-of-window value (uncoloured
# while a window is too young to project).
# Colour thresholds (percent): green below LOW, yellow below HIGH, red otherwise.
SHOW_PROJECTION=off
THRESH_LOW=80
THRESH_HIGH=95

input=$(cat)
cache="$HOME/.cache/claude-code"
# STATUSLINE_DRY_RUN=1 renders without touching the cache files or logs (for testing)
[ -n "$STATUSLINE_DRY_RUN" ] && cache=$(mktemp -d) && trap 'rm -rf "$cache"' EXIT
mkdir -p "$cache"
printf '%s' "$input" > "$cache/statusline-last.json"

# ---- fields from the payload (one jq pass) ---------------------------------
# Joined with \x1f, not spaces: read collapses a run of whitespace separators,
# so an empty field would shift every field after it.
IFS=$'\x1f' read -r transcript session_id model model_id effort ctx \
    five five_reset five_row week week_reset week_row cc_usd <<<"$(printf '%s' "$input" | jq -r '
  def pct: if . == null then "-" else (. | floor | tostring) + "%" end;
  # a usage-history row, "window<TAB>used_pct<TAB>resets_at", or "" without data
  def row($w): .rate_limits[$w]
    | if (.used_percentage | type) == "number"
      then "\($w)\t\(.used_percentage * 100 | round / 100)\t\(.resets_at)" else "" end;
  [ .transcript_path // "",
    .session_id // "",
    .model.display_name // .model.id // "?",
    .model.id // "claude-fable-5-1",
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

# ---- tokens used by this session (main + subagents) -------------------------
# statusline-tokens.jq dedupes assistant records by requestId (the transcript
# repeats one per content block), prices each token category at its model's
# list price, and divides by the input price of this session's model (the
# anchor). The result is one number in "input-equivalent tokens", plus the same
# thing in dollars. With Fable 5.1 as the anchor, for example, output counts 5x,
# a cache write 1.25x (5m) or 2x (1h), and a cache read 0.025x.
fmt_tok() {  # 1234567 -> 1.2M, 424000 -> 424k
  local n=${1%.*}
  if [ "$n" -ge 1000000 ]; then awk -v n="$n" 'BEGIN{printf "%.1fM", n/1e6}'
  elif [ "$n" -ge 1000 ]; then printf '%dk' $((n/1000))
  else printf '%d' "$n"; fi
}
sum_tokens() {  # files... -> "requests raw_tokens eq_tokens usd"
  # Only assistant records carry usage. Claude Code writes one compact JSON
  # object per line, so grep can drop the rest before jq parses anything, which
  # cuts jq's time on a 153 MB transcript from 1 s to 0.04 s. jq still checks
  # .type, so a stray match elsewhere in a line does no harm.
  grep -hE '"type": *"assistant"' "$@" 2>/dev/null \
    | jq -nR -r --arg anchor "$model_id" -f "$HOME/.claude/statusline-tokens.jq" 2>/dev/null
}
tokens=""; main_reqs=0; main_raw=0; main_eq=0; main_usd=0; sub_reqs=0; sub_raw=0; sub_eq=0; sub_usd=0
if [ -r "$transcript" ]; then
  read -r main_reqs main_raw main_eq main_usd <<<"$(sum_tokens "$transcript")"
  sub_dir="$(dirname "$transcript")/$session_id/subagents"
  if compgen -G "$sub_dir/*.jsonl" >/dev/null; then
    read -r sub_reqs sub_raw sub_eq sub_usd <<<"$(sum_tokens "$sub_dir"/*.jsonl)"
  fi
  total_usd=$(awk -v a="${main_usd:-0}" -v b="${sub_usd:-0}" 'BEGIN{printf "%.2f", a+b}')
  tokens="Σ$(fmt_tok "${main_eq:-0}")eq"
  [ "${sub_eq:-0}" -gt 0 ] && tokens="$tokens+$(fmt_tok "$sub_eq")sub"
  tokens="$tokens \$$total_usd"
fi

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
sessions="$cache/sessions"
if [ -n "$session_id" ]; then
  mkdir -p "$sessions"
  prev=$(json_object "$sessions/$session_id.json")
  if printf '%s' "$input" | jq -c --argjson prev "$prev" \
       --argjson mq "${main_reqs:-0}" --argjson mr "${main_raw:-0}" --argjson me "${main_eq:-0}" --argjson mu "${main_usd:-0}" \
       --argjson sq "${sub_reqs:-0}"  --argjson sr "${sub_raw:-0}"  --argjson se "${sub_eq:-0}"  --argjson su "${sub_usd:-0}" '
       {model: .model.display_name, effort: .effort.level,
        context_pct: .context_window.used_percentage,
        claude_code_cost_usd: .cost.total_cost_usd,
        session_tokens: {main:      {requests: $mq, raw: $mr, input_equivalent: $me, usd: $mu},
                         subagents: {requests: $sq, raw: $sr, input_equivalent: $se, usd: $su}}}
       | if . == ($prev | del(.updated_at)) then empty else . + {updated_at: now | floor} end' \
     | write_json "$sessions/$session_id.json"; then
    # cost-log: compare our estimate with Claude Code's own (for calibration).
    # The record also changes when only context_pct moves, so log just the
    # changes to these figures. jq prints a stored number exactly as it was
    # written, so the string comparison is exact.
    cost_row=$(printf '%s\t%s\t%s\t%s' "${main_reqs:-0}" "${main_usd:-0}" "${sub_usd:-0}" "$cc_usd")
    prev_row=$(jq -r '[.session_tokens.main.requests, .session_tokens.main.usd,
                        .session_tokens.subagents.usd, .claude_code_cost_usd]
                      | map(. // "" | tostring) | join("\t")' <<<"$prev")
    [ -r "$transcript" ] && [ -n "$cc_usd" ] && [ "$cost_row" != "$prev_row" ] \
      && printf '%s\t%s\t%s\n' "$(date +%s)" "$session_id" "$cost_row" >> "$cache/cost-log.tsv"
  fi
fi
# Also sweep up temp files left by a run that was killed mid-write.
find "$cache" -maxdepth 2 \( -path "$sessions/*.json" -o -name '*.json.tmp.*' \) -mtime +1 -delete 2>/dev/null

# ---- usage.json: rate limits for a widget ----------------------------------------
# Other sessions write this file too. Within one block (same resets_at) usage
# only rises, so keep whichever snapshot is higher. A later resets_at starts a
# new block and replaces; an earlier one is ignored, since idle sessions keep
# reporting the block they last saw long after it has reset. The file is
# rewritten only when the merged limits change, so updated_at is the time of the
# last change.
printf '%s' "$input" | jq -c --argjson old "$(json_object "$cache/usage.json")" '
  def fresher($w): (.rate_limits[$w]) as $n | ($old.rate_limits[$w]) as $o
    | if $n == null then $o
      elif $o == null or $n.resets_at > $o.resets_at then $n
      elif $n.resets_at < $o.resets_at then $o
      elif $o.used_percentage > $n.used_percentage then $o else $n end;
  ({five_hour: fresher("five_hour"), seven_day: fresher("seven_day")} | with_entries(select(.value != null))) as $limits
  | if $limits == ($old.rate_limits // {}) then empty
    else {updated_at: now | floor, rate_limits: $limits} end' \
  | write_json "$cache/usage.json"

# ---- usage history -------------------------------------------------------------
# Append a row whenever a window's figures change for THIS session:
#   ts<TAB>session_id<TAB>window<TAB>used_pct<TAB>resets_at
# Several sessions may run this script; an idle one keeps reporting a stale
# snapshot, so consumers should take, per resets_at and time bucket, the max.
ulog="$cache/usage-log.tsv"
[ -f "$ulog" ] || printf 'ts\tsession_id\twindow\tused_pct\tresets_at\n' > "$ulog"
for row in "$five_row" "$week_row"; do
  [ -z "$row" ] && continue
  w=${row%%$'\t'*}
  last=$(grep -P "^\d+\t\Q$session_id\E\t$w\t" "$ulog" | tail -1 | cut -f3-)
  [ "$row" != "$last" ] && printf '%s\t%s\t%s\n' "$(date +%s)" "$session_id" "$row" >> "$ulog"
done

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
usage="5h $(window_usage "$five" "$five_reset" $((5*3600)) 600)"
r=$(time_left "$five_reset"); [ -n "$r" ] && usage="$usage($r)"
usage="$usage 7d $(window_usage "$week" "$week_reset" $((7*86400)) $((6*3600)))"
r=$(time_left "$week_reset"); [ -n "$r" ] && usage="$usage($r)"
usage="$usage | ctx $ctx"
[ -n "$tokens" ] && usage="$usage | $tokens"

printf '%s %s | %s\n' "$model" "$effort" "$usage"
