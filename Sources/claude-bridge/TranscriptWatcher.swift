import Foundation

/// Tails a session's transcript file while SSE clients are subscribed, so activity from an
/// interactive `claude` running elsewhere on this machine streams to observers live. Emission is
/// suppressed while this bridge's own runner has a turn in flight for the session (and briefly
/// after), because the runner already streams that turn under different message ids.
actor TranscriptWatcher {
    private let index: TranscriptIndex
    private let store: SessionStore
    private var tailing: Set<String> = []

    private static let pollInterval: Duration = .seconds(1)
    private static let idleAfter: TimeInterval = 30
    private static let runnerGrace: TimeInterval = 5

    init(index: TranscriptIndex, store: SessionStore) {
        self.index = index
        self.store = store
    }

    /// Starts a tail for the session's transcript if one exists and none is running.
    /// The tail stops itself once the last SSE subscriber disconnects.
    func ensureTail(sessionID: String) async {
        guard !tailing.contains(sessionID) else { return }
        let transcriptID = await store.get(sessionID)?.claudeSessionID ?? sessionID
        guard let path = await index.path(for: transcriptID) else { return }
        tailing.insert(sessionID)
        Task {
            await self.tail(sessionID: sessionID, transcriptID: transcriptID, path: path)
            await self.finished(sessionID)
        }
    }

    private func finished(_ sessionID: String) {
        tailing.remove(sessionID)
    }

    private nonisolated func tail(sessionID: String, transcriptID: String, path: String) async {
        let caster = await store.broadcaster(for: sessionID)
        var fold: TranscriptFold
        var offset: Int
        if let primed = await index.foldHandoff(atPath: path) {
            (fold, offset) = (primed.fold, primed.offset)
        } else {
            (fold, offset) = (TranscriptFold(sessionID: transcriptID), 0)
        }
        var emittedRunning: Bool? = nil
        var lastGrowth = Date()
        var suppressedUntil = Date.distantPast
        var emittedGoal = fold.goal

        /// Goal changes are emitted even while message emission is suppressed for the bridge's own
        /// runner: the runner streams messages but knows nothing about goals, so there is no
        /// duplicate to guard against — and suppressing here would strand the chip on a goal the
        /// user set from the app.
        func emitGoalIfChanged() {
            guard fold.goal != emittedGoal else { return }
            emittedGoal = fold.goal
            caster.send(.goal(fold.goal))
        }

        /// Status is emitted only on change: a client re-rendering a conversation
        /// once a second for a value that never moved is pure noise, and a
        /// `running`/`idle` pair every tick reads as a turn ending over and over.
        func report(_ running: Bool) async {
            if !running, emittedRunning != true { return }
            guard emittedRunning != running else { return }
            emittedRunning = running
            caster.send(.status(running ? "running" : "idle"))
            if !running { await store.devicePusher.noteExternalIdle() }
        }

        if let mtime = mtime(path), Date().timeIntervalSince(mtime) < Self.idleAfter,
            !TranscriptParser.isTurnClosed(atPath: path)
        {
            await report(true)
            if let open = fold.snapshot.last, open.role == .assistant {
                caster.send(.messageUpserted(open))
            }
        } else if Self.agentsWorking(transcriptPath: path) {
            await report(true)
        }

        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pollInterval)
            guard caster.hasSubscribers else { break }
            guard let size = fileSize(path) else { break }

            if size < offset {
                if let primed = await index.foldHandoff(atPath: path) {
                    (fold, offset) = (primed.fold, primed.offset)
                } else {
                    fold.reset()
                    offset = 0
                }
                continue
            }
            guard size > offset else {
                if await store.hasRunnerTurnInFlight(claudeSessionID: transcriptID) {
                    suppressedUntil = Date().addingTimeInterval(Self.runnerGrace)
                    continue
                }
                guard Date() > suppressedUntil else { continue }
                if Self.agentsWorking(transcriptPath: path) {
                    lastGrowth = Date()
                    await report(true)
                } else if Date().timeIntervalSince(lastGrowth) > Self.idleAfter
                    || TranscriptParser.isTurnClosed(atPath: path)
                {
                    await report(false)
                }
                continue
            }

            let chunk = readChunk(path, from: offset, count: size - offset)
            offset += chunk.count
            let changed = fold.consume(chunk)
            if !changed.isEmpty { lastGrowth = Date() }
            emitGoalIfChanged()

            if await store.hasRunnerTurnInFlight(claudeSessionID: transcriptID) {
                suppressedUntil = Date().addingTimeInterval(Self.runnerGrace)
                continue
            }
            guard Date() > suppressedUntil, !changed.isEmpty else { continue }

            for message in fold.snapshot where changed.contains(message.id) {
                caster.send(.messageUpserted(message))
            }
            if TranscriptParser.isTurnClosed(atPath: path),
                !Self.agentsWorking(transcriptPath: path)
            {
                await report(false)
            } else {
                await report(true)
            }
        }
    }

    /// Whether agents spawned by this session are still writing. A turn that
    /// hands its work to background agents closes in the parent transcript
    /// while the real work runs on in the sidecars — reading only the parent
    /// would call that session finished the moment it delegated.
    private nonisolated static func agentsWorking(transcriptPath: String) -> Bool {
        guard let latest = TranscriptParser.sidecarActivity(transcriptPath: transcriptPath) else {
            return false
        }
        return Date().timeIntervalSince(latest) < TranscriptIndex.subagentActivityWindow
    }

    private nonisolated func fileSize(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
    }

    private nonisolated func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private nonisolated func readChunk(_ path: String, from offset: Int, count: Int) -> Data {
        guard let handle = FileHandle(forReadingAtPath: path) else { return Data() }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return Data() }
        return (try? handle.read(upToCount: count)) ?? Data()
    }
}
