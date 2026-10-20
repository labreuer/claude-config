# Sum a Claude Code transcript's token usage, weighted by list price so that
# input, output, cache writes (5m / 1h) and cache reads land in one unit:
# "input-equivalent tokens" = dollars / (base input $/M of the anchor model).
# Usage: jq -nR -r -f statusline-tokens.jq [--arg anchor MODEL] transcript.jsonl...
# Output: one line "requests raw_tokens eq_tokens usd"
# Input is read as raw lines and a line that doesn't parse is skipped, so a
# half-written last line costs one record instead of the whole sum.

# $/MTok: [input, output, cache_write_5m, cache_write_1h, cache_read]
def prices:
  { "claude-fable-5-1": [10, 50, 12.5, 20, 0.25],
    "claude-mythos-5-1":[10, 50, 12.5, 20, 0.25],
    "claude-fable-5":   [10, 50, 12.5, 20, 1.0],
    "claude-opus-5-5":  [4, 20, 5, 8, 0.2],
    "claude-opus-5":    [5, 25, 6.25, 10, 0.5],
    "claude-opus-4-8":  [5, 25, 6.25, 10, 0.5],
    "claude-opus-4-7":  [5, 25, 6.25, 10, 0.5],
    "claude-opus-4-6":  [5, 25, 6.25, 10, 0.5],
    "claude-sonnet-5":  [2, 10, 2.5, 4, 0.2],
    "claude-sonnet-4-6":[3, 15, 3.75, 6, 0.3],
    "claude-haiku-4-5": [1, 5, 1.25, 2, 0.1] };

def price_for($m):
  (prices | to_entries | map(.key as $k | select($m | startswith($k))) | sort_by(-(.key|length)) | .[0].value)
  // prices["claude-fable-5-1"];

def usd:  # one usage record -> dollars
  .u as $u | price_for(.m) as $p
  | ($u.cache_creation.ephemeral_1h_input_tokens // 0) as $w1h
  | (($u.cache_creation.ephemeral_5m_input_tokens // ($u.cache_creation_input_tokens // 0) - $w1h)) as $w5m
  | ( ($u.input_tokens // 0) * $p[0]
    + ($u.output_tokens // 0) * $p[1]
    + $w5m * $p[2] + $w1h * $p[3]
    + ($u.cache_read_input_tokens // 0) * $p[4] ) / 1e6;

def raw: .u | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0) + (.output_tokens // 0);

[ inputs | fromjson? | select(.type=="assistant" and .message.usage) | {r:.requestId, m:(.message.model // ""), u:.message.usage} ]
| unique_by(.r)
| (map(usd) | add // 0) as $usd
| (price_for($anchor)[0]) as $base
| "\(length) \(map(raw) | add // 0) \(($usd / $base * 1e6) | floor) \($usd)"
