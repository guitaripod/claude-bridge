import Foundation

/// What a device asked to be pushed about, as it registered. Mirrors Tailscode's `NoticeRules`:
/// when finished work is news, the shortest work worth a push, whether approvals and questions
/// are, and the chats whose finished work stays quiet. A device that registered before the rules
/// existed gets `standard`, which is what makes an old phone stop hearing about every turn too.
struct DeviceRules: Codable, Sendable, Equatable {
    enum Finish: String, Codable, Sendable {
        case settled
        case everyTurn
        case failures
        case never
    }

    var finish: Finish
    var minimumWork: Int?
    var needsYou: Bool?
    var muted: [String]?

    static let standard = DeviceRules(finish: .settled)

    init(finish: Finish, minimumWork: Int? = nil, needsYou: Bool? = nil, muted: [String]? = nil) {
        self.finish = finish
        self.minimumWork = minimumWork
        self.needsYou = needsYou
        self.muted = muted
    }

    private enum CodingKeys: String, CodingKey {
        case finish, minimumWork, needsYou, muted
    }

    /// A choice this bridge does not know reads as the default rather than failing the whole
    /// registration: a newer phone must never lose its pushes to an older bridge.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        finish =
            (try? container.decodeIfPresent(String.self, forKey: .finish))
            .flatMap(Finish.init(rawValue:)) ?? .settled
        minimumWork = try? container.decodeIfPresent(Int.self, forKey: .minimumWork)
        needsYou = try? container.decodeIfPresent(Bool.self, forKey: .needsYou)
        muted = try? container.decodeIfPresent([String].self, forKey: .muted)
    }

    var hearsAsks: Bool { needsYou ?? true }

    /// Whether finished work earns a push: what the person chose, how long the work ran and
    /// whether the chat is muted. A failure ignores the minimum.
    func admits(failed: Bool, length: TimeInterval, sessionID: String) -> Bool {
        guard !(muted ?? []).contains(sessionID) else { return false }
        switch finish {
        case .never: return false
        case .failures: return failed
        case .settled, .everyTurn: return failed || length >= TimeInterval(minimumWork ?? 0)
        }
    }

    /// Whether this device hears a finished turn the moment it closes, or only once its work is over.
    var hearsEveryTurn: Bool { finish == .everyTurn }
}

/// When a stretch of work is over, as opposed to when a turn is — the rule Tailscode's
/// `WorkSettle` states for the phone, kept here for the pushes this bridge sends.
///
/// A turn ending frees the prompt. Claude may still be carrying a command, an agent or a workflow
/// it backgrounded; a queued message may be about to start the next turn; the CLI may be about to
/// start one itself because that background work just finished. The work is over when none of
/// that is true and it has stayed so for `grace`, and a push about it says how long the whole
/// stretch took rather than the last of its turns.
enum WorkSettle {
    static let grace: TimeInterval = 10
}

/// The latest turn of a stretch of work, waiting to find out whether it was the last.
struct PendingEnding: @unchecked Sendable {
    var title: String
    var claudeID: String
    var failed: Bool
    var ending: TurnWaitEnding
    var endedAt: Date
    var lastMessageID: String?
    var notice: NoticePush.Additions
}

/// A stretch of work that came to its end.
struct SettledWork: Sendable, Equatable {
    var ending: TurnWaitEnding
    var failed: Bool
    var title: String
    var length: TimeInterval
    var tools: Int
    var endedAt: Date
    var lastMessageID: String?
}

/// What a wait held for settled work is told.
enum SettleReading: Sendable, Equatable {
    /// Something is running, carried, queued, or the grace has not run out.
    case working
    /// Nothing is going on; the stretch that ended, when this bridge followed one.
    case settled(SettledWork?)
}

/// Every stretch of work the store is following, from its first turn to the moment nothing is left.
/// Pure and clock-injected so the rule can be read and tested apart from the processes.
struct WorkSpans: Sendable {
    struct Span: @unchecked Sendable {
        var began: Date
        var tools: Int
        var ending: PendingEnding?
        /// When the last thing that could start a turn stopped: the latest turn's end, or the
        /// background work it left finishing without a turn of its own.
        var quietSince: Date?
    }

    private(set) var spans: [String: Span] = [:]
    private(set) var settled: [String: SettledWork] = [:]

    /// A turn closed. The stretch it belongs to began with the first turn since the last one that
    /// settled, so its length outlasts any one turn in it.
    mutating func turnEnded(_ id: String, began: Date, tools: Int, ending: PendingEnding) {
        var span = spans[id] ?? Span(began: began, tools: 0)
        span.began = min(span.began, began)
        span.tools += tools
        span.ending = ending
        span.quietSince = ending.endedAt
        spans[id] = span
    }

    /// The turn stopped to ask the person something. Whatever follows their answer is new work.
    mutating func waitsOnPerson(_ id: String) {
        spans[id] = nil
    }

    /// Background work stopped without a turn closing: the grace runs from here.
    mutating func workStopped(_ id: String, at now: Date) {
        guard spans[id]?.ending != nil else { return }
        spans[id]?.quietSince = now
    }

    /// When the stretch is owed a settle check, if it is waiting for one.
    func due(_ id: String) -> Date? {
        spans[id]?.quietSince.map { $0.addingTimeInterval(WorkSettle.grace) }
    }

    func reading(_ id: String, working: Bool, now: Date) -> SettleReading {
        guard !working else { return .working }
        guard let span = spans[id], let ending = span.ending else { return .settled(settled[id]) }
        guard let due = due(id), now >= due else { return .working }
        return .settled(Self.settledWork(span, ending))
    }

    /// Closes the stretch once nothing runs and the grace has passed, and hands back what a push
    /// about it carries. Nil while there is nothing to close or it is not yet time.
    mutating func settle(_ id: String, working: Bool, now: Date) -> (SettledWork, PendingEnding)? {
        guard !working, let span = spans[id], let ending = span.ending, let due = due(id),
            now >= due
        else { return nil }
        let work = Self.settledWork(span, ending)
        spans[id] = nil
        settled[id] = work
        return (work, ending)
    }

    /// The stretches waiting for a settle check, for the sweep that catches whatever ended
    /// without telling anything.
    var waiting: [String] { spans.filter { $0.value.ending != nil }.map(\.key) }

    /// The stretch ends when the work did: the last turn's end, or later, when background work
    /// it left behind finished without a turn of its own.
    private static func settledWork(_ span: Span, _ ending: PendingEnding) -> SettledWork {
        let ended = max(ending.endedAt, span.quietSince ?? ending.endedAt)
        return SettledWork(
            ending: ending.ending, failed: ending.failed, title: ending.title,
            length: max(0, ended.timeIntervalSince(span.began)), tools: span.tools,
            endedAt: ended, lastMessageID: ending.lastMessageID)
    }
}
