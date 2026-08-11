# claude-bridge

Expose a [Claude Code](https://docs.anthropic.com/en/docs/claude-code) subscription as
structured HTTP sessions that any client can drive.

claude-bridge is a small Swift [Hummingbird](https://github.com/hummingbird-project/hummingbird)
server that runs the `claude` CLI headlessly — one
`claude -p --output-format stream-json --include-partial-messages` process per turn — and turns
its stream-JSON output into clean REST + SSE: persistent multi-session chat, token-by-token
streaming, structured tool calls, reasoning blocks, session resume, clear, and fork.

It also serves the parts of a Claude Code session that aren't messages: the subagents a turn
spawned and their own transcripts, context compactions as events rather than a wall of summary
text, the attachments a prompt carried and every picture the agent looked at, the slash commands
that machine will actually resolve, `/goal` state, plan rate-limit gauges — and the machine
itself: what a whole conversation cost and where the month's money went, the project's git tree
read for triage, whether the CLI is signed in (with a sign-in the bridge runs over a
pseudo-terminal so a phone can complete it), whether the bridge is current (with a self-update
that follows through its own restart), and a turn the machine cut off, recovered as a named
state with a resume instead of silence. With an APNs key configured, Live Activity and turn-end
pushes let a phone watch a turn it isn't looking at.

It uses the logged-in CLI (your Claude subscription), not an API key.

Known consumers:

- [Tailscode](https://github.com/guitaripod/Tailscode) — native iOS, Linux and macOS clients, drive the bridge over Tailscale.
- [CodingAgentKit](https://github.com/guitaripod/CodingAgentKit) — Swift package whose `ClaudeCodeBackend` speaks this protocol.

## Requirements

- Swift 6 toolchain (macOS 14+ or Linux) and `git`.
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and logged in
  (`claude` must work interactively for the user running the bridge).
- `sqlite3` only if you want the opencode Go quota gauge.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/guitaripod/claude-bridge/master/install.sh | bash
```

Clones into `~/.claude-bridge/src`, builds it, generates a password, and registers a service that
survives a reboot — `systemctl --user` on Linux, a launch agent on macOS. It prints the address,
username and password to paste into a client — including a single `http://… BRIDGE_PASSWORD=…`
line that [Tailscode](https://github.com/guitaripod/Tailscode) reads whole, filling both fields
from one paste. Config lives in `~/.claude-bridge/config.env`; edit it and restart the service to
change the port, model, or APNs key.

A client that already minted a password can bake it into the one-liner, so both sides carry the
same one without anyone retyping it (an existing config's password is never overwritten):

```sh
curl -fsSL https://raw.githubusercontent.com/guitaripod/claude-bridge/master/install.sh | BRIDGE_PASSWORD=xxx bash
```

## Updating

```sh
curl -fsSL https://raw.githubusercontent.com/guitaripod/claude-bridge/master/install.sh | bash
```

Re-running the installer updates in place and keeps your config and service. It never overwrites
an existing `config.env`.

Or update it from your phone: `GET /update` reports the state, `POST /update` fetches, rebuilds
and restarts, reporting progress through a state file that outlives the restart.
[Tailscode](https://github.com/guitaripod/Tailscode) exposes this as a button on the server
screen, so the machine never needs an ssh session to keep current. An update refuses to run on a
checkout with uncommitted changes, and says so.

`UpdateStatus` is deliberately hard to misread: it reports the checkout's `version` *and* the
stamp of the binary actually **running** (`running`, `builtAt` — the installer writes a
`build.json` after every build), because those part company between a build and a restart —
`restartRequired` says so explicitly. The `remote` block records whether the remote was actually
reached and when, so a fetch that failed can never read as "up to date".

## Running it by hand

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
| GET | `/status` | — | `{"agent": "claude", "model": …, "version": …, "authenticated": bool, "proto": 2, "epoch": …}` — `proto`/`epoch` announce the sequenced `/stream` protocol |
| GET | `/stream` | `Last-Event-ID` header or `?since=epoch:seq` | one sequenced SSE stream of everything this bridge knows is happening (below) |
| GET | `/auth` | — | whether the CLI is signed in, as whom, and the sign-in in progress if there is one |
| POST | `/auth/login` | — | starts `claude auth login` on a pseudo-terminal and answers with the URL it printed |
| POST | `/auth/code` | `{code}` | types the code the browser produced; answers with the status once the machine is signed in (`400` with `error` if it wasn't accepted) |
| POST | `/auth/cancel` | — | drops a sign-in that was left waiting |
| GET | `/update` | `?check=false` to skip the remote fetch | `UpdateStatus` — checkout version, the running binary's own stamp, `restartRequired`, newer commits and their subjects, whether this install can update itself, an explicit `remote` block, and the phase of the last update |
| POST | `/update` | — | `202 UpdateStatus` once the update is running (`409` when it cannot, with `reason`); poll `GET /update` for `phase`: `running` → `building` → `restarting` → `succeeded`/`failed` |
| GET | `/sessions` | — | `[SessionSummary]`, newest first, store + discovered transcripts merged |
| POST | `/sessions` | `{title?, directory?, model?, effort?}` | the created `Session`; `directory` sets the project directory its turns run in |
| GET | `/sessions/:id` | — | `Session` (404 if unknown), including the turn in flight |
| PATCH | `/sessions/:id` | `{title}` | `{"ok": true}` (404 if unknown) |
| DELETE | `/sessions/:id` | — | `{"ok": true}` |
| POST | `/sessions/:id/message` | `{text, model?, effort?, attachments?}` | `202 {"ok": true, "queued": false}`; the turn runs async, watch `/events`. A prompt sent while this bridge is already running a turn on the session is accepted and **queued** behind it — `202 {"ok": true, "queued": true, "position": n}` — so two clients on one session cannot start two `claude` processes against one transcript. `409` when the session is being written by a turn started outside this bridge (a terminal), which it cannot serialize against |
| POST | `/sessions/:id/abort` | — | `{"ok": true, "stopped": bool, "discarded": n}`; stops the turn in flight and discards anything queued behind it. `409` when there is nothing to stop from here |
| POST | `/sessions/:id/clear` | — | `{"ok": true}`; drops history and the resumable Claude session id. `409` while a turn is running or queued — fork instead |
| POST | `/sessions/:id/fork` | — | new `Session` (404 if unknown) seeded with the source's history; its first turn runs `--fork-session` so it diverges instead of mutating the parent |
| GET | `/sessions/:id/events` | — | `text/event-stream` of per-session bridge events (below) |
| GET | `/sessions/:id/usage` | — | `{costUSD?, tokens?}` for the session's last turn |
| GET | `/sessions/:id/spend` | — | the whole conversation priced turn by turn from the CLI's own transcript — per-turn token tiers (cache write/read split), per-model, always an API-equivalent estimate |
| GET | `/sessions/:id/interruption` | — | the state of a turn the machine cut off, as `{"interruption": Interruption\|null}` — `null` when there is none |
| POST | `/sessions/:id/resume` | — | `202`; resumes an interrupted turn with a composed continuation brief — what its own transcript says it already did — never a blind re-send |
| POST | `/sessions/:id/interruption/dismiss` | — | sets the interruption aside |
| POST | `/sessions/:id/auto-resume` | `{enabled}` | resume this session's future interruptions automatically |
| GET | `/sessions/:id/agents` | — | `[SubagentSummary]` — the subagents this session spawned, with what a live one is doing right now (current tool, todo progress) |
| GET | `/sessions/:id/agents/:agentID` | — | `SubagentTranscript` — that subagent's own messages |
| GET | `/search` | `?q=`, `?limit=` | full-transcript search across every session on the machine, subagent sidecars included; honest about what it didn't get to (`truncated`) |
| GET | `/analytics` | `?days=` | the whole machine's usage ledger: every transcript priced turn by turn — totals, per-day series, models, projects, tools, compactions, records |
| GET | `/git` | `?dir=` or `?session=` | `GitSnapshot` — branch, upstream drift, porcelain-v2 status with per-file numstat, recent commits, and any merge/rebase left half-done |
| GET | `/git/diff` | `?path=`, `?staged=`, `?dir=`/`?session=` | `GitPatch` for one file |
| GET | `/git/commit` | `?hash=`, `?dir=`/`?session=` | `GitCommitDetail` via show + numstat |
| GET | `/commands` | `?directory=` | `[AgentCommand]` — slash commands a headless turn will resolve |
| GET | `/usage` | — | Claude plan rate-limit gauges (session / week / Opus) read from the CLI's own accounting |
| GET | `/usage/grok` | — | Grok quota gauges, when a Grok key is configured |
| GET | `/usage/opencode` | — | opencode Go subscription estimate, summed from opencode's local database over the plan's windows |
| GET | `/files` | `?path=` | `[FileNode]` — directory listing for the project picker |
| GET | `/files/content` | `?path=` | `{path, content}` |
| GET | `/files/raw` | `?path=`, `?tool=`, `?session=` | the file's bytes with its MIME type — what an image part points at; a deleted file falls back to the copy that session's transcript kept for that tool call |
| GET | `/attachments/:session/:name` | — | the bytes a prompt carried, served back with its MIME type |
| POST | `/sessions/:id/live-activity` | `LiveActivityRegistration` | registers an ActivityKit push token for this session |
| POST | `/push/device` | `{token, environment}` | registers a device token for turn-end pushes (requires `BRIDGE_PASSWORD`) |
| POST | `/push/device/unregister` | `{token}` | forgets it |

`Session`: `{id, title, directory?, claudeSessionID?, priorClaudeSessionIDs?, model, effort,
createdAt, updatedAt, messages, lastCostUSD?, lastTokens?, pendingFork?, customTitle?,
autoTitled?, goal?, interruption?, autoResume?}`.
`Message`: `{id, role: "user"|"assistant"|"system", parts, createdAt}` — `system` carries
transcript boundaries such as compactions.
`Part` is `{kind: "text"|"reasoning", text}`, `{kind: "tool", tool: ToolCall}`,
`{kind: "file", file: FileRef}` or `{kind: "compaction", compaction: Compaction}`.
`ToolCall`: `{id, name, input, output?, status: "running"|"completed"|"error"}`.
Dates are ISO 8601. Sessions persist to `BRIDGE_STORE` across restarts. After a session's first
exchange, a one-shot haiku-model `claude -p` call writes it a 3–6 word title.

A `file` part on a **user** message is an attachment that prompt carried; on an **assistant**
message it is a picture the agent looked at — every tool result that hands Claude an image becomes
one, docked at the tool call that read it, with `url` pointing at `/files/raw` so a client renders
the same picture without the base64 the transcript keeps. The picture outlives the file: agents
write screenshots to `/tmp` and clean them up, so `/files/raw` falls back to the transcript's own
copy when the path is gone.

## Signing in

A signed-out CLI does not fail a turn — it answers it, with "Not logged in · Please run /login" —
so the bridge reports the machine's account state (`/status` carries `authenticated`, `/auth` the
detail) and can run the sign-in itself. `claude auth login` is a terminal program that prints an
OAuth URL and waits for the code the browser hands back, so the bridge runs it on a pseudo-terminal
and splits those two halves across the network: a client opens the URL wherever the person is, and
returns the code. That is what makes a headless server signable-in from a phone that has no shell
on it.

## One turn at a time

A session runs one turn. A prompt that arrives while a turn is in flight is appended to the
transcript and broadcast like any other, then queued behind it and started when that turn ends —
so a phone and a desktop can both drive one session without two `claude -p --resume` processes
running against one transcript in one working directory, each blind to the other's edits.

The session goes `idle` only when nothing is left waiting, which is what stops a client's own
send queue from draining into turns nobody asked for. Stopping a turn discards what queued behind
it. `/clear` refuses while a turn is held, because pulling the transcript out from under a running
turn loses it; fork instead. A turn started outside this bridge — an interactive `claude` in a
terminal — cannot be serialized against, so `/message` still answers `409` for that case alone.

## A turn the machine cut off

Every turn is journaled. When the bridge starts, each turn the journal says was open gets a
verdict: the transcript closed cleanly (**completed**), the `claude` process from before is
somehow still alive (**still running**), or the machine died under it (**interrupted**). An
interruption is a state, not silence: it records the progress the transcript proves — tools run,
files touched, commands issued, how far the answer got — and surfaces on the session
(`Session.interruption`, `SessionSummary.interrupted`) until someone acts on it.

`POST /sessions/:id/resume` continues the turn with a composed brief telling the model what its
own transcript says it already did — never a blind re-send of the original prompt. `dismiss` sets
it aside; `auto-resume` (per session, or `BRIDGE_AUTO_RESUME=1` machine-wide) does the resuming
without being asked.

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

Because the transcripts are all there, they are also searchable: `GET /search` fans one query
out over the whole transcript directory — subagent sidecars searched with their parent — bounded
from the inside, and honest when it ran out of time rather than silently partial.

## SSE events

Each event on `/sessions/:id/events` is one `data: <json>\n\n` frame:

| `type` | Fields | Meaning |
|---|---|---|
| `message` | `message` | Full message upsert — the user's message echoed back, the empty assistant message that opens a turn, and the final assembled assistant message (reasoning + tool + text parts) that closes it |
| `delta` | `messageID`, `delta` | Incremental assistant text chunk; append to the message's text |
| `tool` | `messageID`, `tool` | Tool call upsert — first with `status: "running"`, again with `output` and `completed`/`error` |
| `status` | `status` | `"running"` when a turn starts, `"idle"` when it ends |
| `goal` | `goal?` | The session's `/goal` changed; the field is absent once nothing is being pursued |
| `compaction` | `phase`, `error?` | A compaction started, finished, or failed — the turn is still running throughout. The numbers and summary arrive as the `compaction` part of a `message` upsert |
| `interrupted` | `interruption?` | A turn was cut off by the machine, with what it had already done; the field is absent once it is picked back up or dismissed |
| `error` | `error` | Turn-level failure (e.g. the `claude` binary could not be launched) |

A subscriber gets a `status` frame immediately on connect, so a client that attaches mid-turn
knows the session is running without waiting for the next token.

## One stream of everything

A client watching many sessions doesn't want one socket per session. `GET /stream` is protocol 2:
a single sequenced SSE stream of everything — a `hello` frame on connect, `session` frames
carrying the per-session events above, `list.upsert`/`list.remove` as the chat list changes,
`agents` frames as subagents come and go, and a heartbeat every 10 seconds so a dead link is
noticed rather than trusted.

Every frame except the heartbeat carries `id: <epoch>:<seq>` (heartbeats are unsequenced so
they never advance `Last-Event-ID`). Reconnect with `Last-Event-ID` (or `?since=epoch:seq`)
and the bridge replays the gap; when the window is gone — or the epoch changed because the bridge
restarted — it answers `reset` and the client refetches instead of guessing. `GET /status`
advertises `proto: 2` and the current `epoch`, so a client knows before subscribing.

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

## Models, effort, ultracode

A session's model and effort default to what the **machine** would use: when `BRIDGE_MODEL` /
`BRIDGE_EFFORT` are unset, the bridge reads the CLI's own `~/.claude/settings.json` (`model`,
`effortLevel`) and re-reads it whenever the file changes — a `/model` pick in a terminal changes
the next chat from a phone, no restart. Both remain overridable per session and per message.

Effort `ultracode` is real: the turn runs as `--effort xhigh` plus `--settings
{"ultracode": true}`, and because print mode ignores the CLI's own keyword, the bridge also
honors the word `ultracode` appearing in a prompt. A session that ran ultracode keeps reporting
it even though its transcript can only spell xhigh.

## Money

`GET /sessions/:id/spend` prices a whole conversation from the CLI's own JSONL, turn by turn,
across the four token tiers (output, fresh input, cache written — 5m/1h split — and cache read).
`GET /analytics` does it for the whole machine: every transcript plus every subagent sidecar
folded into one ledger — totals, a per-day series, models, projects, tools, compactions,
records — cached per file, nothing stored beyond the cache. Both are **API-equivalent
estimates**, marked as such: a subscription bills a flat fee, so the figure is what the tokens
would have cost, never a bill.

## The repository, read

A transcript can't tell you where a change lands, so the bridge reads the project's git tree —
and only reads it. `GET /git` returns the branch and its upstream drift, porcelain-v2 status with
per-file numstat, recent commits, and any merge/rebase/cherry-pick left half-done; `/git/diff`
and `/git/commit` serve one file's patch and one commit's detail. The directory comes from
`?dir=` or `?session=`'s working directory. Nothing stages, commits, pulls or pushes: a change
made from a phone is a change nobody reviewed on the machine that has to live with it. A
directory outside version control says so.

## Configuration

Everything is environment variables. Empty values fall back to the default.

| Variable | Default | Meaning |
|---|---|---|
| `BRIDGE_PORT` | `4098` | Listen port |
| `BRIDGE_BIND` | `127.0.0.1` | Bind address. Set `BRIDGE_BIND=0.0.0.0` only when the machine sits behind Tailscale (or an equivalent private overlay) so tailnet clients can reach it |
| `BRIDGE_PASSWORD` | empty | HTTP Basic auth password (username `claude`). Required unless `BRIDGE_PERMISSION` is changed off `bypassPermissions` — see Security |
| `BRIDGE_PERMISSION` | `bypassPermissions` | Claude `--permission-mode`. `bypassPermissions` also passes `--dangerously-skip-permissions` |
| `BRIDGE_WORKDIR` | `~/agentapi-workdir` | Working directory for sessions that didn't choose one (created if missing, also passed as `--add-dir`); a session created with `directory` runs in its own |
| `BRIDGE_CLAUDE` | `~/.local/bin/claude` | Path to the `claude` binary |
| `BRIDGE_MODEL` | machine's | Default model for new sessions. Unset, it follows `~/.claude/settings.json` (`model`), falling back to `sonnet` |
| `BRIDGE_EFFORT` | machine's | Default reasoning effort. Unset, it follows `~/.claude/settings.json` (`effortLevel`), falling back to `medium` |
| `BRIDGE_AUTO_RESUME` | `0` | Resume interrupted turns automatically, machine-wide |
| `BRIDGE_STORE` | `~/.claude-bridge/sessions.json` | Session persistence file |
| `BRIDGE_PROJECTS` | `~/.claude/projects` | Claude Code CLI transcript root scanned for discoverable sessions |
| `BRIDGE_SRC` | `~/.claude-bridge/src` | The checkout self-update operates on (set by the installer's generated runner) |
| `BRIDGE_STATE_DIR` | `~/.claude-bridge` | Where the running binary's build stamp (`build.json`) is read from; update state always lives in `BRIDGE_STORE`'s directory |
| `BRIDGE_OPENCODE_DB` | auto | Path to opencode's local database, for `/usage/opencode` |
| `BRIDGE_OPENCODE_GO_LIMITS` | `12,30,60` | opencode Go plan limits in dollars: 5-hour, week, month |
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
macOS, use a `launchd` LaunchAgent with the same environment variables instead. (The installer
does all of this for you, pointing the unit at a generated `~/.claude-bridge/run.sh` that
sources `config.env`.)

## License

GPL-3.0. Copyright (c) 2026 Midgar Oy. See [LICENSE](LICENSE).
