# Changelog

Each release in a line or two per change, written for the person deciding whether to update. The
app reads this file from the project's head, so what it shows as new is exactly what is listed
here above the version a machine is running.

## 1.15.3 — 2026-10-21

- Installing over a bridge that launchd already starts now leaves one running. Waiting for the job to come back after `bootout` also matched the job that was still on its way out, so the installer returned as though it had loaded the new one and the job then disappeared, leaving the machine with no bridge at all. It now waits for the old job to be gone before loading the plist, and asks again until launchd takes it.

## 1.15.2 — 2026-10-21

- Installing a release over a bridge that systemd already runs now restarts it into the new program. `systemctl enable --now` does nothing to a unit that is already active, so the archive landed in `~/.claude-bridge/bin` while the old program went on serving and `--version` still answered with the one it replaced; the installer enables the unit and then restarts it, which starts a stopped one just as well.

## 1.15.1 — 2026-10-20

- Installing over a bridge that a launchd job already starts no longer leaves the machine without one. `bootout` answers before the job is actually gone, so the `bootstrap` straight behind it was refused with "Input/output error" and the installer stopped there — job unloaded, program no longer running; it now keeps asking for a few seconds instead of taking the first refusal as the answer.

## 1.15.0 — 2026-10-20

- A turn's push now says what happened, not only that it did. Beside the English alert it carries a `notice`: how long the turn took, how many tools it ran, how many lines it added and removed, the first of what it answered, the question it stopped on with its options, or the error and the prompt that failed. The phone writes the sentences in its own language from those facts and draws the buttons, a reply field and a long look from them. The alert also names its `category`, `relevance-score` and `target-content-id`, and a question is marked time sensitive. A phone that does not read the notice shows the same alert as before. The whole body stays under 3,800 bytes: the answer is shortened first, then the prompt, then the options' reasons.

- opencode Go usage is read from the account's own status instead of guessed from this machine's database. The card now carries the plan (Go or Go Plus), the real dollar ceilings and the exact reset of each window, and the 5-hour window is named as a session so the client can pace it. A reading that cannot be taken is the last good one marked cached, or the server's reason; no zero estimate is invented. The `BRIDGE_OPENCODE_DB` and `BRIDGE_OPENCODE_GO_LIMITS` settings are gone.
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
