# claude-bridge

Expose a [Claude Code](https://docs.anthropic.com/en/docs/claude-code) subscription as
structured HTTP sessions that any client can drive.

claude-bridge is a small Swift [Hummingbird](https://github.com/hummingbird-project/hummingbird)
server that runs the `claude` CLI headlessly — one
`claude -p --output-format stream-json --include-partial-messages` process per turn — and turns
its stream-JSON output into clean REST + SSE: persistent multi-session chat, token-by-token
streaming, structured tool calls, reasoning blocks, per-turn cost/token accounting, session
resume, clear, and fork.

It also serves the parts of a Claude Code session that aren't messages: the subagents a turn
spawned and their own transcripts, context compactions as events rather than a wall of summary
text, the attachments a prompt carried, plan rate-limit gauges, the slash commands that machine
will actually resolve, `/goal` state — and, with an APNs key configured, Live Activity and
turn-end pushes so a phone can watch a turn it isn't looking at.

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
| GET | `/sessions` | — | `[SessionSummary]`, newest first, store + discovered transcripts merged |
| POST | `/sessions` | `{title?, model?, effort?}` | the created `Session` |
| GET | `/sessions/:id` | — | `Session` (404 if unknown), including the turn in flight |
| PATCH | `/sessions/:id` | `{title}` | the renamed `Session` |
| DELETE | `/sessions/:id` | — | `{"ok": true}` |
| POST | `/sessions/:id/message` | `{text, model?, effort?, attachments?}` | `202 {"ok": true}`; the turn runs async, watch `/events`. `409` when the session is already being written by a turn on the machine itself |
| POST | `/sessions/:id/abort` | — | `{"ok": true}`; stops the turn in flight |
| POST | `/sessions/:id/clear` | — | `{"ok": true}`; drops history and the resumable Claude session id |
| POST | `/sessions/:id/fork` | — | new `Session` (404 if unknown) seeded with the source's history; its first turn runs `--fork-session` so it diverges instead of mutating the parent |
| GET | `/sessions/:id/events` | — | `text/event-stream` of bridge events (below) |
| GET | `/sessions/:id/usage` | — | `{costUSD?, tokens?}` for the session's last turn |
| GET | `/sessions/:id/agents` | — | `[SubagentSummary]` — the subagents this session spawned |
| GET | `/sessions/:id/agents/:agentID` | — | `SubagentTranscript` — that subagent's own messages |
| GET | `/commands` | `?directory=` | `[AgentCommand]` — slash commands a headless turn will resolve |
| GET | `/usage` | — | Claude plan rate-limit gauges (session / week / Opus) read from the CLI's own accounting |
| GET | `/usage/grok` | — | Grok quota gauges, when a Grok key is configured |
| GET | `/files` | `?path=` | `[FileNode]` — directory listing for the project picker |
| GET | `/files/content` | `?path=` | `{path, content}` |
| GET | `/attachments/:session/:name` | — | the bytes a prompt carried, served back with its MIME type |
| POST | `/sessions/:id/live-activity` | `LiveActivityRegistration` | registers an ActivityKit push token for this session |
| POST | `/push/device` | `{token, environment}` | registers a device token for turn-end pushes (requires `BRIDGE_PASSWORD`) |
| POST | `/push/device/unregister` | `{token}` | forgets it |

`Session`: `{id, title, claudeSessionID?, model, effort, createdAt, updatedAt, messages,
lastCostUSD?, lastTokens?, goal?}`. `Message`: `{id, role: "user"|"assistant", parts, createdAt}`.
`Part` is `{kind: "text"|"reasoning", text}`, `{kind: "tool", tool: ToolCall}`,
`{kind: "file", file: FileRef}` or `{kind: "compaction", compaction: Compaction}`.
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
| `goal` | `goal?` | The session's `/goal` changed; the field is absent once nothing is being pursued |
| `compaction` | `compaction` | The context was compacted: tokens before/after, duration, how many messages carried over, and the CLI's summary |
| `error` | `error` | Turn-level failure (e.g. the `claude` binary could not be launched) |

A subscriber gets a `status` frame immediately on connect, so a client that attaches mid-turn
knows the session is running without waiting for the next token.

## Commands and goals

`GET /commands` lists what a `claude -p` turn will actually resolve: the built-ins worth running
from a client (`goal`, `recap`, `compact`, `context`, `usage`, `init`, `review` — the CLI's other
commands either need an interactive terminal or duplicate controls a client already has), plus
every command file on the machine — `~/.claude/commands`, `<directory>/.claude/commands`, and each
installed plugin's, namespaced `plugin:command`. `AgentCommand`:
`{name, description, argumentHint?, source: "builtin"|"user"|"project"|"plugin", scope?}`.
Running one is just sending `/name args` as a message; there is no separate route.

`/goal <condition>` makes the agent keep working until the condition holds, which is the one piece
of state worth setting from a phone and then walking away from. The CLI records it in the
transcript as `goal_status` attachments, so the bridge reads goal state from the same incremental
fold that serves messages and reports it as `Session.goal`, as a `goal` SSE event when it changes,
and in the turn-end push (`Goal reached: …` rather than `Done in 2m · 6 tools`). A goal survives
the bridge respawning `claude -p --resume` per message: the CLI restores it from the last
`goal_status` record unless that record is met or failed.
`GoalStatus`: `{condition, met, failed?, reason?, iterations?, durationMs?, tokens?, updatedAt?}`.

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
| `BRIDGE_APNS_KEY` | empty | Path to an APNs `.p8` auth key. Set all four `BRIDGE_APNS_*` values to enable Live Activity and turn-end pushes; leave them empty and the bridge simply never pushes |
| `BRIDGE_APNS_KEY_ID` | empty | Key id of that `.p8` |
| `BRIDGE_APNS_TEAM_ID` | empty | Apple developer team id |
| `BRIDGE_APNS_TOPIC` | `com.guitaripod.tailscode.push-type.liveactivity` | Live Activity push topic; set it to your own bundle id + `.push-type.liveactivity` if you ship a different client |

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

GPL-3.0. Copyright (c) 2026 Midgar Oy. See [LICENSE](LICENSE).
