# claude-bridge

Expose a [Claude Code](https://docs.anthropic.com/en/docs/claude-code) subscription as
structured HTTP sessions that any client can drive.

claude-bridge is a small Swift [Hummingbird](https://github.com/hummingbird-project/hummingbird)
server that runs the `claude` CLI headlessly — one
`claude -p --output-format stream-json --include-partial-messages` process per turn — and turns
its stream-JSON output into clean REST + SSE: persistent multi-session chat, token-by-token
streaming, structured tool calls, reasoning blocks, per-turn cost/token accounting, session
resume, clear, and fork.

It uses the logged-in CLI (your Claude subscription), not an API key.

Known consumers:

- [Tailscode](https://github.com/guitaripod/Tailscode) — native iOS client, drives the bridge over Tailscale.
- [CodingAgentKit](https://github.com/guitaripod/CodingAgentKit) — Swift package whose `ClaudeSDKBackend` speaks this protocol.

## Requirements

- Swift 6 toolchain (macOS 14+ or Linux).
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and logged in
  (`claude` must work interactively for the user running the bridge).

## Quickstart

```sh
git clone https://github.com/guitaripod/claude-bridge
cd claude-bridge
swift build -c release

BRIDGE_PASSWORD=change-me .build/release/claude-bridge
```

The server listens on `127.0.0.1:4098` by default. Try it:

```sh
curl -u claude:change-me http://127.0.0.1:4098/health
curl -u claude:change-me -X POST http://127.0.0.1:4098/sessions -d '{}'
curl -u claude:change-me -N http://127.0.0.1:4098/sessions/<id>/events &
curl -u claude:change-me -X POST http://127.0.0.1:4098/sessions/<id>/message \
  -d '{"text": "hello"}'
```

## Endpoints

All request/response bodies are JSON. When `BRIDGE_PASSWORD` is set, every route (including
`/health`) requires HTTP Basic auth with username `claude`.

| Method | Path | Body | Response |
|---|---|---|---|
| GET | `/health` | — | `ok` |
| GET | `/status` | — | `{"agent": "claude", "model": "<default model>"}` |
| GET | `/sessions` | — | `[SessionSummary]`, newest first |
| POST | `/sessions` | `{title?, model?, effort?}` | the created `Session` |
| GET | `/sessions/:id` | — | `Session` (404 if unknown) |
| DELETE | `/sessions/:id` | — | `{"ok": true}` |
| POST | `/sessions/:id/message` | `{text, model?, effort?}` | `202 {"ok": true}`; the turn runs async, watch `/events` |
| POST | `/sessions/:id/clear` | — | `{"ok": true}`; drops history and the resumable Claude session id |
| POST | `/sessions/:id/fork` | — | new `Session` (404 if unknown) seeded with the source's history; its first turn runs `--fork-session` so it diverges instead of mutating the parent |
| GET | `/sessions/:id/events` | — | `text/event-stream` of bridge events (below) |

`Session`: `{id, title, claudeSessionID?, model, effort, createdAt, updatedAt, messages,
lastCostUSD?, lastTokens?}`. `Message`: `{id, role: "user"|"assistant", parts, createdAt}`.
`Part` is `{kind: "text"|"reasoning", text}` or `{kind: "tool", tool: ToolCall}`.
`ToolCall`: `{id, name, input, output?, status: "running"|"completed"|"error"}`.
Dates are ISO 8601. Sessions persist to `BRIDGE_STORE` across restarts.

## Transcript discovery

The bridge also surfaces every local Claude Code CLI session as a first-class bridge session —
the CLI's transcripts under `~/.claude/projects` (override with `BRIDGE_PROJECTS`) are the
single source of truth. `GET /sessions` merges them into the list (newest first),
`GET /sessions/:id` parses the transcript into the message model above, and the first write
(`message`, `fork`, `clear`) adopts the transcript into the store and resumes the underlying
Claude session — a chat started in the terminal continues seamlessly from any client, in the
project directory it was started in. `DELETE` on a discovered session hides it from the list
(persisted next to `BRIDGE_STORE`) without touching the transcript on disk. Discovery is
incremental: files are re-parsed only when their mtime/size changes.

## SSE events

Each event is one `data: <json>\n\n` frame:

| `type` | Fields | Meaning |
|---|---|---|
| `message` | `message` | Full message upsert — the user's message echoed back, the empty assistant message that opens a turn, and the final assembled assistant message (reasoning + tool + text parts) that closes it |
| `delta` | `messageID`, `delta` | Incremental assistant text chunk; append to the message's text |
| `tool` | `messageID`, `tool` | Tool call upsert — first with `status: "running"`, again with `output` and `completed`/`error` |
| `status` | `status` | `"running"` when a turn starts, `"idle"` when it ends |
| `error` | `error` | Turn-level failure (e.g. the `claude` binary could not be launched) |

## Configuration

Everything is environment variables. Empty values fall back to the default.

| Variable | Default | Meaning |
|---|---|---|
| `BRIDGE_PORT` | `4098` | Listen port |
| `BRIDGE_BIND` | `127.0.0.1` | Bind address. Set `BRIDGE_BIND=0.0.0.0` only when the machine sits behind Tailscale (or an equivalent private overlay) so tailnet clients can reach it |
| `BRIDGE_PASSWORD` | empty | HTTP Basic auth password (username `claude`). Required unless `BRIDGE_PERMISSION` is changed off `bypassPermissions` — see Security |
| `BRIDGE_PERMISSION` | `bypassPermissions` | Claude `--permission-mode`. `bypassPermissions` also passes `--dangerously-skip-permissions` |
| `BRIDGE_WORKDIR` | `~/agentapi-workdir` | Working directory Claude runs in (created if missing, also passed as `--add-dir`) |
| `BRIDGE_CLAUDE` | `~/.local/bin/claude` | Path to the `claude` binary |
| `BRIDGE_MODEL` | `sonnet` | Default model for new sessions (overridable per session and per message) |
| `BRIDGE_EFFORT` | `medium` | Default reasoning effort (overridable per session and per message) |
| `BRIDGE_STORE` | `~/.claude-bridge/sessions.json` | Session persistence file |
| `BRIDGE_PROJECTS` | `~/.claude/projects` | Claude Code CLI transcript root scanned for discoverable sessions |

## Security

Read this before deploying.

**What `bypassPermissions` means.** By default the bridge runs Claude with
`--permission-mode bypassPermissions --dangerously-skip-permissions`. Claude executes any tool
call — shell commands, file reads and writes, network access — without asking. Anyone who can
send a message to this server can run arbitrary commands as the user the bridge runs as. That
is the point of the tool (an unattended agent has nobody to answer permission prompts), but it
makes the HTTP surface equivalent to remote shell access.

**Fail-closed startup.** Because of the above, the server refuses to start when
`BRIDGE_PASSWORD` is empty while `BRIDGE_PERMISSION` is `bypassPermissions`. Either set a
password or set `BRIDGE_PERMISSION=default`.

**Deploy behind Tailscale only.** The default bind is `127.0.0.1`, which is only useful for
local experiments. The intended deployment is a machine on a
[Tailscale](https://tailscale.com) tailnet with `BRIDGE_BIND=0.0.0.0`, so that reachability is
gated by tailnet membership (WireGuard) and Basic auth is the second layer, not the only one.

**Never expose this server to the public internet.** Do not port-forward it, do not put it
behind a public reverse proxy, do not run it on a cloud box with an open firewall. Basic auth
over plain HTTP is not a sufficient boundary for something that executes shell commands.

## Running as a service (systemd)

See [examples/claude-bridge.service](examples/claude-bridge.service) for a systemd user unit.

```sh
mkdir -p ~/.config/systemd/user
cp examples/claude-bridge.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now claude-bridge
loginctl enable-linger "$USER"
```

`enable-linger` keeps the user service running across reboots without a login session. On
macOS, use a `launchd` LaunchAgent with the same environment variables instead.

## License

GPL-3.0. Copyright (c) 2026 Marcus Ziadé. See [LICENSE](LICENSE).
