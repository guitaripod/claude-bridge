# Changelog

Each release in a line or two per change, written for the person deciding whether to update. The
app reads this file from the project's head, so what it shows as new is exactly what is listed
here above the version a machine is running.

## 1.21.1 — 2026-11-08

- A message sent while a chat's background work runs is taken again. Once a turn that left a workflow, a subagent or a background command running had been over for 45 seconds, every message to that chat was refused with "This session is running on the server right now" until the work finished, because what the work's agents wrote was taken for somebody else working in the chat. While the bridge's own Claude process carries the work, and for 45 seconds after it ends, its agents' writes are known as the bridge's own; a chat whose conversation a terminal is writing is still refused.
- The usage card names the 20× Max account Ultra and the 5× one Max, with no multiplier beside either.

## 1.21.0 — 2026-11-06

- A push says the work is done when the work is done, not when a turn is. A turn that leaves a background command, a subagent or a workflow running, that a queued message follows, or that Claude follows on its own once that work finishes is one stretch of work, and the phone hears about it once, ten seconds after nothing is running, carried or queued any more, with how long the whole stretch took and every tool it ran. A turn that stops to ask still pushes at once.
- Each phone decides what it hears. A device registers its rules with its token (finished work when it is done, every turn, only failures or never; only for work longer than a minimum; approvals and questions on or off; muted chats), and the bridge applies them per device. A phone that registered before the rules existed gets the default, finished work when it is done.
- `GET /sessions/:id/wait?until=settled` holds the phone's background wait until the work settles and answers `settled: true` for the whole stretch; `/status` says `turnWait: 2`.

## 1.20.1 — 2026-11-06

- The Mac build no longer crashes when a request's body (a message, a queued message, a rename) reaches it after its headers, as it often does from a phone on a cellular network: since 1.18.0 the Mac bridge died on them ("The network connection was lost" in the app) and launchd restarted it, over and over. The code was right; the Swift 6.3 compiler of Xcode 26 miscompiled the wait for the body (swiftlang/swift#84793). Releases for the Mac are now built with Xcode 27, and every release is started and sent a late body before it is published.

## 1.20.0 — 2026-11-04

- Hosts DeepSeek Harness, DeepSeek's open-source coding agent: its own `dsh` when it is on PATH, otherwise `npx @deepseek-ai/dsh --profile acp` with nothing installed, and a DeepSeek API key kept on the machine like any other agent's. Its models (DeepSeek V4 Flash and Pro, and any provider set up in dsh) and reasoning levels come from its own session. The ACP registry does not carry it, so an agent the bridge knows that the registry lacks is now listed wherever its runtime is, ready to add from the app.
- An agent's tool call that has no ACP kind but is named for a Claude Code tool (`bash`, `write`, `edit`, `grep`, `todo_write`, …) is drawn as that tool: DeepSeek Harness's shell commands, file writes and edits, searches and task lists show as Bash, Write, Edit, Grep and the task board instead of bare names.
- A message queued behind an agent's turn now reaches the agent when that turn ends. Until now ending the turn closed the queued one before it was sent, leaving an empty answer.

## 1.19.0 — 2026-11-04

- `GET /sessions/:id/context` answers what fills a conversation's context window as Claude Code itself counts it: the system prompt, tools, memory files, skills, agents, the messages split by kind, the buffer held back for auto-compaction, the window and where auto-compaction starts. It asks the process holding the conversation, or one started on its transcript, so it costs no turn and no request to the model; the app's Range sheet shows it as measured rather than estimated.
- The session store is split: `sessions.json` is an index of every conversation without its messages, and each conversation's messages live in `conversations/<id>.json`, written only when they change. On a machine with 618 conversations the index is 216 KB instead of 243 MB and a turn's end writes in 17 ms instead of a second. The first start splits the old file on its own. A bridge older than 1.19.0 started on the split store shows conversations without their messages until it is updated again; nothing is lost.

## 1.18.0 — 2026-11-04

- Answers that are whole documents — a transcript, the session list, analytics — go out gzipped to any client that asks, which every app does on its own: a long conversation that was 6.2 MB on the wire is 1.5, the list 42 KB instead of 184. Event streams are never compressed.
- `GET /sessions` is tagged like a transcript, so a client holding the list it last read is answered 304.
- A turn waiting on Anthropic between attempts says so: a `retry` frame with the attempt, the reason, the HTTP status and when it tries next, closed by the next answer or the end of the turn, and `GET /sessions/:id` carries the wait a turn is in. Until now a turn retrying an overloaded model for minutes looked like one thinking hard.
- `/status` reports `"detail": 1`: the session read answers the goal, the cut-off turn and the provider wait as the whole word on each, so an app refreshing a conversation asks for none of them separately.
- A failed turn's push no longer says "Done in …" on a phone whose notification extension leaves the alert as sent.
- Live answers no longer stall for a second whenever a turn anywhere on the machine ends. The session store, every conversation with its messages, was re-encoded whole on the store's actor at each settle; it is now written off the actor, re-encoding only the conversations that changed, in the same format.

## 1.17.0 — 2026-11-03

- Hosts any agent that speaks the Agent Client Protocol beside Claude Code — Hermes, Gemini CLI, Codex, goose, Kimi CLI, Qwen Code, GitHub Copilot and the rest of the ACP registry — on the same port and in the same session list, with nothing else to install or pair. An agent is found on PATH, run through npx or uvx, or downloaded from the registry and checked against its sha256; it is ready only once it has answered a real session. `GET /agents`, `/agents/registry`, `/agents/models`, and presses to add, prove, install, give a brain, keep a key and sign in.
- Gives Hermes a brain with one press: any model server already on the machine (llama-swap, ollama, LM Studio, vLLM), named the way the server names its models, or a provider key kept on the machine in a 0600 file.
- Keeps schedules on the machine, so a question asked every morning is asked whether or not any app is open: `GET/POST /schedules`, `PATCH/DELETE /schedules/:id`, `POST /schedules/:id/run`. Runs go into one conversation that remembers by default, a run with nothing new stays quiet (no push, not unread) while a failure always speaks, and a machine that was off asks once for what it owed and records how many times it missed.
- `/status` reports `agents` and `schedules`, and `/stream` carries a `machine` frame when either changes.

## 1.16.0 — 2026-10-23

- A message queued behind a running turn now lives on the bridge, so every device on the conversation shows the same queue and can edit or cancel it, instead of the phone that queued it being the only one to know. `GET /sessions/:id/queue` reads it; `POST /sessions/:id/queue` adds an item under the client's own id (idempotent, and started at once when nothing is running), `PATCH` and `DELETE /sessions/:id/queue/:qid` change or cancel one that has not started (`409 already_started` once it has), and `POST /sessions/:id/queue/resume` lets a paused queue run. Every change is a `queue` event carrying the whole queue, `GET /sessions/:id` carries `queue` and `queuePaused`, and `/status` reports `"queue": 1` so an app can tell a bridge that holds one.
- A queued message is not in the conversation until it starts: its user message is written when its turn begins, not when it was queued. The bridge starts the next one when a turn closes, a compaction included.
- Stop pauses the queue instead of throwing it away, and a new message, an enqueue or Resume lets it run again. A queue survives a restart, attachments included, and comes back paused so nothing runs unattended after a crash.
- An older app sending while a turn runs still works: its message joins the queue like any other, so a newer app sees it.

## 1.15.4 — 2026-10-23

- A compaction is announced once and always closed, so a chat no longer shows it compacting until the app is restarted. The CLI repeats its compacting status while an automatic compaction writes its summary, and only the first of them now starts one. The result and the boundary record are one seam in either order, a failed result is a failure rather than a seam, and a turn that ends on a compaction the CLI never finished (a process that died, a stop) now says so.
- opencode Go's usage card reads the account's own status: the plan, the real dollar ceilings and both ends of every window, with the reason in one place when it cannot answer. A cache from the estimate era is never served as current data, and two machines on one account fold into one card.

## 1.15.3 — 2026-10-21

- Installing over a bridge that launchd already starts now leaves one running. Waiting for the job to come back after `bootout` also matched the job that was still on its way out, so the installer returned as though it had loaded the new one and the job then disappeared, leaving the machine with no bridge at all. It now waits for the old job to be gone before loading the plist, and asks again until launchd takes it.

## 1.15.2 — 2026-10-21

- Installing a release over a bridge that systemd already runs now restarts it into the new program. `systemctl enable --now` does nothing to a unit that is already active, so the archive landed in `~/.claude-bridge/bin` while the old program went on serving and `--version` still answered with the one it replaced; the installer enables the unit and then restarts it, which starts a stopped one just as well.

## 1.15.1 — 2026-10-20

- Installing over a bridge that a launchd job already starts no longer leaves the machine without one. `bootout` answers before the job is actually gone, so the `bootstrap` straight behind it was refused with "Input/output error" and the installer stopped there — job unloaded, program no longer running; it now keeps asking for a few seconds instead of taking the first refusal as the answer.

## 1.15.0 — 2026-10-20

- A turn's push now says what happened, not only that it did. Beside the English alert it carries a `notice`: how long the turn took, how many tools it ran, how many lines it added and removed, the first of what it answered, the question it stopped on with its options, or the error and the prompt that failed. The phone writes the sentences in its own language from those facts and draws the buttons, a reply field and a long look from them. The alert also names its `category`, `relevance-score` and `target-content-id`, and a question is marked time sensitive. A phone that does not read the notice shows the same alert as before. The whole body stays under 3,800 bytes: the answer is shortened first, then the prompt, then the options' reasons.

- opencode Go usage is read from the account's own status instead of guessed from this machine's database. The card now carries the plan (Go or Go Plus), the real dollar ceilings and the exact start and reset of each window, and the 5-hour window is named as a session rather than a rolling window. A reading that cannot be taken is the last good one marked cached, or the server's reason with a short code; no zero estimate is invented. The snapshot names the account, so two machines signed into one Go account fold into one card and a machine that failed is named rather than becoming part of the live provenance. The `BRIDGE_OPENCODE_DB` and `BRIDGE_OPENCODE_GO_LIMITS` settings are gone.
- Quota timestamps are read and written by value styles rather than Foundation's shared formatter, so two quota routes asked at once cannot crash the bridge on Linux.
- Installing no longer needs Swift or git. The installer downloads a prebuilt program for the machine (Linux x86_64 and aarch64, macOS on Apple silicon), checks its SHA-256 and starts it, in seconds instead of a long build. It builds from source only when there is no program for the machine, the download fails or does not check out, or `--from-source` asks, and then says why in one sentence and where to get Swift if it is missing.
- The installer looks at the machine first and says in plain words whether Tailscale is installed and signed in and whether Claude Code is installed and signed in, carries on either way, and ends with what is actually left to do. `--no-service` installs everything except the service. The bridge answers `--version`, and refuses an argument it does not know rather than starting a second server.
- A machine installed from the prebuilt release now updates itself from Tailscode like any other. It looks for a newer release by reading the release's version pointer (one conditional request at most every five minutes, tolerant of being offline), tells the app what is new from that release's changelog, and runs the installer it kept from its own archive, which refuses any download whose checksum does not match and leaves the running program alone when one does not. Everything the app reads keeps its shape; the quiet wait before a restart, the job steps and the unattended policy are the ones a source install has.
- `claude-bridge pair` prints the link and the QR code Tailscode scans to find this machine, and the installer ends with it. It names the machine by its Tailscale name (or address) and says plainly when it is not on a tailnet; the password goes into the link only when the machine does not trust its tailnet. `--link-only` and `--json` are for scripts.
- Release archives now carry the installer they were made with, and each release publishes `CHANGELOG-<version>.md` beside them.
- The installer's time limit on the programs it asks things of no longer leaves a sleeping timer behind for the rest of the limit.

## 1.14.0 — 2026-10-10

- The bridge now keeps what a person decides about each conversation — saved, pinned, archived and when it was last read — so every device reads the same answer from the machine that holds the chat. `PATCH /sessions/:id` takes `pinned`, `archived` and `read` (`seen` or `unread`) beside `saved`, each stamped with when the person decided so a phone that was offline cannot overrule a later choice, and every conversation in a listing or a live `list.upsert` carries them. `/status` reports `marks` so a client can tell a bridge that holds them from one that does not.

## 1.13.2 — 2026-10-10

- A phone that comes back after a long absence is no longer replayed the whole of what happened meanwhile. A client more than a thousand frames behind is told its window is gone and joins at the present, so it reads the conversation once instead of watching hours of text deltas and list moves arrive one at a time.

## 1.13.1 — 2026-09-27

- The Live Activity stops saying a tool is running once it has finished: between tools the card reads *Thinking…* again, keeping the last tool as context, where it used to say *Running Bash* for as long as the model thought about what to do next.
- A finished turn's card leaves the Dynamic Island on time again. Starting a Live Activity for one chat made the phone hand over every other card's address, and the bridge took that for a new turn, forgot the card had settled, and never took it off the island; the phone could show *Done* there for hours.
- A turn somebody stopped takes its card down at once instead of leaving *Cancelled* on the Lock Screen for an hour.

## 1.13.0 — 2026-09-25

- A new route, `GET /sessions/:id/wait`, answers only once a turn ends or stops to ask you something — a background URLSession can hold it while the app is closed and be woken by the answer, with nothing passing through Midgar or Apple. `/status` reports `turnWait` so a client can tell a bridge too old for the route from a session it does not know.
- `POST /push/device` now says whether this bridge actually holds an APNs key (`delivers`), so a client can tell a real push from one an old bridge only pretended to accept.
- A turn stopped or failed right before a restart (a self-update's `exit(0)`, say) now settles as `cancelled`/`failed` on `/wait` rather than a plain `finished`: the stop and the failure are now written to the turn's journal record as they happen, not just held in memory.

## 1.12.1 — 2026-09-25

- The bridge no longer grows by gigabytes a day until Linux kills it, taking every running chat with it. Checking which chats a live Claude process still serves leaked a little memory for every kernel thread on the machine, every two seconds, and a busy day added up to 15 GB.
- A client that drops its live connection no longer leaves the bridge holding a dead subscriber and re-reading that chat's transcript every second for the rest of its life.

## 1.12.0 — 2026-09-24

- On a Mac, Tailscode can tell whether the bridge has Full Disk Access and walk you through giving it: one press opens System Settings at the right list on the Mac with the bridge shown in Finder beside it, and the app notices the moment the switch is on. Without it, macOS stops an agent at a permission dialog on a screen nobody is watching.

## 1.11.3 — 2026-09-24

- On a Mac, 1.11.2's signed build was removed by macOS as malware ("Malware Blocked and Moved to Trash") and refused at every launch after. Builds are signed ad hoc again, under a requirement that names the bridge rather than the exact build, so privacy permissions still carry over between updates without a certificate.

## 1.11.2 — 2026-09-24

- On a Mac, the bridge stops asking for its privacy permissions again after every update: each build is now signed with a certificate from the Mac's keychain, so a permission given once carries over to later builds. The first update after this one asks one last time. A Mac with no signing certificate keeps asking, and the update log says so.

## 1.11.1 — 2026-09-24

- Pressing Restart on a bridge with a newer build waiting no longer gets refused with "already running the build in its checkout" when that build landed soon after the bridge started.
- A restart takes seconds rather than a minute and a half: helper processes that ignore the stop signal are ended after 15 seconds instead of 90. Existing installs pick this up the next time the installer writes the service.

## 1.11.0 - 2026-09-23

- Reopening a chat, or coming back to one after the phone slept, no longer downloads the whole conversation again when nothing in it changed: Tailscode 1.55 asks whether it moved, and the bridge answers in a single line instead of resending it.

## 1.10.1 — 2026-09-23

- A chat is dated by the last thing said in it: it no longer moves up the list half an hour after it went quiet, and a restart no longer moves every chat it had open to the top.

## 1.10.0 — 2026-09-23

- Updates are followed step by step — download, build, waiting for idle, restart — and every update reports how it ended and which version it landed on.
- The app shows what is new in an update, read from this changelog.
- Live Activities stay on the Lock Screen after a turn finishes, showing how it ended, until you open the chat.

## 1.9.2 — 2026-09-23

- A chat that used agents stops showing as live once its last agent reports back.
- Nested agents are answered where they report, and a background agent whose CLI is gone is shown as gone.

## 1.9.1 — 2026-09-17

- Stopping background work asks Claude Code to stop it, so agents, workflows and shells all end the same way.

## 1.9.0 — 2026-09-16

- A background shell that is stuck is ended and reported, and background work says how long it has been running.
- Background work can be stopped from the app.

## 1.8.3 — 2026-09-16

- A /compact lands once instead of twice, and a compacted chat goes idle when the compaction ends.

## 1.8.2 — 2026-09-16

- A turn that goes silent, or a background shell that disappears, now ends on its own instead of staying live until a restart.

## 1.8.1 — 2026-09-11

- A finished answer is no longer published twice at the end of a turn.

## 1.8.0 — 2026-09-06

- Work Claude Code keeps running between turns is reported, so a chat waiting on a long command shows as working rather than finished.
