# Claude Code status line

    Opus 5.5 xhigh | 5h 6%(3h30m) 7d 38%(3d17h) | ctx 8% | $0.77

`statusline.sh` renders this from the JSON that Claude Code pipes to it. It is
wired up by `statusLine` in `settings.json` (refreshed every 60 s) and makes no
network calls: the rate limits come from the payload's `rate_limits` field,
which Claude Code fills from its own API responses.

| segment | meaning |
|---------|---------|
| `Opus 5.5 xhigh` | model and effort level |
| `5h 6%(3h30m)` | five-hour rate-limit window: percent used, time until it resets |
| `7d 38%(3d17h)` | the same for the seven-day window |
| `ctx 8%` | share of the context window in use |
| `$0.77` | the session's cost at list price, as Claude Code computes it |

The two window percentages are coloured by where they are headed rather than
where they are. The script projects usage at the window's end in a straight
line (used % ÷ fraction of the window elapsed): by default green below 80 %,
yellow below 95 %, red otherwise. They stay uncoloured for the first 10 minutes
of the 5h window and the first 6 hours of the 7d one, while the projection is
noise.

## Settings

Set these in the environment, for example at the start of the `statusLine`
command in `settings.json`:

    "command": "STATUSLINE_SHOW_PROJECTION=on ~/git/claude-config/statusline/statusline.sh"

| variable | default | effect |
|----------|---------|--------|
| `STATUSLINE_SHOW_PROJECTION` | `off` | `on` prints the projection as well: `5h 6%→20%(3h30m)` |
| `STATUSLINE_THRESH_LOW` | `80` | projected % below which a window is green |
| `STATUSLINE_THRESH_HIGH` | `95` | projected % below which it is yellow; at or above, red |
| `STATUSLINE_DRY_RUN` | unset | any value renders without touching the cache (see Testing) |

The thresholds must be whole numbers, such as `75` rather than `75.5`.

## Cost

The dollar figure is Claude Code's own `cost.total_cost_usd`. Summing the
session's transcripts comes out far too low. Every WebSearch and WebFetch call
is a separate API request that never reaches a transcript, and Workflow agents
keep their transcripts a level deeper than the session's subagents. Pricing
the tokens also needs a table that goes stale with every model release.

## Files it writes

Every open session runs the script once a minute, idle or not, so each file
below is written only when its contents change. All are in
`~/.cache/claude-code/`, which the script keeps at mode 0700, and new files
are created 0600, since they hold session titles, working directories and
costs:

| file | contents |
|------|----------|
| `statusline-last.json` | the last input payload, from whichever session refreshed last, for debugging |
| `usage.json` | `updated_at` and `rate_limits` (`five_hour`, `seven_day`: `used_percentage`, `resets_at`), merged across sessions: the source for a desktop widget. Within one window the higher reading wins; a later `resets_at` replaces it, and an earlier one is ignored. Claude Code drops a window from the payload once it resets, so that last rule is only a guard. |
| `sessions/<session_id>.json` | one session's `model`, `effort`, `context_pct` and `cost_usd`, plus `updated_at`, the time they last changed. `cost_usd` keeps the highest value seen, since Claude Code's counter has dropped to $0 mid-session (after `/login`, and when an IDE session restarted). Written only by that session; deleted after two days without a change. |
| `usage-log.tsv` | a row per session whenever a window's used % changes. An idle session's last row lags the others; within one `resets_at` usage only rises, so take the max. |

## Testing

From this directory,

    STATUSLINE_DRY_RUN=1 ./statusline.sh < ~/.cache/claude-code/statusline-last.json

renders against the last real payload without touching any of those files.
Needs bash, jq and awk.
