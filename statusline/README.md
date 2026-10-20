# Claude Code status line

    Opus 5.5 xhigh | 5h 6%(3h30m) 7d 38%(3d17h) | ctx 8% | Σ192keq $0.77

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
| `Σ192keq $0.77` | this session's price-weighted tokens and their list-price cost; subagents add `+NNksub` after `eq` |

The two window percentages are coloured by where they are headed rather than
where they are. The script projects usage at the window's end in a straight
line (used % ÷ fraction of the window elapsed): green below 80 %, yellow below
95 %, red otherwise. They stay uncoloured for the first 10 minutes of the 5h
window and the first 6 hours of the 7d one, while the projection is noise.
`SHOW_PROJECTION=on` at the top of the script prints the projection as well:
`5h 6%→20%(3h30m)`.

## Token weighting

`statusline-tokens.jq` sums `message.usage` over the session transcript and its
subagent transcripts, counting each `requestId` once (the transcript repeats an
assistant record for every content block). Each token category is priced from
the table at the top of the file, and the total is divided by the current
model's input price, giving "input-equivalent tokens": cache reads count for
little and output for a lot. A model missing from the table is priced as
Fable 5.1, so add a row (\$/MTok for input, output, 5-minute cache write,
1-hour cache write, cache read) when a new one ships.

The dollar figure matches Claude Code's own `cost.total_cost_usd`, except for
side requests (session titles, WebFetch summaries) that never reach the
transcript.

## Files it writes

Every open session runs the script once a minute, idle or not, so each file
below is written only when its contents change. All are in
`~/.cache/claude-code/`:

| file | contents |
|------|----------|
| `statusline-last.json` | the last input payload, from whichever session refreshed last, for debugging |
| `usage.json` | `updated_at` and `rate_limits` (`five_hour`, `seven_day`: `used_percentage`, `resets_at`), merged across sessions: the source for a desktop widget. Within one window the higher reading wins; a later `resets_at` replaces it, and an earlier one, from an idle session that hasn't seen the reset, is ignored. |
| `sessions/<session_id>.json` | one session's `model`, `effort`, `context_pct`, `claude_code_cost_usd` and `session_tokens` (`main` and `subagents`: `requests`, `raw`, `input_equivalent`, `usd`), plus `updated_at`, the time they last changed. Written only by that session; deleted after two days without a change. |
| `usage-log.tsv` | a row per session whenever a window's used % changes. Idle sessions repeat stale readings, so take the max per `resets_at`. |
| `cost-log.tsv` | a row whenever one of a session's cost figures changes, `ts session_id requests main_usd sub_usd claude_code_usd`, comparing this script's cost with Claude Code's. No header, never trimmed. |

## Testing

    STATUSLINE_DRY_RUN=1 ~/.claude/statusline.sh < ~/.cache/claude-code/statusline-last.json

renders against the last real payload without touching any of those files.
Needs bash, jq, awk and GNU grep (`-P`).
