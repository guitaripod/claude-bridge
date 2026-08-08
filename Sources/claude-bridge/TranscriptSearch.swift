import Foundation

/// One place in one conversation where the words were said.
struct SearchMatch: Codable, Sendable {
    var role: Role
    /// Which register the words were in: prose, the model's reasoning, a tool's input, or what a
    /// tool answered. A search for a shell command and a search for a sentence are different
    /// searches, and only the client knows which one this was.
    var kind: String
    /// The words, with enough either side to recognise them by.
    var text: String
    var at: Date?
}

/// One conversation that has the words in it, with the places it has them.
struct SearchHit: Codable, Sendable {
    var sessionID: String
    var title: String
    var directory: String?
    var updatedAt: Date
    var matches: [SearchMatch]
    /// How many places matched in total, which is usually more than were returned.
    var total: Int
}

struct SearchResponse: Codable, Sendable {
    var query: String
    var hits: [SearchHit]
    /// Transcripts actually opened. A search that gave up early has to say so rather than let an
    /// absence read as an answer.
    var scanned: Int
    var truncated: Bool
}

/// Search across every conversation this machine has had.
///
/// A chat list can only match titles, which means everything actually said — the answer, the diff,
/// the command that worked — stops being findable the moment it scrolls off. This reads the CLI's
/// own transcripts, which are already on disk and already the truth about what happened.
///
/// It searches a conversation's subagents as part of the conversation, because that is what they
/// are: a subagent is never its own chat, so its words are found under the chat that spawned it
/// rather than as a row nobody can open. On a machine that has been used they are most of the
/// corpus, and leaving them out would make the fleet's one search quietly miss half of it.
///
/// Three things keep it honest at that size. A file is byte-scanned for the rarest term before
/// anything is parsed, so the overwhelming majority are rejected without decoding a single line of
/// JSON; matching a passage allocates nothing, because every term is folded once up front and
/// carries its own skip table; and the whole search is bounded by a deadline it both reports and
/// actually obeys — the work inside a file watches the clock too, so a transcript the size of a
/// book cannot spend the budget after the answer is already known.
enum TranscriptSearch {
    static let defaultLimit = 40
    static let matchesPerSession = 4
    static let snippetRadius = 90
    static let budget: TimeInterval = 3.0
    /// How often the work inside one transcript looks up at the clock. Often enough that a huge
    /// file cannot outlive the budget, rarely enough that the check costs nothing.
    private static let heartbeat = 512

    /// One word to look for, folded to lowercase ASCII once and carrying its own Boyer–Moore–Horspool
    /// skip table. Both are computed when the query is parsed rather than per file or per passage:
    /// the parsed pass tests millions of passages, and a table rebuilt each time would cost more
    /// than the search.
    struct Term: Sendable {
        let bytes: [UInt8]
        let skip: [Int]

        init(_ raw: String) {
            let bytes = raw.utf8.map(TranscriptSearch.fold)
            var skip = [Int](repeating: bytes.count, count: 256)
            if bytes.count > 1 {
                for index in 0..<(bytes.count - 1) {
                    skip[Int(bytes[index])] = bytes.count - 1 - index
                }
            }
            self.bytes = bytes
            self.skip = skip
        }
    }

    /// The words to look for. Every term must appear somewhere in the same passage — several words
    /// are a narrowing, not a wider net.
    struct Query: Sendable {
        let terms: [Term]
        /// The term to byte-scan a whole file for. The longest one: the rarest of them, near
        /// enough, and the cheapest way to reject a file that cannot possibly match.
        let rarest: Term

        init?(_ raw: String) {
            let words =
                raw.lowercased()
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { !$0.isEmpty }
            guard let longest = words.max(by: { $0.utf8.count < $1.utf8.count }) else { return nil }
            self.terms = words.map(Term.init)
            self.rarest = Term(longest)
        }

        func matches(_ haystack: String) -> Bool {
            var copy = haystack
            return copy.withUTF8 { buffer in
                terms.allSatisfy { TranscriptSearch.firstOffset(of: $0, in: buffer) != nil }
            }
        }

        /// Where the passage first says any of the words, in bytes, and how long that word was.
        func earliest(in haystack: String) -> (offset: Int, length: Int)? {
            var copy = haystack
            return copy.withUTF8 { buffer -> (offset: Int, length: Int)? in
                var best: (offset: Int, length: Int)?
                for term in terms {
                    guard let at = TranscriptSearch.firstOffset(of: term, in: buffer) else { continue }
                    if best == nil || at < best!.offset { best = (at, term.bytes.count) }
                }
                return best
            }
        }
    }

    /// Runs the search, newest transcript first, several at a time.
    ///
    /// The corpus is gigabytes on a machine that has been used, and almost all of it cannot match:
    /// the win is rejecting a whole file without decoding a line of it, and doing that to several
    /// files at once. Concurrency is bounded to the machine's cores — this is one person pressing
    /// enter, not a service, and it must not starve the turn that is running while they look.
    static func run(root: URL, query raw: String, limit: Int) async -> SearchResponse {
        guard let query = Query(raw) else {
            return SearchResponse(query: raw, hits: [], scanned: 0, truncated: false)
        }
        let files = transcripts(under: root)
        var conversations: [String: URL] = [:]
        for file in files where !file.isSubagent { conversations[file.id] = file.url }
        let deadline = Date().addingTimeInterval(budget)
        let lanes = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 1))
        var merged: [String: SearchHit] = [:]
        var scanned = 0
        var truncated = false
        var next = 0

        await withTaskGroup(of: (Bool, SearchHit?).self) { group in
            func enqueue() -> Bool {
                guard next < files.count else { return false }
                let file = files[next]
                next += 1
                group.addTask(priority: .userInitiated) {
                    guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe)
                    else { return (false, nil) }
                    guard offset(of: query.rarest, in: data) != nil else { return (true, nil) }
                    return (true, search(file: file, data: data, query: query, deadline: deadline))
                }
                return true
            }
            for _ in 0..<lanes where enqueue() {}
            var considered = 0
            while let (read, hit) = await group.next() {
                considered += 1
                if read { scanned += 1 }
                if let hit { absorb(hit, into: &merged) }
                if merged.count >= limit || Date() >= deadline {
                    // Truncated means transcripts nobody looked at — not tasks still in flight,
                    // which have been looked at by the time they answer.
                    truncated = considered < files.count
                    group.cancelAll()
                    break
                }
                _ = enqueue()
            }
        }

        var hits = Array(merged.values)
        for index in hits.indices where hits[index].title.isEmpty {
            hits[index].title =
                conversations[hits[index].sessionID]
                .flatMap { TranscriptParser.firstUserPromptLine(atPath: $0.path) } ?? "Conversation"
        }
        hits.sort { $0.updatedAt > $1.updatedAt }
        return SearchResponse(
            query: raw, hits: Array(hits.prefix(limit)), scanned: scanned, truncated: truncated)
    }

    /// One conversation is one row, however many of its transcripts had the words in them.
    private static func absorb(_ hit: SearchHit, into merged: inout [String: SearchHit]) {
        guard var existing = merged[hit.sessionID] else {
            merged[hit.sessionID] = hit
            return
        }
        existing.total += hit.total
        existing.updatedAt = max(existing.updatedAt, hit.updatedAt)
        if existing.title.isEmpty { existing.title = hit.title }
        if existing.directory == nil { existing.directory = hit.directory }
        if existing.matches.count < matchesPerSession {
            existing.matches.append(
                contentsOf: hit.matches.prefix(matchesPerSession - existing.matches.count))
        }
        merged[hit.sessionID] = existing
    }

    private struct Transcript {
        let url: URL
        /// The conversation this file belongs to: itself, or the one whose subagent it is.
        let id: String
        let modifiedAt: Date
        let isSubagent: Bool
    }

    /// Newest first: a search bounded by a deadline has to spend it where the answer probably is.
    private static func transcripts(under root: URL) -> [Transcript] {
        let manager = FileManager.default
        guard
            let projects = try? manager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        else { return [] }
        var found: [Transcript] = []
        for project in projects {
            guard (try? project.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                let entries = try? manager.contentsOfDirectory(
                    at: project,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                    options: .skipsHiddenFiles)
            else { continue }
            var sessions = Set<String>()
            var nested: [URL] = []
            for entry in entries {
                if entry.pathExtension == "jsonl" {
                    let id = entry.deletingPathExtension().lastPathComponent
                    guard UUID(uuidString: id) != nil else { continue }
                    sessions.insert(id)
                    found.append(
                        Transcript(
                            url: entry, id: id, modifiedAt: modified(entry), isSubagent: false))
                } else if UUID(uuidString: entry.lastPathComponent) != nil,
                    (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                {
                    nested.append(entry)
                }
            }
            // A subagent whose conversation is gone would be a result nobody could open, so it is
            // left out rather than offered as a place to go back to that no longer exists.
            for directory in nested where sessions.contains(directory.lastPathComponent) {
                found.append(
                    contentsOf: subagents(under: directory, of: directory.lastPathComponent))
            }
        }
        return found.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Every transcript a conversation's subagents wrote, at whatever depth the CLI filed them —
    /// straight under the conversation, or nested again per workflow.
    private static func subagents(under directory: URL, of session: String) -> [Transcript] {
        guard
            let walker = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        var found: [Transcript] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            found.append(
                Transcript(url: url, id: session, modifiedAt: modified(url), isSubagent: true))
        }
        return found
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
    }

    private static func search(
        file: Transcript, data: Data, query: Query, deadline: Date
    ) -> SearchHit? {
        var matches: [SearchMatch] = []
        var total = 0
        var title: String?
        var directory: String?
        var lines = 0

        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            lines += 1
            if lines % heartbeat == 0, Task.isCancelled || Date() >= deadline { break }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            if directory == nil { directory = object["cwd"] as? String }
            let stamp = (object["timestamp"] as? String).flatMap(TranscriptParser.parseTimestamp)
            for passage in passages(in: object) {
                // A subagent's first words are the errand it was sent on, not the conversation's
                // own opening line, so it never names the row it is folded into.
                if title == nil, !file.isSubagent, passage.role == .user, passage.kind == "text" {
                    title = String(passage.text.prefix(80))
                }
                guard query.matches(passage.text) else { continue }
                total += 1
                guard matches.count < matchesPerSession else { continue }
                matches.append(
                    SearchMatch(
                        role: passage.role, kind: passage.kind,
                        text: snippet(passage.text, around: query), at: stamp))
            }
        }
        guard !matches.isEmpty else { return nil }
        return SearchHit(
            sessionID: file.id, title: title ?? "", directory: directory,
            updatedAt: file.modifiedAt, matches: matches, total: total)
    }

    private struct Passage {
        let role: Role
        let kind: String
        let text: String
    }

    /// Everything in one transcript line that a person could be looking for. Tool input and output
    /// are in here on purpose: a command that worked and a diff that was applied are exactly the
    /// things worth finding again, and neither is prose.
    private static func passages(in line: [String: Any]) -> [Passage] {
        guard line["isMeta"] as? Bool != true, let message = line["message"] as? [String: Any]
        else { return [] }
        let role: Role = line["type"] as? String == "assistant" ? .assistant : .user
        if let content = message["content"] as? String {
            guard let text = TranscriptParser.typedText(content) else { return [] }
            return [Passage(role: role, kind: "text", text: text)]
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        var found: [Passage] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    let typed = role == .user ? TranscriptParser.typedText(text) : text
                    if let typed { found.append(Passage(role: role, kind: "text", text: typed)) }
                }
            case "thinking":
                if let text = block["thinking"] as? String, !text.isEmpty {
                    found.append(Passage(role: role, kind: "reasoning", text: text))
                }
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                if let input = block["input"] as? [String: Any] {
                    // The values, not the JSON. What someone is looking for is the command they
                    // ran or the path they edited, and re-encoding the object buries both under
                    // key names and escape sequences that were never on anybody's screen.
                    let text = input.keys.sorted()
                        .compactMap { TranscriptParser.flatten(input[$0]) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    if !text.isEmpty { found.append(Passage(role: role, kind: name, text: text)) }
                }
            case "tool_result":
                let text = TranscriptParser.flatten(block["content"])
                if !text.isEmpty {
                    found.append(Passage(role: role, kind: "result", text: text))
                }
            default:
                continue
            }
        }
        return found
    }

    /// Enough of the passage to recognise the match by, cut on whole characters and marked with an
    /// ellipsis where it was cut, so a client can render it as one line without measuring anything.
    ///
    /// The window is taken before the whitespace is flattened, never after: a passage can be a file
    /// a tool read, and rewriting megabytes of it to quote two lines is the one place this could
    /// spend real time for nothing.
    private static func snippet(_ text: String, around query: Query) -> String {
        guard let match = query.earliest(in: text) else {
            return flattened(String(text.prefix(snippetRadius * 2)))
        }
        let anchor = boundary(at: match.offset, in: text)
        let tail = boundary(at: match.offset + match.length, in: text)
        let start =
            text.index(anchor, offsetBy: -snippetRadius, limitedBy: text.startIndex)
            ?? text.startIndex
        let end =
            text.index(tail, offsetBy: snippetRadius, limitedBy: text.endIndex) ?? text.endIndex
        var out = flattened(String(text[start..<end]))
        if start > text.startIndex { out = "…" + out }
        if end < text.endIndex { out += "…" }
        return out
    }

    private static func boundary(at offset: Int, in text: String) -> String.Index {
        let utf8 = text.utf8
        guard let byte = utf8.index(utf8.startIndex, offsetBy: offset, limitedBy: utf8.endIndex)
        else { return text.endIndex }
        return String.Index(byte, within: text) ?? text.startIndex
    }

    private static func flattened(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// Case-insensitive byte search, Boyer–Moore–Horspool over a folded alphabet.
    ///
    /// This is the whole performance story: a machine that has been used has gigabytes of
    /// transcript, and a byte-at-a-time scan cannot read that inside anyone's patience. Horspool
    /// skips the length of the term on almost every step, so most of the corpus is never actually
    /// looked at. ASCII-folded on purpose — rejecting a file only has to be right about whether it
    /// is worth parsing, and the parsed pass decides for real.
    private static func firstOffset(of term: Term, in buffer: UnsafeBufferPointer<UInt8>) -> Int? {
        let length = term.bytes.count
        guard length > 0, buffer.count >= length, let base = buffer.baseAddress else { return nil }
        var offset = 0
        while offset <= buffer.count - length {
            var index = length - 1
            while index >= 0, fold(base[offset + index]) == term.bytes[index] { index -= 1 }
            if index < 0 { return offset }
            offset += term.skip[Int(fold(base[offset + length - 1]))]
        }
        return nil
    }

    private static func offset(of term: Term, in data: Data) -> Int? {
        data.withUnsafeBytes { raw -> Int? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            return firstOffset(of: term, in: UnsafeBufferPointer(start: base, count: raw.count))
        }
    }

    @inline(__always)
    private static func fold(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }
}
