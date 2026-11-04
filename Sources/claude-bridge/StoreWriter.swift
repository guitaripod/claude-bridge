import Foundation

/// The session store on disk, written away from the store's actor and re-encoding only what moved.
///
/// The file holds every conversation this bridge keeps, messages and all — a quarter of a gigabyte
/// on a machine that has been used for a while — and it used to be encoded whole on the store's
/// own actor every time anything settled. That took over a second, and for that second no frame of
/// any running turn on the machine could be published: every live answer stalled whenever any
/// turn anywhere ended. Now the store hands over a snapshot, which costs nothing because its
/// sessions share their storage with the store's, and the writer encodes it on a thread of its own,
/// reusing the bytes of every conversation that has not changed since the last write.
///
/// Writes are ordered by the generation the store stamps on each snapshot, so a write that lost a
/// race to a newer one is dropped rather than putting an older store back on disk. The format is
/// the one it always was, a JSON array of sessions, so any bridge can read what this one wrote.
final class StoreWriter: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var written: [String: (session: Session, bytes: Data)] = [:]
    private var writtenGeneration = 0

    init(url: URL) {
        self.url = url
    }

    /// Puts `snapshot` on disk before returning, unless a newer generation already got there.
    func write(_ snapshot: [Session], generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard generation > writtenGeneration else { return }
        var encoded: [String: (session: Session, bytes: Data)] = [:]
        encoded.reserveCapacity(snapshot.count)
        var body = Data("[".utf8)
        var first = true
        for session in snapshot {
            let bytes: Data
            if let held = written[session.id], held.session == session {
                bytes = held.bytes
            } else if let fresh = try? JSONCoding.encoder.encode(session) {
                bytes = fresh
            } else {
                continue
            }
            if !first { body.append(UInt8(ascii: ",")) }
            first = false
            body.append(bytes)
            encoded[session.id] = (session, bytes)
        }
        body.append(UInt8(ascii: "]"))
        written = encoded
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? body.write(to: url, options: .atomic)) != nil else { return }
        writtenGeneration = generation
    }
}
