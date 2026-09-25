# Changelog

Each release in a line or two per change, written for the person deciding whether to update. The
app reads this file from the project's head, so what it shows as new is exactly what is listed
here above the version a machine is running.

## 1.13.0 — 2026-09-25

- A new route, `GET /sessions/:id/wait`, answers only once a turn ends or stops to ask you something — a background URLSession can hold it while the app is closed and be woken by the answer, with nothing passing through Midgar or Apple. `/status` reports `turnWait` so a client can tell a bridge too old for the route from a session it does not know.
- `POST /push/device` now says whether this bridge actually holds an APNs key (`delivers`), so a client can tell a real push from one an old bridge only pretended to accept.

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
