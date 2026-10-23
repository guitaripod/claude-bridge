import Foundation

/// One message waiting behind a running turn, as every client of the conversation sees it. The
/// bytes of its attachments are not here: they arrive once with the enqueue and live on disk.
struct QueuedItem: Codable, Sendable, Equatable {
    static let promptKind = "prompt"
    static let commandKind = "command"

    var id: String
    var text: String
    var kind: String
    var model: String?
    var effort: String?
    var attachments: [QueueAttachment]
    var createdAt: Date
}

/// What a queued item's attachment is, without its bytes.
struct QueueAttachment: Codable, Sendable, Equatable {
    var mime: String
    var filename: String
    var size: Int
}

/// A queued item and the files the bridge kept for it, which are what the user message shows and
/// what the CLI is pointed at when the item starts.
struct HeldQueueItem: Codable, Sendable {
    var item: QueuedItem
    var files: [FileRef]
}

/// Everything a client needs to draw the shared queue: the items in arrival order, and whether
/// draining is held back after a Stop or a restart.
struct QueueSnapshot: Codable, Sendable, Equatable {
    var queue: [QueuedItem]
    var paused: Bool
}

/// One session's queue as it is written to the journal.
struct PersistedQueue: Codable, Sendable {
    var items: [HeldQueueItem]
    var paused: Bool
}

struct EnqueueRequest: Codable, Sendable {
    var id: String
    var text: String
    var kind: String?
    var model: String?
    var effort: String?
    var attachments: [SendAttachment]?
}

struct EditQueuedRequest: Codable, Sendable {
    var text: String?
    var model: String?
    var effort: String?
}

/// The answer to an enqueue: whether the item went straight into a turn, and the queue after it.
struct EnqueueAccepted: Encodable, Sendable {
    let started: Bool
    let queue: [QueuedItem]
    let paused: Bool
}

/// What the store did with an enqueue.
enum EnqueueOutcome: Sendable, Equatable {
    case accepted(started: Bool, snapshot: QueueSnapshot)
    case unknownSession
    case invalid(String)
}

/// What the store did with an edit, a cancel or a resume.
enum QueueChangeOutcome: Sendable, Equatable {
    case changed(QueueSnapshot)
    case alreadyStarted
    case unknownSession
}

enum QueueRefusal {
    static let alreadyStarted = "already_started"
}
