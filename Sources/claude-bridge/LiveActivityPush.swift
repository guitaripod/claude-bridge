import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct LiveActivityRegistration: Codable, Sendable, Equatable {
    var token: String
    var environment: String
    var startedAt: Date
    var title: String
}

/// Where a card's pushes go: APNs in production, a recorder in tests.
protocol LiveActivityTransport: Sendable {
    func pushLiveActivity(
        body: Data, token: String, environment: String, priority: String
    ) async -> (status: Int, reason: String?)
}

extension APNSClient: LiveActivityTransport {
    func pushLiveActivity(
        body: Data, token: String, environment: String, priority: String
    ) async -> (status: Int, reason: String?) {
        await send(
            body: body, token: token, environment: environment, topic: config.topic,
            pushType: "liveactivity", priority: priority)
    }
}

/// What a card says, named rather than written.
///
/// These raw values are the app's `LiveActivityDetail`: the phone's widget writes the words from
/// them in its own language, because a push is written here, in English, while the phone is in a
/// pocket. They are a contract with every app already installed, so a case may be added and never
/// renamed; `phase` is the older contract, the one an app from before the key decodes.
enum CardDetail: String, Sendable {
    case thinking
    case writing
    case tool
    case compacting
    case question
    case approval
    case finished
    case answerless
    case failed
    case noResponse
    case sendFailed
    case interrupted
    case cancelled
    case lost

    var phase: String {
        switch self {
        case .thinking: return "thinking"
        case .writing: return "responding"
        case .tool, .compacting: return "tool"
        case .question, .approval: return "approval"
        case .finished, .answerless, .cancelled, .lost: return "done"
        case .failed, .noResponse, .sendFailed, .interrupted: return "error"
        }
    }

    /// Which card leads when the phone is following several: whatever is waiting on the person,
    /// then whatever is still moving, then what went wrong, and only then what simply finished.
    var relevance: Int {
        switch self {
        case .question, .approval: return 100
        case .thinking, .writing, .tool, .compacting: return 50
        case .answerless, .failed, .noResponse, .sendFailed, .interrupted: return 20
        case .finished, .cancelled, .lost: return 10
        }
    }

    /// The sentence an app from before the key draws instead, in the words it used to be sent.
    func fallback(tool: String?, toolCount: Int, duration: TimeInterval) -> String {
        switch self {
        case .thinking: return "Thinking…"
        case .writing: return "Writing…"
        case .tool: return tool.map { "Running \($0)" } ?? "Running tool"
        case .compacting: return "Compacting…"
        case .question: return "Waiting for your answer"
        case .approval: return "Awaiting your approval"
        case .finished:
            var parts = ["Done in \(PushFormatting.compactDuration(duration))"]
            if toolCount > 0 { parts.append("\(toolCount) tool\(toolCount == 1 ? "" : "s")") }
            return parts.joined(separator: " · ")
        case .answerless: return "Nothing came back"
        case .failed: return "Something went wrong"
        case .noResponse: return "No response"
        case .sendFailed: return "Couldn't send"
        case .interrupted: return "The server stopped mid-answer"
        case .cancelled: return "Cancelled"
        case .lost: return "Open the chat to see how it ended"
        }
    }
}

/// How a turn ended, as the store saw it. A failure the turn reported along the way and a stop
/// somebody pressed are remembered by the card itself and outrank a plain finish.
enum TurnEnding: Sendable, Equatable {
    case finished
    case answerless
    case question
    case interrupted
}

/// One conversation's card as this bridge last drew it.
struct LiveActivityCard: Codable, Sendable, Equatable {
    var sessionID: String
    var registration: LiveActivityRegistration
    var title: String
    var startedAt: Date
    var detail: String
    var tool: String?
    var toolCount: Int
    var background: Int
    /// The turn reported a failure before it ended.
    var failed: Bool
    /// Somebody pressed stop on the turn.
    var stopped: Bool
    /// A turn is running on the card right now. A card registered after its turn had already
    /// ended has none, and the next turn to start takes it over from the beginning.
    var turnOpen: Bool
    var endedAt: Date?
    var lastPushAt: Date
    /// When the newest thing this card was told happened. The store hands every call its own
    /// moment, taken where the event happened rather than where it lands here, so a call that was
    /// overtaken on the way — a turn's ending arriving after the next turn's start — is refused
    /// instead of undoing what came after it.
    var lastEventAt: Date

    var isSettled: Bool { endedAt != nil }
    var reading: CardDetail { CardDetail(rawValue: detail) ?? .thinking }
}

/// Drives the app's Live Activities over APNs while the phone is suspended: the app registers each
/// card's push token, and the conversation's turns push the same content-state shape the app
/// renders locally. ActivityKit decodes the payload with a default JSONDecoder, so dates in the
/// content state travel as seconds since the 2001 reference date.
///
/// A card outlives its turn. The end of a turn is news until somebody reads it, so the card
/// settles in place — how the turn ended, how long it ran — and stays live in the Dynamic Island
/// for `island` and on the Lock Screen for `lockScreen`, the same two clocks the app keeps; the
/// conversation's next turn takes it back rather than leaving the phone to stack a second one.
/// Cards persist beside the session store, so a restart neither forgets a card waiting to be read
/// nor leaves a live one standing forever over a turn that did not survive it.
actor LiveActivityPusher {
    static let island: TimeInterval = 60 * 60
    static let lockScreen: TimeInterval = 4 * 60 * 60
    static let staleAfter: TimeInterval = 30 * 60
    static let heartbeatAfter: TimeInterval = 10 * 60
    static let progressGap: TimeInterval = 8

    private static let deadTokenReasons: Set<String> = [
        "BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic", "ExpiredToken",
    ]

    private let transport: (any LiveActivityTransport)?
    private let activitiesURL: URL?
    private var cards: [String: LiveActivityCard]
    private var countedTools: [String: Set<String>] = [:]
    private var deliveries: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    init(client: APNSClient?, activitiesURL: URL? = nil) {
        self.init(transport: client, activitiesURL: activitiesURL)
    }

    init(transport: (any LiveActivityTransport)?, activitiesURL: URL? = nil) {
        self.transport = transport
        self.activitiesURL = activitiesURL
        cards = Self.load(from: activitiesURL)
    }

    var enabled: Bool { transport != nil }

    func card(_ sessionID: String) -> LiveActivityCard? { cards[sessionID] }

    /// A card the app just started or took back for a new turn. Nothing is pushed: the app drew
    /// it a moment ago.
    func register(_ registration: LiveActivityRegistration, sessionID: String, turnOpen: Bool) {
        let previous = cards[sessionID]
        let sameTurn = previous.map { !$0.isSettled && $0.turnOpen && turnOpen } ?? false
        cards[sessionID] = LiveActivityCard(
            sessionID: sessionID, registration: registration,
            title: registration.title.isEmpty ? (previous?.title ?? "") : registration.title,
            startedAt: registration.startedAt,
            detail: sameTurn ? previous?.detail ?? CardDetail.thinking.rawValue
                : CardDetail.thinking.rawValue,
            tool: sameTurn ? previous?.tool : nil,
            toolCount: sameTurn ? previous?.toolCount ?? 0 : 0,
            background: previous?.background ?? 0, failed: sameTurn && previous?.failed == true,
            stopped: false, turnOpen: turnOpen, endedAt: nil, lastPushAt: Date(),
            lastEventAt: Date())
        if !sameTurn { countedTools[sessionID] = nil }
        persist()
        log("token registered for \(sessionID) (\(registration.environment))")
    }

    func noteEvent(_ event: BridgeEvent, sessionID: String, now: Date = Date()) {
        guard transport != nil, var card = cards[sessionID], now >= card.lastEventAt else { return }
        card.lastEventAt = now
        switch event {
        case .status(let status):
            guard status == "running", card.isSettled || !card.turnOpen else { return }
            revive(&card, now: now)
            cards[sessionID] = card
            persist()
            push(card, event: "update", priority: "10", now: now)
            return
        case .background(let work):
            let tasks = work?.tasks ?? 0
            guard tasks != card.background else { return }
            card.background = tasks
            cards[sessionID] = card
            guard card.isSettled else { return }
            persist()
            push(card, event: "update", priority: "5", now: now)
            return
        case .error:
            guard !card.isSettled else { return }
            card.failed = true
            cards[sessionID] = card
            return
        default:
            break
        }
        guard !card.isSettled else { return }
        let before = card.detail
        switch event {
        case .toolUpserted(_, let tool):
            guard tool.status == .running else { return }
            card.detail =
                (tool.name.caseInsensitiveCompare("AskUserQuestion") == .orderedSame
                    ? CardDetail.question : CardDetail.tool).rawValue
            card.tool = tool.name
            if countedTools[sessionID, default: []].insert(tool.id).inserted {
                card.toolCount += 1
            }
        case .partTextDelta:
            card.detail = CardDetail.writing.rawValue
        case .compaction(let phase, _):
            card.detail = (phase == "started" ? CardDetail.compacting : .thinking).rawValue
        default:
            return
        }
        let changed = card.detail != before
        guard changed || now.timeIntervalSince(card.lastPushAt) > Self.progressGap else {
            cards[sessionID] = card
            return
        }
        card.lastPushAt = now
        cards[sessionID] = card
        push(card, event: "update", priority: changed ? "10" : "5", now: now)
    }

    /// Somebody pressed stop: the turn that ends next ended because they asked it to.
    func noteStopped(sessionID: String, now: Date = Date()) {
        guard var card = cards[sessionID], !card.isSettled, now >= card.lastEventAt else { return }
        card.stopped = true
        card.lastEventAt = now
        cards[sessionID] = card
    }

    /// The turn ended. The card settles on how, and stays for somebody to read it.
    func endTurn(
        sessionID: String, toolCount: Int?, ending: TurnEnding, title: String? = nil,
        now: Date = Date()
    ) {
        guard transport != nil, var card = cards[sessionID], now >= card.lastEventAt else { return }
        card.lastEventAt = now
        if let title, !title.isEmpty { card.title = title }
        card.toolCount = max(card.toolCount, toolCount ?? 0)
        card.detail = Self.settledDetail(card, ending).rawValue
        card.tool = nil
        card.turnOpen = false
        if card.endedAt == nil { card.endedAt = now }
        card.lastPushAt = now
        cards[sessionID] = card
        countedTools[sessionID] = nil
        persist()
        push(card, event: "update", priority: "10", now: now)
    }

    /// The conversation has a better name than the card started with.
    func retitle(sessionID: String, title: String, now: Date = Date()) {
        guard transport != nil, !title.isEmpty, var card = cards[sessionID], card.title != title
        else { return }
        card.title = title
        cards[sessionID] = card
        persist()
        guard card.isSettled else { return }
        push(card, event: "update", priority: "5", now: now)
    }

    /// Picks the cards back up after a restart. A settled card keeps waiting to be read on its own
    /// clock. A live card whose turn the journal knows is left to the recovery that reads the
    /// journal; any other live card followed a turn that did not survive the restart and nobody
    /// can say how it ended, so it settles saying exactly that.
    func restore(journaled: Set<String>, now: Date = Date()) {
        guard transport != nil else {
            if !cards.isEmpty {
                cards = [:]
                persist()
            }
            return
        }
        for (sessionID, card) in cards
        where !card.isSettled && card.turnOpen && !journaled.contains(sessionID) {
            var lost = card
            lost.detail = CardDetail.lost.rawValue
            lost.tool = nil
            lost.turnOpen = false
            lost.endedAt = now
            lost.lastPushAt = now
            cards[sessionID] = lost
            push(lost, event: "update", priority: "10", now: now)
            log("settled a card whose turn did not survive the restart (\(sessionID))")
        }
        persist()
        tick(now: now, inFlight: [])
    }

    /// Everything a clock moves along: a live card with nothing new to say is written again before
    /// the phone would call it stale, as long as its turn really is running; a settled card nobody
    /// came for leaves the Dynamic Island, and stays on the Lock Screen until its time there is up.
    func tick(now: Date = Date(), inFlight: Set<String>) {
        for (sessionID, card) in cards {
            if let endedAt = card.endedAt {
                guard now >= endedAt.addingTimeInterval(Self.island) else { continue }
                retire(card, now: now)
            } else if card.turnOpen, inFlight.contains(sessionID),
                now.timeIntervalSince(card.lastPushAt) >= Self.heartbeatAfter
            {
                var refreshed = card
                refreshed.lastPushAt = now
                cards[sessionID] = refreshed
                push(refreshed, event: "update", priority: "5", now: now)
            }
        }
    }

    /// Runs `tick` for the life of the process.
    func runClock(inFlight: @escaping @Sendable () async -> Set<String>) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            tick(now: Date(), inFlight: await inFlight())
        }
    }

    private func retire(_ card: LiveActivityCard, now: Date) {
        guard let endedAt = card.endedAt else { return }
        cards[card.sessionID] = nil
        countedTools[card.sessionID] = nil
        persist()
        let leaves = endedAt.addingTimeInterval(Self.lockScreen)
        push(card, event: "end", priority: "10", now: now, dismissal: max(leaves, now))
        log("card left the Dynamic Island for \(card.sessionID)")
    }

    private func revive(_ card: inout LiveActivityCard, now: Date) {
        card.startedAt = now
        card.detail = CardDetail.thinking.rawValue
        card.tool = nil
        card.toolCount = 0
        card.failed = false
        card.stopped = false
        card.turnOpen = true
        card.endedAt = nil
        card.lastPushAt = now
        countedTools[card.sessionID] = nil
    }

    private static func settledDetail(_ card: LiveActivityCard, _ ending: TurnEnding) -> CardDetail {
        switch ending {
        case .question: return .question
        case .interrupted: return .interrupted
        case .finished, .answerless:
            if card.stopped { return .cancelled }
            if card.failed { return .failed }
            return ending == .answerless ? .answerless : .finished
        }
    }

    static func payload(
        _ card: LiveActivityCard, event: String, now: Date, dismissal: Date? = nil
    ) -> [String: Any] {
        let reading = card.reading
        let duration = (card.endedAt ?? now).timeIntervalSince(card.startedAt)
        var state: [String: Any] = [
            "phase": reading.phase,
            "statusText": reading.fallback(
                tool: card.tool, toolCount: card.toolCount, duration: duration),
            "toolCount": card.toolCount,
            "startedAt": card.startedAt.timeIntervalSinceReferenceDate,
            "title": card.title,
            "detail": reading.rawValue,
        ]
        if let tool = card.tool, !card.isSettled { state["lastTool"] = tool }
        if let endedAt = card.endedAt { state["endedAt"] = endedAt.timeIntervalSinceReferenceDate }
        if card.isSettled, card.background > 0 { state["background"] = card.background }
        var aps: [String: Any] = [
            "timestamp": Int(now.timeIntervalSince1970),
            "event": event,
            "content-state": state,
            "relevance-score": reading.relevance,
        ]
        if !card.isSettled {
            aps["stale-date"] = Int(now.addingTimeInterval(staleAfter).timeIntervalSince1970)
        }
        if let dismissal { aps["dismissal-date"] = Int(dismissal.timeIntervalSince1970) }
        return ["aps": aps]
    }

    /// Sends in order, one conversation at a time: an update that raced ahead of the one before it
    /// would leave the phone showing the older of the two.
    private func push(
        _ card: LiveActivityCard, event: String, priority: String, now: Date,
        dismissal: Date? = nil
    ) {
        guard let transport,
            let body = try? JSONSerialization.data(
                withJSONObject: Self.payload(card, event: event, now: now, dismissal: dismissal))
        else { return }
        let sessionID = card.sessionID
        let registration = card.registration
        let previous = deliveries[sessionID]?.task
        let id = UUID()
        let task = Task {
            await previous?.value
            let (status, reason) = await transport.pushLiveActivity(
                body: body, token: registration.token, environment: registration.environment,
                priority: priority)
            self.delivered(
                sessionID: sessionID, token: registration.token, event: event, status: status,
                reason: reason)
            if self.deliveries[sessionID]?.id == id { self.deliveries[sessionID] = nil }
        }
        deliveries[sessionID] = (id, task)
    }

    /// Waits until every push already asked for has been answered — for a test, which must read
    /// what was sent rather than what is about to be.
    func settled() async {
        for delivery in deliveries.values { await delivery.task.value }
    }

    /// A card the phone no longer has — ended, swiped away, or the app reinstalled — answers with
    /// a dead token, and every push after that is a request APNs will refuse again.
    private func delivered(
        sessionID: String, token: String, event: String, status: Int, reason: String?
    ) {
        if status == 200 {
            log("\(event) push ok for \(sessionID)")
            return
        }
        log("\(event) push failed \(status) for \(sessionID): \(reason ?? "no reason")")
        let dead = status == 410 || Self.deadTokenReasons.contains(reason ?? "")
        guard dead, cards[sessionID]?.registration.token == token else { return }
        cards[sessionID] = nil
        countedTools[sessionID] = nil
        persist()
        log("dropped the card for \(sessionID): its token is dead")
    }

    private struct LegacyStoredActivity: Codable {
        var sessionID: String
        var registration: LiveActivityRegistration
    }

    private static func load(from url: URL?) -> [String: LiveActivityCard] {
        guard let url, let data = try? Data(contentsOf: url) else { return [:] }
        if let stored = try? JSONCoding.decoder.decode([LiveActivityCard].self, from: data) {
            return Dictionary(stored.map { ($0.sessionID, $0) }, uniquingKeysWith: { _, new in new })
        }
        guard let legacy = try? JSONCoding.decoder.decode([LegacyStoredActivity].self, from: data)
        else { return [:] }
        return Dictionary(
            legacy.map { stored in
                (
                    stored.sessionID,
                    LiveActivityCard(
                        sessionID: stored.sessionID, registration: stored.registration,
                        title: stored.registration.title, startedAt: stored.registration.startedAt,
                        detail: CardDetail.thinking.rawValue, tool: nil, toolCount: 0,
                        background: 0, failed: false, stopped: false, turnOpen: true,
                        endedAt: nil, lastPushAt: stored.registration.startedAt,
                        lastEventAt: stored.registration.startedAt)
                )
            }, uniquingKeysWith: { _, new in new })
    }

    private func persist() {
        guard let activitiesURL else { return }
        let snapshot = cards.values.sorted { $0.sessionID < $1.sessionID }
        guard let data = try? JSONCoding.encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: activitiesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: activitiesURL, options: .atomic)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[live-activity] \(message)\n".utf8))
    }
}
