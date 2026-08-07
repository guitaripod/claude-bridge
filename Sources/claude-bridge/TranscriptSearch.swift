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
/// Two things keep it honest on a machine with hundreds of megabytes of them. A file is byte-scanned
/// for the rarest term before anything is parsed, so the overwhelming majority are rejected without
/// decoding a single line of JSON; and the whole search is bounded by a deadline it reports, because
/// a search that quietly stopped looking is worse than one that admits it did.
enum TranscriptSearch {
    static let defaultLimit = 40
    static let matchesPerSession = 4
    static let snippetRadius = 90
    static let budget: TimeInterval = 3.0

    /// The words to look for, lowercased once. Every term must appear somewhere in the same passage
    /// — several words are a narrowing, not a wider net.
    struct Query: Sendable {
        let terms: [String]
        /// The term to byte-scan a whole file for. The longest one: the rarest of them, near
        /// enough, and the cheapest way to reject a file that cannot possibly match.
        let rarest: [UInt8]

        init?(_ raw: String) {
            let terms = raw.lowercased()
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { !$0.isEmpty }
            guard let longest = terms.max(by: { $0.count < $1.count }) else { return nil }
            self.terms = terms
            self.rarest = Array(longest.utf8)
        }

        func matches(_ haystack: String) -> Bool {
            let lowered = haystack.lowercased()
            return terms.allSatisfy { lowered.contains($0) }
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
        let deadline = Date().addingTimeInterval(budget)
        let lanes = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 1))
        var hits: [SearchHit] = []
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
                    guard contains(query.rarest, in: data) else { return (true, nil) }
                    return (true, search(file: file, data: data, query: query))
                }
                return true
            }
            for _ in 0..<lanes where enqueue() {}
            var considered = 0
            while let (read, hit) = await group.next() {
                considered += 1
                if read { scanned += 1 }
                if let hit { hits.append(hit) }
                if hits.count >= limit || Date() >= deadline {
                    // Truncated means transcripts nobody looked at — not tasks still in flight,
                    // which have been looked at by the time they answer.
                    truncated = considered < files.count
                    group.cancelAll()
                    break
                }
                _ = enqueue()
            }
        }
        hits.sort { $0.updatedAt > $1.updatedAt }
        return SearchResponse(
            query: raw, hits: Array(hits.prefix(limit)), scanned: scanned, truncated: truncated)
    }

    private struct Transcript {
        let url: URL
        let id: String
        let modifiedAt: Date
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
                let files = try? manager.contentsOfDirectory(
                    at: project, includingPropertiesForKeys: [.contentModificationDateKey],
                    options: .skipsHiddenFiles)
            else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let id = file.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: id) != nil else { continue }
                let modified =
                    (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                found.append(Transcript(url: file, id: id, modifiedAt: modified))
            }
        }
        return found.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func search(file: Transcript, data: Data, query: Query) -> SearchHit? {
        var matches: [SearchMatch] = []
        var total = 0
        var title: String?
        var directory: String?

        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            if directory == nil { directory = object["cwd"] as? String }
            let stamp = (object["timestamp"] as? String).flatMap(TranscriptParser.parseTimestamp)
            for passage in passages(in: object) {
                if title == nil, passage.role == .user, passage.kind == "text" {
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
            sessionID: file.id,
            title: title ?? TranscriptParser.firstUserPromptLine(atPath: file.url.path)
                ?? "Conversation",
            directory: directory, updatedAt: file.modifiedAt, matches: matches, total: total)
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
    private static func snippet(_ text: String, around query: Query) -> String {
        let flattened = text.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression)
        let lowered = flattened.lowercased()
        guard let first = query.terms.compactMap({ lowered.range(of: $0) })
            .min(by: { $0.lowerBound < $1.lowerBound })
        else { return String(flattened.prefix(snippetRadius * 2)) }
        let start = flattened.index(
            first.lowerBound, offsetBy: -snippetRadius,
            limitedBy: flattened.startIndex) ?? flattened.startIndex
        let end = flattened.index(
            first.upperBound, offsetBy: snippetRadius,
            limitedBy: flattened.endIndex) ?? flattened.endIndex
        var out = String(flattened[start..<end])
        if start > flattened.startIndex { out = "…" + out }
        if end < flattened.endIndex { out += "…" }
        return out
    }

    /// Case-insensitive byte search over the raw file, Boyer–Moore–Horspool over a folded alphabet.
    ///
    /// This is the whole performance story: a machine that has been used has gigabytes of
    /// transcript, and a byte-at-a-time scan cannot read that inside anyone's patience. Horspool
    /// skips the length of the term on almost every step, so most of the corpus is never actually
    /// looked at. ASCII-folded on purpose — it only has to be right about whether a file is worth
    /// parsing, and the parsed pass decides for real.
    private static func contains(_ needle: [UInt8], in haystack: Data) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let folded = needle.map { fold($0) }
        let length = folded.count
        var skip = [Int](repeating: length, count: 256)
        for index in 0..<(length - 1) { skip[Int(folded[index])] = length - 1 - index }
        return haystack.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            let count = buffer.count
            var offset = 0
            while offset <= count - length {
                var index = length - 1
                while index >= 0, fold(base[offset + index]) == folded[index] { index -= 1 }
                if index < 0 { return true }
                offset += skip[Int(fold(base[offset + length - 1]))]
            }
            return false
        }
    }

    @inline(__always)
    private static func fold(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }
}
