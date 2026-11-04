import Foundation

/// The session store on disk, written away from the store's actor, one conversation per file.
///
/// The store used to be one file holding every conversation with its messages — a quarter of a
/// gigabyte on a machine that has been used for a while — encoded whole on the store's own actor
/// and rewritten whole every time anything settled: over a second during which no frame of any
/// running turn on the machine could be published, and gigabytes an hour written to the disk to
/// record one turn's change. Now `sessions.json` is the index — every session as it was, with its
/// messages left out — and each conversation's messages live in `conversations/<id>.json`, written
/// only when they changed. The store hands over a snapshot, which costs nothing because its sessions
/// share their storage with the store's, and the writer does the rest on a thread of its own.
///
/// Writes are ordered by the generation the store stamps on each snapshot, so a write that lost a
/// race to a newer one is dropped rather than putting an older store back on disk — a newer one
/// that failed included, since the next change writes again. A bridge from before this layout
/// reads the index and finds each conversation's settings and no messages, which the transcripts on
/// disk still hold; a store from before it is read whole and split on its first write.
final class StoreWriter: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var written: [String: [Message]] = [:]
    private var writtenGeneration = 0

    init(url: URL) {
        self.url = url
    }

    /// Where a conversation's messages are kept beside the index at `store`.
    static func messagesURL(for id: String, besides store: URL) -> URL {
        let safe = String(id.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? Character(scalar) : "_"
        })
        return directory(besides: store).appendingPathComponent(safe + ".json")
    }

    static func directory(besides store: URL) -> URL {
        store.deletingLastPathComponent().appendingPathComponent("conversations")
    }

    /// Puts `snapshot` on disk before returning, unless a newer generation already got there.
    func write(_ snapshot: [Session], generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard generation > writtenGeneration else { return }
        writtenGeneration = generation
        let folder = Self.directory(besides: url)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var kept: [String: [Message]] = [:]
        kept.reserveCapacity(snapshot.count)
        var index: [Session] = []
        index.reserveCapacity(snapshot.count)
        for session in snapshot {
            let file = Self.messagesURL(for: session.id, besides: url)
            var landed = true
            if written[session.id] != session.messages
                || !FileManager.default.fileExists(atPath: file.path)
            {
                landed = (try? JSONCoding.encoder.encode(session.messages))
                    .map { (try? $0.write(to: file, options: .atomic)) != nil } ?? false
            }
            kept[session.id] = landed ? session.messages : written[session.id] ?? []
            var entry = session
            entry.messages = []
            index.append(entry)
        }
        for gone in Set(written.keys).subtracting(kept.keys) {
            try? FileManager.default.removeItem(at: Self.messagesURL(for: gone, besides: url))
        }
        written = kept
        guard let data = try? JSONCoding.encoder.encode(index) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The store as the index and the conversation files hold it. A session whose messages have no
    /// file yet keeps the ones the index itself carried, which is how a store written before the
    /// split is read.
    static func load(from url: URL) -> [Session]? {
        guard let data = try? Data(contentsOf: url),
            let index = try? JSONCoding.decoder.decode([Session].self, from: data)
        else { return nil }
        return index.map { entry in
            var session = entry
            let file = messagesURL(for: entry.id, besides: url)
            if let stored = try? Data(contentsOf: file),
                let messages = try? JSONCoding.decoder.decode([Message].self, from: stored)
            {
                session.messages = messages
            }
            return session
        }
    }
}
