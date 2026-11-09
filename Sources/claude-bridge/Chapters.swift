import Foundation

/// A stretch of the conversation under one title. A chapter begins where the bridge judged that
/// the topic had moved on; a rename inside the stretch — the first model title replacing the
/// prompt-derived one, a person's rename, an agent's own title — renames the chapter rather than
/// starting another, because a new name for the same work is not a new piece of work.
struct Chapter: Codable, Sendable, Equatable {
    var title: String
    /// The person's message the chapter begins at, counted from one the way `titledAtTurn` is.
    var turn: Int
    /// That message, under the id this bridge serves it by.
    var messageID: String?
    var startedAt: Date
    /// What the chapter came to, in one sentence, written once the next chapter begins. The open
    /// chapter has none: it has not come to anything yet.
    var gist: String?
    var namedBy: Namer

    /// Who gave the chapter its current name. `kept` is the name a conversation already wore when
    /// this bridge began keeping chapters, which may describe its later stretch rather than its
    /// first.
    enum Namer: String, Codable, Sendable {
        case prompt, model, person, agent, schedule, fork, kept
    }
}

/// The chapter rules, as functions of a session, so every way a title changes is decided in one
/// place and can be checked without running a turn.
enum ChapterBook {
    /// The newest revision looks back over at most this many of the person's messages when asked
    /// where a new topic began.
    static let lookBack = 4

    static func prompts(in messages: [Message]) -> [(turn: Int, message: Message)] {
        var turn = 0
        var result: [(turn: Int, message: Message)] = []
        for message in messages where message.role == .user {
            turn += 1
            result.append((turn, message))
        }
        return result
    }

    /// Words the bridge put in the conversation in the person's place — a turn picked back up
    /// after background work was cut off, a wait out of a session limit. They count as messages,
    /// as they always have for when a title is looked at, but a chapter never begins at one.
    static func isNotice(_ message: Message) -> Bool {
        let words = text(of: message)
        return words == AutoContinue.prompt || words.hasSuffix(" Picking it back up.")
            || words.hasPrefix("The session limit was reached. Picking the work back up at")
    }

    static func text(of message: Message) -> String {
        message.parts.compactMap { part in
            if case .text(let value) = part { return value }
            return nil
        }.joined(separator: "\n")
    }

    /// How a session's first chapter is named when it opens with the conversation's first message.
    static func openingNamer(for session: Session) -> Chapter.Namer {
        if session.scheduleID != nil { return .schedule }
        if session.customTitle == true { return .person }
        return .prompt
    }

    /// The person's message was just added. The first one opens chapter one; a later one that
    /// changed the prompt-derived title (a first message that was only a picture) renames it.
    static func recorded(_ session: inout Session, message: Message, priorTitle: String) -> Bool {
        let chapters = session.chapters ?? []
        if chapters.isEmpty {
            guard prompts(in: session.messages).count == 1 else { return false }
            session.chapters = [
                Chapter(
                    title: session.title, turn: 1, messageID: message.id,
                    startedAt: message.createdAt, gist: nil, namedBy: openingNamer(for: session))
            ]
            return true
        }
        guard session.title != priorTitle else { return false }
        return renamed(&session, to: session.title, by: .prompt, priorTitle: priorTitle)
    }

    /// Writes chapter one from the name the conversation wore before, for a conversation that has
    /// history but no chapters — one older than this bridge's chapters, or a transcript adopted
    /// from a terminal. A conversation past its first message may have worn several names by now,
    /// and only the last is known, so it says it was kept rather than chosen.
    static func seeded(_ session: inout Session, priorTitle: String) {
        guard session.chapters?.isEmpty ?? true else { return }
        let all = prompts(in: session.messages)
        guard let first = all.first else { return }
        session.chapters = [
            Chapter(
                title: priorTitle, turn: 1, messageID: first.message.id,
                startedAt: first.message.createdAt, gist: nil,
                namedBy: all.count > 1 ? .kept : openingNamer(for: session))
        ]
    }

    /// The conversation took a new name without its topic moving: the current chapter takes it.
    @discardableResult
    static func renamed(
        _ session: inout Session, to title: String, by namer: Chapter.Namer, priorTitle: String
    ) -> Bool {
        seeded(&session, priorTitle: priorTitle)
        guard var chapters = session.chapters, let last = chapters.indices.last else { return false }
        guard chapters[last].title != title || chapters[last].namedBy != namer else { return false }
        chapters[last].title = title
        chapters[last].namedBy = namer
        session.chapters = chapters
        return true
    }

    /// The topic moved: a chapter opens at `message` under `title`, and the index of the chapter
    /// it closes comes back so its gist can be written. A boundary at or before the current
    /// chapter's own start moves to the message after it; when there is none, no chapter opens
    /// and nil comes back, because the current chapter already begins at the newest message.
    static func opened(
        _ session: inout Session, title: String, at message: Message, priorTitle: String
    ) -> Int? {
        seeded(&session, priorTitle: priorTitle)
        let all = prompts(in: session.messages)
        guard var chapters = session.chapters, let last = chapters.last,
            let named = all.first(where: { $0.message.id == message.id })
        else { return nil }
        var start = named
        if start.turn <= last.turn {
            guard let next = all.first(where: { $0.turn > last.turn }) else { return nil }
            start = next
        }
        chapters.append(
            Chapter(
                title: title, turn: start.turn, messageID: start.message.id,
                startedAt: start.message.createdAt, gist: nil, namedBy: .model))
        session.chapters = chapters
        return chapters.count - 2
    }

    /// A fork carries the chapters it was cut from, and its own name names the chapter it goes on.
    static func forked(_ chapters: [Chapter]?, title: String) -> [Chapter]? {
        guard var chapters, let last = chapters.indices.last else { return chapters }
        chapters[last].title = title
        chapters[last].namedBy = .fork
        chapters[last].gist = nil
        return chapters
    }

    /// The person's messages a revision is shown: those since the title was last looked at, the
    /// newest `lookBack` of them, oldest first.
    static func recent(_ messages: [Message], since titledAt: Int?, through turn: Int)
        -> [(turn: Int, message: Message)]
    {
        let floor = titledAt ?? 0
        let span = prompts(in: messages).filter {
            $0.turn > floor && $0.turn <= turn && !isNotice($0.message)
        }
        return Array(span.suffix(lookBack))
    }

    /// The exchange the first model title is written from: the opening message of the chapter the
    /// conversation is in, and the first answer after it. For a fresh conversation that is its
    /// first exchange; for a fork it is where the fork's own stretch began, not the start of the
    /// conversation it was cut from.
    static func opening(of session: Session) -> (id: String, user: String, answer: String)? {
        let messages = session.messages
        var startIndex = messages.firstIndex(where: { $0.role == .user })
        if let last = session.chapters?.last {
            let all = prompts(in: messages)
            let id = last.messageID ?? all.first(where: { $0.turn == last.turn })?.message.id
            if let id, let index = messages.firstIndex(where: { $0.id == id }) { startIndex = index }
        }
        guard let startIndex else { return nil }
        let user = text(of: messages[startIndex])
        let answer = messages[(startIndex + 1)...].first(where: { $0.role == .assistant })
            .map(text(of:)) ?? ""
        guard !user.isEmpty, !answer.isEmpty else { return nil }
        return (messages[startIndex].id, user, answer)
    }

    /// What a closed chapter is summed up from: the person's messages in it — at most eight, taken
    /// evenly across it, so the middle of a long chapter is in the picture too — and the last
    /// answer with words in it before the next chapter began (a compaction seam has none).
    static func gistInput(_ session: Session, closed index: Int) -> (prompts: [String], answer: String)? {
        guard let chapters = session.chapters, chapters.indices.contains(index),
            chapters.indices.contains(index + 1)
        else { return nil }
        let start = chapters[index].turn
        let end = chapters[index + 1].turn
        let messages = session.messages
        let inside = prompts(in: messages).filter { $0.turn >= start && $0.turn < end }
        guard let lastPrompt = inside.last,
            let promptIndex = messages.firstIndex(where: { $0.id == lastPrompt.message.id })
        else { return nil }
        let nextIndex = chapters[index + 1].messageID.flatMap { id in
            messages.firstIndex(where: { $0.id == id })
        } ?? messages.endIndex
        guard promptIndex < nextIndex else { return nil }
        let answer = messages[promptIndex..<nextIndex].reversed()
            .first(where: { $0.role == .assistant && !text(of: $0).isEmpty })
            .map(text(of:)) ?? ""
        let spoken = inside.filter { !isNotice($0.message) }
        let picked = spoken.count > 8
            ? (0..<8).map { spoken[$0 * (spoken.count - 1) / 7] } : spoken
        let texts = picked.map { text(of: $0.message) }.filter { !$0.isEmpty }
        guard !texts.isEmpty, !answer.isEmpty else { return nil }
        return (texts, answer)
    }

    /// Puts a gist on the chapter it was written for, found again by where it starts, so a
    /// conversation cleared or re-chaptered while the gist was being written is left alone.
    static func summed(_ session: inout Session, chapter: Chapter, gist: String) -> Bool {
        guard var chapters = session.chapters,
            let index = chapters.firstIndex(where: {
                $0.turn == chapter.turn && $0.messageID == chapter.messageID
            }),
            chapters[index].gist == nil
        else { return false }
        chapters[index].gist = gist
        session.chapters = chapters
        return true
    }
}
