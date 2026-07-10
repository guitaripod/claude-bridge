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
        var fold = TranscriptFold()
        var offset = primeSilently(&fold, path: path)
        var emittedRunning = false
        var lastGrowth = Date()
        var suppressedUntil = Date.distantPast

        if let mtime = mtime(path), Date().timeIntervalSince(mtime) < Self.idleAfter {
            caster.send(.status("running"))
            emittedRunning = true
            if let open = fold.snapshot.last, open.role == .assistant {
                caster.send(.messageUpserted(open))
            }
        }

        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pollInterval)
            guard caster.hasSubscribers else { break }
            guard let size = fileSize(path) else { break }

            if size < offset {
                fold.reset()
                offset = primeSilently(&fold, path: path)
                continue
            }
            guard size > offset else {
                if Date() > suppressedUntil,
                    let sidecar = TranscriptParser.sidecarActivity(transcriptPath: path),
                    sidecar > lastGrowth
                {
                    lastGrowth = sidecar
                    if !emittedRunning {
                        caster.send(.status("running"))
                        emittedRunning = true
                    }
                }
                if emittedRunning, Date().timeIntervalSince(lastGrowth) > Self.idleAfter {
                    caster.send(.status("idle"))
                    emittedRunning = false
                }
                continue
            }

            let chunk = readChunk(path, from: offset, count: size - offset)
            offset += chunk.count
            let changed = fold.consume(chunk)
            lastGrowth = Date()

            if await store.hasRunnerTurnInFlight(claudeSessionID: transcriptID) {
                suppressedUntil = Date().addingTimeInterval(Self.runnerGrace)
                continue
            }
            guard Date() > suppressedUntil, !changed.isEmpty else { continue }

            for message in fold.snapshot where changed.contains(message.id) {
                caster.send(.messageUpserted(message))
            }
            if !emittedRunning {
                caster.send(.status("running"))
                emittedRunning = true
            }
        }
    }

    private nonisolated func primeSilently(_ fold: inout TranscriptFold, path: String) -> Int {
        guard let data = FileManager.default.contents(atPath: path) else { return 0 }
        _ = fold.consume(data)
        return data.count
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
