import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct LiveActivityRegistration: Codable, Sendable, Equatable {
    var token: String
    var environment: String
    var startedAt: Date
    var title: String
    /// What the person asked a card to do when its turn ends: `silent` alerts without a sound so
    /// the Dynamic Island opens on how it ended, `sound` alerts with one, absent settles it in
    /// place. Sent by Tailscode from the build that reads the brief; older apps send none.
    var endAlert: String?
    /// Which installation the card is on. Two devices following one conversation each hold a card
    /// of their own, and both are pushed; absent from apps before it, which read as one device.
    var deviceID: String?

    /// Whether this registration is the same card on the same installation as `other`: the same
    /// device when both say which. An app from before the device's name followed a conversation
    /// on one device only, so two registrations that name none are the same card with its token
    /// handed over again.
    func isSameCard(as other: LiveActivityRegistration) -> Bool {
        if let deviceID, let otherID = other.deviceID { return deviceID == otherID }
        return deviceID == nil && other.deviceID == nil
    }
}

/// How this bridge may start a Live Activity on one installation by itself: its push-to-start
/// token, what it calls this machine and which profile that is, whether it follows turns started
/// elsewhere at all, how many cards may stand there at once and the chats it muted. Handed over
/// with the device's push registration, and forgotten with it.
struct LiveActivityStarter: Codable, Sendable, Equatable {
    var token: String
    var deviceID: String
    var profileID: String
    var profileName: String
    var follows: Bool
    var cardLimit: Int?
    var muted: [String]?
    var environment: String = "production"
    var lastSeenAt: Date = Date()
    /// The device's own wish to stay quiet while its person is at a desk, and its patience, taken
    /// from the rules it registered with rather than from the starter it sent.
    var quietAtDesk: Bool?
    var awayAfter: Int?

    private enum CodingKeys: String, CodingKey {
        case token, deviceID, profileID, profileName, follows, cardLimit, muted, environment, lastSeenAt
        case quietAtDesk, awayAfter
    }

    init(
        token: String, deviceID: String, profileID: String, profileName: String, follows: Bool,
        cardLimit: Int? = nil, muted: [String]? = nil, environment: String = "production",
        lastSeenAt: Date = Date()
    ) {
        self.token = token
        self.deviceID = deviceID
        self.profileID = profileID
        self.profileName = profileName
        self.follows = follows
        self.cardLimit = cardLimit
        self.muted = muted
        self.environment = environment
        self.lastSeenAt = lastSeenAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        token = try values.decode(String.self, forKey: .token)
        deviceID = try values.decode(String.self, forKey: .deviceID)
        profileID = try values.decode(String.self, forKey: .profileID)
        profileName = try values.decode(String.self, forKey: .profileName)
        follows = try values.decodeIfPresent(Bool.self, forKey: .follows) ?? true
        cardLimit = try values.decodeIfPresent(Int.self, forKey: .cardLimit)
        muted = try values.decodeIfPresent([String].self, forKey: .muted)
        environment = try values.decodeIfPresent(String.self, forKey: .environment) ?? "production"
        lastSeenAt = try values.decodeIfPresent(Date.self, forKey: .lastSeenAt) ?? Date()
        quietAtDesk = try values.decodeIfPresent(Bool.self, forKey: .quietAtDesk)
        awayAfter = try values.decodeIfPresent(Int.self, forKey: .awayAfter)
    }

    /// Takes the desk wish from the rules the device registered with.
    mutating func adopt(_ rules: DeviceRules?) {
        quietAtDesk = rules?.quietAtDesk
        awayAfter = rules?.awayAfter
    }

    func follows(_ sessionID: String) -> Bool {
        follows && !(muted ?? []).contains(sessionID)
    }
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

    /// The words a started card's alert says on an Apple Watch, as the app's own catalog holds them.
    var startKey: String {
        switch self {
        case .question, .approval: return "Needs you"
        case .thinking: return "Thinking"
        default: return "Working"
        }
    }

    /// The words an ending's alert says on an Apple Watch, as the key the app's own catalog holds
    /// them under, so the watch reads them in the phone's language.
    var alertKey: String {
        switch self {
        case .finished: return "Done"
        case .question: return "Waiting for your answer"
        case .answerless: return "Nothing came back"
        case .failed: return "Something went wrong"
        case .noResponse: return "No response"
        case .sendFailed: return "Couldn't send"
        case .interrupted: return "The server stopped mid-answer"
        case .lost: return "Open the chat to see how it ended"
        case .thinking, .writing, .tool, .compacting, .approval, .cancelled: return "Done"
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

extension CardDetail {
    /// How a turn's ending reads once it settles — the one place that decides it, so a Live
    /// Activity card and a `/wait` answer with no card at all read a stop or a failure the same
    /// way. A stop somebody pressed and a failure the turn reported along the way outrank a plain
    /// finish; a question or an interruption are what they are regardless of either.
    static func settled(ending: TurnEnding, stopped: Bool, failed: Bool) -> CardDetail {
        switch ending {
        case .question: return .question
        case .interrupted: return .interrupted
        case .finished, .answerless:
            if stopped { return .cancelled }
            if failed { return .failed }
            return ending == .answerless ? .answerless : .finished
        }
    }
}

/// One conversation's card as this bridge last drew it.
struct LiveActivityCard: Codable, Sendable, Equatable {
    var sessionID: String
    /// Every installation following the conversation, each with the token of its own card. Empty
    /// for a turn no device has a card for yet: the card is kept from the turn's start so a device
    /// this bridge starts one on, or one that registers late, joins a turn whose story is whole.
    var registrations: [LiveActivityRegistration]
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
    /// What the card says beyond its line. Optional so a card stored by an older bridge loads.
    var brief: CardBrief?

    var isSettled: Bool { endedAt != nil }
    var reading: CardDetail { CardDetail(rawValue: detail) ?? .thinking }

    init(
        sessionID: String, registrations: [LiveActivityRegistration], title: String,
        startedAt: Date, detail: String, tool: String?, toolCount: Int, background: Int,
        failed: Bool, stopped: Bool, turnOpen: Bool, endedAt: Date?, lastPushAt: Date,
        lastEventAt: Date, brief: CardBrief? = nil
    ) {
        self.sessionID = sessionID
        self.registrations = registrations
        self.title = title
        self.startedAt = startedAt
        self.detail = detail
        self.tool = tool
        self.toolCount = toolCount
        self.background = background
        self.failed = failed
        self.stopped = stopped
        self.turnOpen = turnOpen
        self.endedAt = endedAt
        self.lastPushAt = lastPushAt
        self.lastEventAt = lastEventAt
        self.brief = brief
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, registrations, registration, title, startedAt, detail, tool, toolCount
        case background, failed, stopped, turnOpen, endedAt, lastPushAt, lastEventAt, brief
    }

    /// Reads a card stored by a bridge that kept one registration per card, as a card with one.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        if let many = try values.decodeIfPresent([LiveActivityRegistration].self, forKey: .registrations) {
            registrations = many
        } else {
            registrations = [try values.decode(LiveActivityRegistration.self, forKey: .registration)]
        }
        title = try values.decode(String.self, forKey: .title)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        detail = try values.decode(String.self, forKey: .detail)
        tool = try values.decodeIfPresent(String.self, forKey: .tool)
        toolCount = try values.decode(Int.self, forKey: .toolCount)
        background = try values.decode(Int.self, forKey: .background)
        failed = try values.decode(Bool.self, forKey: .failed)
        stopped = try values.decode(Bool.self, forKey: .stopped)
        turnOpen = try values.decode(Bool.self, forKey: .turnOpen)
        endedAt = try values.decodeIfPresent(Date.self, forKey: .endedAt)
        lastPushAt = try values.decode(Date.self, forKey: .lastPushAt)
        lastEventAt = try values.decode(Date.self, forKey: .lastEventAt)
        brief = try values.decodeIfPresent(CardBrief.self, forKey: .brief)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sessionID, forKey: .sessionID)
        try values.encode(registrations, forKey: .registrations)
        try values.encode(title, forKey: .title)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encode(detail, forKey: .detail)
        try values.encodeIfPresent(tool, forKey: .tool)
        try values.encode(toolCount, forKey: .toolCount)
        try values.encode(background, forKey: .background)
        try values.encode(failed, forKey: .failed)
        try values.encode(stopped, forKey: .stopped)
        try values.encode(turnOpen, forKey: .turnOpen)
        try values.encodeIfPresent(endedAt, forKey: .endedAt)
        try values.encode(lastPushAt, forKey: .lastPushAt)
        try values.encode(lastEventAt, forKey: .lastEventAt)
        try values.encodeIfPresent(brief, forKey: .brief)
    }

    /// Whether the installation already holds a card for this conversation.
    func follows(device deviceID: String) -> Bool {
        registrations.contains { $0.deviceID == deviceID }
    }

    /// The registrations with this one in place of the same card's older one.
    mutating func upsert(_ registration: LiveActivityRegistration) {
        registrations.removeAll { $0.isSameCard(as: registration) }
        registrations.append(registration)
    }
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
    /// A tool the machine is running for the card's turn right now.
    private struct OpenTool: Sendable {
        let id: String
        let name: String
    }

    static let island: TimeInterval = 60 * 60
    static let lockScreen: TimeInterval = 4 * 60 * 60
    static let staleAfter: TimeInterval = 30 * 60
    static let heartbeatAfter: TimeInterval = 10 * 60
    static let progressGap: TimeInterval = 8
    /// The least time between two pushes that only move the card's steps, plan or question on.
    static let briefGap: TimeInterval = 2
    /// How long a live card may hear nothing before the phone redraws it as quiet: the Agents
    /// wall's own threshold, so a stall reads the same on the Lock Screen as on the wall.
    static let quietAfter: TimeInterval = 45
    /// The largest push APNs takes for a Live Activity.
    static let payloadLimit = 4_000
    /// The sound an alert that must not be heard plays, bundled in the app: a tenth of a second
    /// of silence, because an alert has no silent sound of its own.
    static let silentSound = "LiveActivityQuiet.caf"
    /// How long a turn runs before a card is started for it on the devices that follow turns
    /// started elsewhere: long enough for the phone that sent it to hand over its own card's
    /// token, and for a turn refused at once to be over.
    static let startDelay: TimeInterval = 4
    /// The type the app's cards decode as, which a start push names.
    static let attributesType = "ChatActivityAttributes"

    private static let deadTokenReasons: Set<String> = [
        "BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic", "ExpiredToken",
    ]

    private let transport: (any LiveActivityTransport)?
    private let activitiesURL: URL?
    private var cards: [String: LiveActivityCard]
    private var countedTools: [String: Set<String>] = [:]
    private var openTools: [String: [OpenTool]] = [:]
    private var deliveries: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    /// Whether the latest turn this bridge started for each conversation runs at ultracode, by the
    /// chat's effort or by the word. Kept beside the cards rather than on one, because the turn
    /// starts before the phone has handed over the token of the card that will follow it.
    private var ultracode: [String: Bool] = [:]
    /// The installations this bridge may start cards on, by device.
    private var starters: [String: LiveActivityStarter]
    /// The devices a card was started on for each conversation's current turn, by when the turn
    /// began, so one turn starts at most one card on a device however often it is looked at.
    private var started: [String: (turn: Date, devices: Set<String>)] = [:]
    private let startDelay: TimeInterval
    private let desks: DeskRegistry?
    /// Each installation's wish to stay quiet at a desk and its patience, from the rules it last
    /// registered with, whether or not this bridge can start its cards.
    private var deskRules: [String: DeskRule]

    struct DeskRule: Codable, Sendable, Equatable {
        var quiet: Bool
        var awayAfter: Int?
    }

    init(client: APNSClient?, activitiesURL: URL? = nil, desks: DeskRegistry? = nil) {
        self.init(transport: client, activitiesURL: activitiesURL, desks: desks)
    }

    init(
        transport: (any LiveActivityTransport)?, activitiesURL: URL? = nil,
        startDelay: TimeInterval = LiveActivityPusher.startDelay, desks: DeskRegistry? = nil
    ) {
        self.transport = transport
        self.activitiesURL = activitiesURL
        self.startDelay = startDelay
        self.desks = desks
        cards = Self.load(from: activitiesURL)
        starters = Self.loadStarters(from: activitiesURL.map(Self.startersURL))
        deskRules = Self.loadDeskRules(from: activitiesURL.map(Self.deskRulesURL))
    }

    static func startersURL(_ activitiesURL: URL) -> URL {
        activitiesURL.deletingLastPathComponent().appendingPathComponent("live-activity-starters.json")
    }

    func starter(_ deviceID: String) -> LiveActivityStarter? { starters[deviceID] }

    static func deskRulesURL(_ activitiesURL: URL) -> URL {
        activitiesURL.deletingLastPathComponent().appendingPathComponent("live-activity-desk.json")
    }

    /// The device's rules as it last registered them, kept by its installation id.
    func noteDeskRules(deviceID: String, rules: DeviceRules?) {
        let rule = DeskRule(quiet: rules?.quietAtDesk == true, awayAfter: rules?.awayAfter)
        guard deskRules[deviceID] != rule else { return }
        deskRules[deviceID] = rule
        persistDeskRules()
    }

    /// Whether the installation asked to stay quiet while its person is at a desk, and they are
    /// (or this bridge has not listened long enough to know they are not): no card is started on
    /// it and an ending updates its card without opening the island.
    func quietAtDesk(_ deviceID: String?, now: Date = Date()) -> Bool {
        guard let deviceID, let desks else { return false }
        let rule =
            deskRules[deviceID]
            ?? starters[deviceID].map { DeskRule(quiet: $0.quietAtDesk == true, awayAfter: $0.awayAfter) }
        guard let rule, rule.quiet else { return false }
        let patience = rule.awayAfter.map { TimeInterval(max(1, $0)) } ?? DeskRegistry.defaultAwayAfter
        return desks.mayBeOccupied(awayAfter: patience, now: now)
    }

    private static func loadDeskRules(from url: URL?) -> [String: DeskRule] {
        guard let url, let data = try? Data(contentsOf: url),
            let rules = try? JSONCoding.decoder.decode([String: DeskRule].self, from: data)
        else { return [:] }
        return rules
    }

    private func persistDeskRules() {
        guard let activitiesURL, let data = try? JSONCoding.encoder.encode(deskRules) else { return }
        try? data.write(to: Self.deskRulesURL(activitiesURL), options: .atomic)
    }

    /// A device handed over how this bridge may start its cards.
    func registerStarter(_ starter: LiveActivityStarter) {
        starters[starter.deviceID] = starter
        persistStarters()
        log("start token registered for …\(starter.deviceID.suffix(6)) as \(starter.profileName) (follows: \(starter.follows))")
    }

    func forgetStarter(deviceID: String) {
        guard starters.removeValue(forKey: deviceID) != nil else { return }
        persistStarters()
        log("start token forgotten for …\(deviceID.suffix(6))")
    }

    var enabled: Bool { transport != nil }

    func card(_ sessionID: String) -> LiveActivityCard? { cards[sessionID] }

    /// A card the app just started or took back for a new turn. Nothing is pushed: the app drew
    /// it a moment ago.
    ///
    /// The phone also hands over a card's token when nothing about the card changed — iOS hands the
    /// app every standing card's token again whenever it starts another one — and such a
    /// registration is told apart by its clock: a card taken back for a new turn starts later than
    /// the one on file, while a token handed over again carries the card's own start. It changes
    /// the address and nothing else, so a settled card stays settled and still leaves the Dynamic
    /// Island on time.
    func register(_ registration: LiveActivityRegistration, sessionID: String, turnOpen: Bool) {
        let previous = cards[sessionID]
        if var card = previous, Self.isRefresh(registration, of: card) {
            card.upsert(registration)
            if card.title.isEmpty { card.title = registration.title }
            cards[sessionID] = card
            persist()
            log("token refreshed for \(sessionID) (\(registration.environment))")
            return
        }
        let sameTurn = previous.map { !$0.isSettled && $0.turnOpen && turnOpen } ?? false
        let brief = sameTurn ? previous?.brief : CardBrief(model: previous?.brief?.model)
        var registrations = previous?.registrations ?? []
        registrations.removeAll { $0.isSameCard(as: registration) }
        registrations.append(registration)
        cards[sessionID] = LiveActivityCard(
            sessionID: sessionID, registrations: registrations,
            title: registration.title.isEmpty ? (previous?.title ?? "") : registration.title,
            startedAt: registration.startedAt,
            detail: sameTurn ? previous?.detail ?? CardDetail.thinking.rawValue
                : CardDetail.thinking.rawValue,
            tool: sameTurn ? previous?.tool : nil,
            toolCount: sameTurn ? previous?.toolCount ?? 0 : 0,
            background: previous?.background ?? 0, failed: sameTurn && previous?.failed == true,
            stopped: false, turnOpen: turnOpen, endedAt: nil, lastPushAt: Date(),
            lastEventAt: Date(), brief: brief)
        if !sameTurn { forgetTools(sessionID) }
        persist()
        log("token registered for \(sessionID) (\(registration.environment))")
    }

    func noteEvent(
        _ event: BridgeEvent, sessionID: String, now: Date = Date(), title: String? = nil
    ) {
        guard transport != nil else { return }
        if case .status("running") = event, cards[sessionID] == nil, !starters.isEmpty {
            cards[sessionID] = LiveActivityCard(
                sessionID: sessionID, registrations: [], title: title ?? "", startedAt: now,
                detail: CardDetail.thinking.rawValue, tool: nil, toolCount: 0, background: 0,
                failed: false, stopped: false, turnOpen: true, endedAt: nil, lastPushAt: now,
                lastEventAt: now, brief: CardBrief())
            forgetTools(sessionID)
            persist()
            scheduleStarts(sessionID, turn: now)
            return
        }
        guard var card = cards[sessionID], now >= card.lastEventAt else { return }
        card.lastEventAt = now
        if let title, !title.isEmpty, card.title.isEmpty { card.title = title }
        switch event {
        case .status(let status):
            guard status == "running", card.isSettled || !card.turnOpen else {
                cards[sessionID] = card
                return
            }
            revive(&card, now: now)
            cards[sessionID] = card
            persist()
            push(card, event: "update", priority: "10", now: now)
            scheduleStarts(sessionID, turn: card.startedAt)
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
        let shapeBefore = card.brief?.shape
        var brief = card.brief ?? CardBrief()
        switch event {
        case .messageUpserted(let message):
            brief.absorb(message)
            brief.note(now)
            card.brief = brief
            cards[sessionID] = card
            return
        case .toolUpserted(_, let tool):
            brief.absorb(tool)
            brief.note(now)
        case .partTextDelta, .compaction:
            brief.note(now)
        default:
            break
        }
        card.brief = brief
        switch event {
        case .toolUpserted(_, let tool):
            if tool.status == .running {
                if !openTools[sessionID, default: []].contains(where: { $0.id == tool.id }) {
                    openTools[sessionID, default: []].append(OpenTool(id: tool.id, name: tool.name))
                }
                card.detail = Self.detail(runningTool: tool.name).rawValue
                card.tool = tool.name
                if countedTools[sessionID, default: []].insert(tool.id).inserted {
                    card.toolCount += 1
                }
            } else {
                guard let index = openTools[sessionID]?.firstIndex(where: { $0.id == tool.id })
                else {
                    cards[sessionID] = card
                    return
                }
                openTools[sessionID]?.remove(at: index)
                if let still = openTools[sessionID]?.last {
                    card.detail = Self.detail(runningTool: still.name).rawValue
                    card.tool = still.name
                } else {
                    card.detail = CardDetail.thinking.rawValue
                }
            }
        case .partTextDelta:
            card.detail = CardDetail.writing.rawValue
        case .compaction(let phase, _):
            card.detail = (phase == "started" ? CardDetail.compacting : .thinking).rawValue
        default:
            cards[sessionID] = card
            return
        }
        let changed = card.detail != before
        let since = now.timeIntervalSince(card.lastPushAt)
        let moved = card.brief?.shape != shapeBefore && since > Self.briefGap
        guard changed || moved || since > Self.progressGap else {
            cards[sessionID] = card
            return
        }
        card.lastPushAt = now
        cards[sessionID] = card
        push(card, event: "update", priority: changed ? "10" : "5", now: now)
    }

    /// A turn this bridge started, and whether it runs at ultracode, which the card wears as the
    /// wall's rainbow while the turn runs — whenever the card comes to exist.
    func noteTurn(sessionID: String, ultracode: Bool) {
        self.ultracode[sessionID] = ultracode
    }

    /// Somebody pressed stop: the turn that ends next ended because they asked it to.
    func noteStopped(sessionID: String, now: Date = Date()) {
        guard var card = cards[sessionID], !card.isSettled, now >= card.lastEventAt else { return }
        card.stopped = true
        card.lastEventAt = now
        cards[sessionID] = card
    }

    /// The turn ended. The card settles on how, and stays for somebody to read it — unless
    /// somebody stopped it, which is never news to the person who pressed stop, so that card goes
    /// at once.
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
        forgetTools(sessionID)
        if card.reading != .question { card.brief?.ask = nil }
        guard card.reading != .cancelled else {
            cards[sessionID] = nil
            persist()
            push(card, event: "end", priority: "10", now: now, dismissal: now)
            log("card ended with its stopped turn for \(sessionID)")
            return
        }
        cards[sessionID] = card
        persist()
        push(card, event: "update", priority: "10", now: now, alerts: true)
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

    /// Starts a card for the conversation's turn on every device that follows turns started
    /// elsewhere and holds none for it, once the turn has run `startDelay`: by then the phone that
    /// sent it has handed over its own card, and a turn refused at once is already over.
    private func scheduleStarts(_ sessionID: String, turn: Date) {
        guard !starters.isEmpty else { return }
        let delay = startDelay
        Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            self.startCards(sessionID, turn: turn, now: Date())
        }
    }

    /// Sends a start push for the conversation's turn to every device that wants one now.
    func startCards(_ sessionID: String, turn: Date, now: Date) {
        guard let transport, let card = cards[sessionID], !card.isSettled, card.turnOpen,
            abs(card.startedAt.timeIntervalSince(turn)) < 1
        else { return }
        var record = started[sessionID] ?? (turn, [])
        if abs(record.turn.timeIntervalSince(turn)) >= 1 { record = (turn, []) }
        let targets = starters.values.filter { starter in
            starter.follows(sessionID) && !card.follows(device: starter.deviceID)
                && !record.devices.contains(starter.deviceID) && !atLimit(starter)
                && !quietAtDesk(starter.deviceID, now: now)
        }
        guard !targets.isEmpty else { return }
        let ultra = ultracode[sessionID] == true
        var pending = deliveries[sessionID]?.task
        for starter in targets {
            record.devices.insert(starter.deviceID)
            guard let body = Self.startBody(card, starter: starter, now: now, ultra: ultra) else { continue }
            let previous = pending
            let task = Task {
                await previous?.value
                let (status, reason) = await transport.pushLiveActivity(
                    body: body, token: starter.token, environment: starter.environment,
                    priority: "10")
                self.startDelivered(
                    sessionID: sessionID, deviceID: starter.deviceID, token: starter.token,
                    status: status, reason: reason)
            }
            pending = task
        }
        started[sessionID] = record
        if let pending { deliveries[sessionID] = (UUID(), pending) }
    }

    /// Whether a device already has as many live cards from this bridge as it allows.
    private func atLimit(_ starter: LiveActivityStarter) -> Bool {
        guard let limit = starter.cardLimit else { return false }
        let live = cards.values.filter { !$0.isSettled && $0.follows(device: starter.deviceID) }.count
        return live >= limit
    }

    private func startDelivered(
        sessionID: String, deviceID: String, token: String, status: Int, reason: String?
    ) {
        if status == 200 {
            log("start push ok for \(sessionID) on …\(deviceID.suffix(6))")
            return
        }
        log("start push failed \(status) for \(sessionID) on …\(deviceID.suffix(6)): \(reason ?? "no reason")")
        let dead = status == 410 || Self.deadTokenReasons.contains(reason ?? "")
        guard dead, starters[deviceID]?.token == token else { return }
        forgetStarter(deviceID: deviceID)
    }

    /// The push that starts a card: the app's attributes for the conversation as this device names
    /// its machine, the card's state, and the alert a start must carry — silent, because the card
    /// itself is the news — asking for the new card's own update token.
    static func startBody(
        _ card: LiveActivityCard, starter: LiveActivityStarter, now: Date, ultra: Bool
    ) -> Data? {
        var last: Data?
        for parts in BriefParts.allCases {
            var object = payload(card, event: "start", now: now, ultra: ultra, briefParts: parts)
            guard var aps = object["aps"] as? [String: Any] else { return nil }
            let title = card.title.isEmpty ? "Tailscode" : card.title
            aps["attributes-type"] = attributesType
            aps["attributes"] = [
                "sessionID": card.sessionID, "sessionTitle": title,
                "serverName": starter.profileName, "profileID": starter.profileID,
            ]
            aps["alert"] = [
                "title": title, "body": ["loc-key": card.reading.startKey], "sound": silentSound,
            ] as [String: Any]
            aps["input-push-token"] = 1
            object["aps"] = aps
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { continue }
            last = data
            if data.count <= payloadLimit { return data }
        }
        return last
    }

    private func retire(_ card: LiveActivityCard, now: Date) {
        guard let endedAt = card.endedAt else { return }
        cards[card.sessionID] = nil
        forgetTools(card.sessionID)
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
        card.brief = CardBrief(model: card.brief?.model)
        forgetTools(card.sessionID)
    }

    private static func settledDetail(_ card: LiveActivityCard, _ ending: TurnEnding) -> CardDetail {
        CardDetail.settled(ending: ending, stopped: card.stopped, failed: card.failed)
    }

    /// What a card says while this tool is out on the machine: the one tool that stops the turn to
    /// ask something reads as the question it is.
    private static func detail(runningTool name: String) -> CardDetail {
        name.caseInsensitiveCompare("AskUserQuestion") == .orderedSame ? .question : .tool
    }

    /// Whether a registration only hands over the address of the card already on file: it starts
    /// no later than that card did, where a card taken back for a new turn starts after it.
    private static func isRefresh(
        _ registration: LiveActivityRegistration, of card: LiveActivityCard
    ) -> Bool {
        registration.startedAt.timeIntervalSince(card.startedAt) < 1
    }

    private func forgetTools(_ sessionID: String) {
        countedTools[sessionID] = nil
        openTools[sessionID] = nil
    }

    static func payload(
        _ card: LiveActivityCard, event: String, now: Date, dismissal: Date? = nil,
        alert: String? = nil, ultra: Bool = false, briefParts: BriefParts = .fitted
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
        if let brief = card.brief {
            var object = CardBrief.fitted(brief, settled: card.isSettled, now: now, parts: briefParts)
            if ultra, !card.isSettled { object["ultra"] = true }
            if !object.isEmpty { state["brief"] = object }
        }
        var aps: [String: Any] = [
            "timestamp": Int(now.timeIntervalSince1970),
            "event": event,
            "content-state": state,
            "relevance-score": reading.relevance,
        ]
        if !card.isSettled { aps["stale-date"] = Int(staleDate(card, now: now).timeIntervalSince1970) }
        if let dismissal { aps["dismissal-date"] = Int(dismissal.timeIntervalSince1970) }
        if let alert, card.isSettled, reading != .cancelled {
            aps["alert"] = [
                "title": card.title.isEmpty ? "Tailscode" : card.title,
                "body": ["loc-key": reading.alertKey],
                "sound": alert == "sound" ? "default" : silentSound,
            ] as [String: Any]
        }
        return ["aps": aps]
    }

    /// When the phone redraws a live card as having heard nothing: the wall's quiet threshold
    /// after the turn last moved. A turn waiting on its question is waiting, not quiet, and a card
    /// that has seen nothing move keeps the old half hour.
    static func staleDate(_ card: LiveActivityCard, now: Date) -> Date {
        guard card.reading != .question, let moved = card.brief?.moved else {
            return now.addingTimeInterval(staleAfter)
        }
        let quiet = moved.addingTimeInterval(quietAfter)
        return min(max(quiet, now.addingTimeInterval(1)), now.addingTimeInterval(staleAfter))
    }

    /// Whether the brief may carry everything it fits in its own budget, or nothing past the pulse
    /// and the model because even that would not leave the push under what APNs takes.
    enum BriefParts: CaseIterable {
        case fitted, bare
    }

    /// The push's body, with as much of the brief as fits in what APNs takes.
    static func body(
        _ card: LiveActivityCard, event: String, now: Date, dismissal: Date?, alert: String?,
        ultra: Bool = false
    ) -> Data? {
        var last: Data?
        for parts in BriefParts.allCases {
            let object = payload(
                card, event: event, now: now, dismissal: dismissal, alert: alert, ultra: ultra,
                briefParts: parts)
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { continue }
            last = data
            if data.count <= payloadLimit { return data }
        }
        return last
    }

    /// Sends in order, one conversation at a time: an update that raced ahead of the one before it
    /// would leave the phone showing the older of the two.
    /// Sends in order, one conversation at a time, to every installation following it: an update
    /// that raced ahead of the one before it would leave a phone showing the older of the two.
    /// `alerts` carries each registration's own choice of alert at the ending.
    private func push(
        _ card: LiveActivityCard, event: String, priority: String, now: Date,
        dismissal: Date? = nil, alerts: Bool = false
    ) {
        guard let transport, !card.registrations.isEmpty else { return }
        let ultra = ultracode[card.sessionID] == true
        var bodies: [String: Data] = [:]
        var sends: [(LiveActivityRegistration, Data)] = []
        for registration in card.registrations {
            let alert =
                alerts && !quietAtDesk(registration.deviceID, now: now) ? registration.endAlert : nil
            let key = alert ?? ""
            if bodies[key] == nil {
                bodies[key] = Self.body(
                    card, event: event, now: now, dismissal: dismissal, alert: alert, ultra: ultra)
            }
            guard let body = bodies[key] else { continue }
            sends.append((registration, body))
        }
        let sessionID = card.sessionID
        let previous = deliveries[sessionID]?.task
        let id = UUID()
        let task = Task {
            await previous?.value
            for (registration, body) in sends {
                let (status, reason) = await transport.pushLiveActivity(
                    body: body, token: registration.token, environment: registration.environment,
                    priority: priority)
                self.delivered(
                    sessionID: sessionID, token: registration.token, event: event, status: status,
                    reason: reason)
            }
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
        guard dead, var card = cards[sessionID], card.registrations.contains(where: { $0.token == token })
        else { return }
        card.registrations.removeAll { $0.token == token }
        if card.registrations.isEmpty, card.isSettled || starters.isEmpty {
            cards[sessionID] = nil
            forgetTools(sessionID)
            log("dropped the card for \(sessionID): its token is dead")
        } else {
            cards[sessionID] = card
            log("dropped one device's card for \(sessionID): its token is dead")
        }
        persist()
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
                        sessionID: stored.sessionID, registrations: [stored.registration],
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

    private static func loadStarters(from url: URL?) -> [String: LiveActivityStarter] {
        guard let url, let data = try? Data(contentsOf: url),
            let stored = try? JSONCoding.decoder.decode([LiveActivityStarter].self, from: data)
        else { return [:] }
        return Dictionary(stored.map { ($0.deviceID, $0) }, uniquingKeysWith: { _, new in new })
    }

    private func persistStarters() {
        guard let activitiesURL else { return }
        let url = Self.startersURL(activitiesURL)
        let snapshot = starters.values.sorted { $0.deviceID < $1.deviceID }
        guard let data = try? JSONCoding.encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[live-activity] \(message)\n".utf8))
    }
}
