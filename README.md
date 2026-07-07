# claude-bridge

A thin HTTP/SSE bridge that drives the `claude` CLI in headless streaming-JSON mode
(`claude -p --output-format stream-json --include-partial-messages`) and exposes clean,
structured sessions to the Tailscode iOS app over Tailscale.

Uses your Claude subscription (the logged-in CLI), not an API key. Replaces the
agentapi TUI-scraping approach with real sessions (`--resume`), token streaming,
structured tool calls, and proper multi-chat / clear semantics.

## Endpoints
- `GET /health`, `GET /status`
- `GET/POST /sessions`, `GET/DELETE /sessions/:id`
- `POST /sessions/:id/message` `{text, model?, effort?}`
- `GET /sessions/:id/events` (SSE)

## Config (env)
`BRIDGE_PORT` (4098), `BRIDGE_PASSWORD`, `BRIDGE_WORKDIR`, `BRIDGE_CLAUDE`,
`BRIDGE_MODEL` (sonnet), `BRIDGE_EFFORT` (medium), `BRIDGE_STORE`.
