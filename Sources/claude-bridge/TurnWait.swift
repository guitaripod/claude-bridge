import Foundation

/// What `GET /sessions/:id/wait` settles on: nothing to answer with yet (`running`, the hold hit
/// its cap), an ending the person should read (`ended`), or a turn that stopped to ask them
/// something (`needsYou`).
enum TurnWaitState: String, Codable, Sendable {
    case ended
    case needsYou
    case running
}

/// How the turn behind a wait ended, in the same words `LiveActivityDetail` already gave the app —
/// a wire contract shared with every push this bridge sends, so a case is added here and never
/// renamed. `approval` and `lost` are carried for that same reason though this bridge does not yet
/// produce them: it runs Claude with a fixed permission mode, so no turn ever stops on an
/// interactive approval, and a `/wait` answer is always computed fresh rather than recovered from
/// a card that outlived a restart.
enum TurnWaitEnding: String, Codable, Sendable, Equatable {
    case finished
    case answerless
    case failed
    case interrupted
    case cancelled
    case question
    case approval
    case lost

    /// The ending a settled Live Activity card would show, read as this wire's own vocabulary — the
    /// one place `CardDetail.settled` is turned into a `TurnWait`, so the two never drift apart.
    init(settled detail: CardDetail) {
        switch detail {
        case .question: self = .question
        case .interrupted: self = .interrupted
        case .cancelled: self = .cancelled
        case .failed: self = .failed
        case .answerless: self = .answerless
        default: self = .finished
        }
    }
}

/// The body `GET /sessions/:id/wait` answers with, whether it resolved at once or after holding
/// the connection. Every field but `state` and `waited` is omitted rather than written null, so a
/// decoder that has never seen a field this bridge does not yet fill treats it as simply absent.
struct TurnWait: Codable, Sendable, Equatable {
    var state: TurnWaitState
    var waited: Bool
    var ending: TurnWaitEnding?
    var title: String?
    var toolCount: Int?
    var background: Int?
    var duration: TimeInterval?
    var lastMessageID: String?
    var endedAt: Date?

    init(
        state: TurnWaitState, waited: Bool, ending: TurnWaitEnding? = nil, title: String? = nil,
        toolCount: Int? = nil, background: Int? = nil, duration: TimeInterval? = nil,
        lastMessageID: String? = nil, endedAt: Date? = nil
    ) {
        self.state = state
        self.waited = waited
        self.ending = ending
        self.title = title
        self.toolCount = toolCount
        self.background = background
        self.duration = duration
        self.lastMessageID = lastMessageID
        self.endedAt = endedAt
    }
}

/// What a turn left behind once it closed, recorded at the same choke points that settle a Live
/// Activity card (`finishTurn`, `settleFromTranscript`, `markInterrupted`) so `/wait` can answer a
/// session that is already idle without recomputing anything from the transcript.
struct LastTurnEnding: Sendable, Equatable {
    var ending: TurnWaitEnding
    var title: String?
    var toolCount: Int?
    var duration: TimeInterval?
    var lastMessageID: String?
    var endedAt: Date
}

/// The one rule `/sessions/:id/wait` is built from, pure so the route's polling loop and its tests
/// read the same decision: nothing is owed while a turn is genuinely open, and once it is not, a
/// remembered ending reads as `needsYou` exactly when it is a question nobody has answered yet.
enum TurnWaitResolution {
    static func reading(
        turnOpen: Bool, lastEnding: LastTurnEnding?, background: Int?
    ) -> TurnWait? {
        guard !turnOpen else { return nil }
        guard let lastEnding else { return TurnWait(state: .ended, waited: false) }
        return TurnWait(
            state: lastEnding.ending == .question ? .needsYou : .ended, waited: false,
            ending: lastEnding.ending, title: lastEnding.title, toolCount: lastEnding.toolCount,
            background: background, duration: lastEnding.duration,
            lastMessageID: lastEnding.lastMessageID, endedAt: lastEnding.endedAt)
    }

    static func capped() -> TurnWait {
        TurnWait(state: .running, waited: true)
    }
}
