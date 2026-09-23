# Changelog

Each release in a line or two per change, written for the person deciding whether to update. The
app reads this file from the project's head, so what it shows as new is exactly what is listed
here above the version a machine is running.

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
