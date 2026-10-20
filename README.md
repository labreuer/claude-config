# claude-config

Pieces of a [Claude Code](https://code.claude.com/docs) setup. Each directory
is one piece, with its own README.

| directory | what it is |
|-----------|------------|
| [`statusline/`](statusline/) | A status line showing the model, the 5-hour and 7-day rate-limit windows (coloured by where they're headed), context use and session cost. It makes no network calls, and keeps a merged `usage.json` that a desktop widget can read. |

## Using the status line

Point `statusLine` in `~/.claude/settings.json` at the script in your clone:

```json
"statusLine": {
  "type": "command",
  "command": "~/git/claude-config/statusline/statusline.sh",
  "refreshInterval": 60
}
```

`refreshInterval` is optional. Without it the line only updates when something
happens in the session, such as a new reply.

## License

MIT; see [LICENSE](LICENSE).
