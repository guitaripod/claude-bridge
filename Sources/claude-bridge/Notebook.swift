import Foundation

/// An expert's notebook: one fact per Markdown file with a front matter, and a `MEMORY.md` index
/// of one line per note — the shape of a Claude Code memory folder, so a folder the person already
/// keeps can be adopted as it is and the terminal goes on reading what Tailscode writes into it.
///
/// Nothing is ever deleted. A retired note moves to `retired/` with the day and the reason in its
/// front matter, because a fact that silently disappears is a fact the next task can rediscover
/// and believe again.
struct Notebook: Sendable {
    let folder: URL
    let adopted: Bool

    static let indexName = "MEMORY.md"
    static let retiredFolder = "retired"
    /// A note nobody has written or confirmed for this long is offered for review.
    static let staleAfter: TimeInterval = 60 * 24 * 3_600

    var retiredURL: URL { folder.appendingPathComponent(Self.retiredFolder) }

    // MARK: Reading

    func facts(now: Date = Date()) -> NotebookFacts {
        let live = notes(now: now)
        return NotebookFacts(
            path: folder.path, adopted: adopted, notes: live.count,
            stale: live.filter(\.stale).count, retired: noteFiles(in: retiredURL).count)
    }

    /// Every live note, newest first, without bodies.
    func notes(now: Date = Date()) -> [Note] {
        let titles = indexTitles()
        return noteFiles(in: folder)
            .compactMap { read($0, titles: titles, withBody: false, retired: false, now: now) }
            .sorted { ($0.confirmed ?? $0.written ?? .distantPast) > ($1.confirmed ?? $1.written ?? .distantPast) }
    }

    func retired(now: Date = Date()) -> [Note] {
        noteFiles(in: retiredURL)
            .compactMap { read($0, titles: [:], withBody: false, retired: true, now: now) }
            .sorted { ($0.retired?.at ?? .distantPast) > ($1.retired?.at ?? .distantPast) }
    }

    func note(_ id: String, now: Date = Date()) -> Note? {
        guard let name = Self.safeName(id) else { return nil }
        let live = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: live.path) {
            return read(live, titles: indexTitles(), withBody: true, retired: false, now: now)
        }
        let gone = retiredURL.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: gone.path) else { return nil }
        return read(gone, titles: [:], withBody: true, retired: true, now: now)
    }

    private func noteFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".md") && $0 != Self.indexName && !$0.hasPrefix(".") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    private func read(_ url: URL, titles: [String: String], withBody: Bool, retired: Bool, now: Date) -> Note? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parsed = FrontMatter(text)
        guard parsed.hasFence else { return nil }
        let id = url.lastPathComponent
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        let written = parsed.date("written") ?? parsed.date("modified") ?? modified
        let confirmed = parsed.date("confirmed")
        let title =
            titles[id] ?? parsed.value("title") ?? parsed.heading
            ?? Self.title(fromSlug: parsed.value("name") ?? String(id.dropLast(3)))
        let latest = [written, confirmed].compactMap { $0 }.max()
        let stale = !retired && latest.map { now.timeIntervalSince($0) > Self.staleAfter } ?? false
        return Note(
            id: id, title: title, summary: parsed.value("description") ?? "",
            body: withBody ? parsed.body : nil, type: parsed.value("type"), written: written,
            confirmed: confirmed, source: parsed.value("source") ?? parsed.value("originSessionId"),
            stale: stale,
            retired: retired
                ? NoteRetirement(at: parsed.date("retired") ?? modified, reason: parsed.value("reason")) : nil)
    }

    /// The titles the index gives each file, read from its `- [Title](file.md)` lines.
    func indexTitles() -> [String: String] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(Self.indexName), encoding: .utf8)
        else { return [:] }
        var titles: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let link = Self.indexLink(String(line)) else { continue }
            titles[link.file] = link.title
        }
        return titles
    }

    static func indexLink(_ line: String) -> (title: String, file: String)? {
        guard let open = line.firstIndex(of: "["),
            let separator = line.range(of: "](", range: open..<line.endIndex),
            let end = line[separator.upperBound...].firstIndex(of: ")")
        else { return nil }
        let title = String(line[line.index(after: open)..<separator.lowerBound])
        let file = String(line[separator.upperBound..<end])
        guard file.hasSuffix(".md"), !file.contains("/") else { return nil }
        return (title, file)
    }

    // MARK: Writing

    /// Writes a new note and its index line, and answers its file name.
    @discardableResult
    func add(title: String, summary: String, body: String, type: String?, source: String, now: Date) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = uniqueName(for: title)
        let lines = [
            "---",
            "name: \(name.dropLast(3))",
            "description: \(FrontMatter.quoted(summary))",
            "metadata:",
            "  type: \(Self.noteType(type))",
            "  written: \(FrontMatter.day(now))",
            "  source: \(FrontMatter.quoted(source))",
            "---",
            "",
            body.trimmingCharacters(in: .whitespacesAndNewlines),
            "",
        ]
        try write(lines.joined(separator: "\n"), to: folder.appendingPathComponent(name))
        try setIndexLine(file: name, title: title, summary: summary)
        return name
    }

    /// Rewrites a note's words, marks it confirmed today, and keeps every other line of its front
    /// matter as it was.
    func change(_ id: String, title: String, summary: String, body: String, source: String, now: Date) throws {
        guard let name = Self.safeName(id) else { throw ExpertError.invalid("No such note.") }
        let url = folder.appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ExpertError.invalid("The note \(name) is not in the notebook any more.")
        }
        var parsed = FrontMatter(text)
        guard parsed.hasFence else { throw ExpertError.invalid("\(name) has no front matter, so it is not a note.") }
        parsed.set("description", FrontMatter.quoted(summary))
        parsed.setMetadata("confirmed", FrontMatter.day(now))
        parsed.setMetadata("source", FrontMatter.quoted(source))
        parsed.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        try write(parsed.rendered, to: url)
        try setIndexLine(file: name, title: title, summary: summary)
    }

    /// Moves a note to `retired/` with the day and the reason, and takes its index line out.
    func retire(_ id: String, reason: String, now: Date) throws {
        guard let name = Self.safeName(id) else { throw ExpertError.invalid("No such note.") }
        let url = folder.appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ExpertError.invalid("The note \(name) is not in the notebook any more.")
        }
        var parsed = FrontMatter(text)
        guard parsed.hasFence else { throw ExpertError.invalid("\(name) has no front matter, so it is not a note.") }
        parsed.setMetadata("retired", FrontMatter.day(now))
        parsed.setMetadata("reason", FrontMatter.quoted(reason))
        try FileManager.default.createDirectory(at: retiredURL, withIntermediateDirectories: true)
        var target = retiredURL.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) {
            target = retiredURL.appendingPathComponent(
                "\(name.dropLast(3))-\(FrontMatter.day(now))-\(UUID().uuidString.prefix(4)).md")
        }
        try write(parsed.rendered, to: target)
        try FileManager.default.removeItem(at: url)
        try removeIndexLine(file: name)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: adopted ? 0o644 : 0o600], ofItemAtPath: url.path)
    }

    private func setIndexLine(file: String, title: String, summary: String) throws {
        let url = folder.appendingPathComponent(Self.indexName)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let line = "- [\(Self.flat(title))](\(file)) — \(Self.flat(summary))"
        var lines = existing.isEmpty ? [] : existing.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { Self.indexLink($0)?.file == file }) {
            lines[index] = line
        } else {
            while let last = lines.last, last.isEmpty { lines.removeLast() }
            lines.append(line)
            lines.append("")
        }
        try write(lines.joined(separator: "\n"), to: url)
    }

    private func removeIndexLine(file: String) throws {
        let url = folder.appendingPathComponent(Self.indexName)
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = existing.components(separatedBy: "\n").filter { Self.indexLink($0)?.file != file }
        try write(lines.joined(separator: "\n"), to: url)
    }

    private func uniqueName(for title: String) -> String {
        let slug = Self.slug(title)
        var name = "\(slug).md"
        var counter = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
            || FileManager.default.fileExists(atPath: retiredURL.appendingPathComponent(name).path)
        {
            name = "\(slug)-\(counter).md"
            counter += 1
        }
        return name
    }

    // MARK: Words

    static func slug(_ title: String) -> String {
        var slug = ""
        var lastDash = true
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                slug.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                slug.append("-")
                lastDash = true
            }
            if slug.count >= 60 { break }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "note" : slug
    }

    static func title(fromSlug slug: String) -> String {
        let words = slug.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let first = words.first else { return slug }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    static func noteType(_ type: String?) -> String {
        guard let type, ["user", "feedback", "project", "reference"].contains(type) else { return "project" }
        return type
    }

    /// A file name inside the notebook, or nil for anything that would reach outside it.
    static func safeName(_ id: String) -> String? {
        let name = id.hasSuffix(".md") ? id : "\(id).md"
        guard !name.contains("/"), !name.contains("\\"), !name.hasPrefix("."), name != indexName else { return nil }
        return name
    }

    private static func flat(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "](", with: "] (")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// A Markdown file's YAML front matter read as flat keys (top-level and one level under
/// `metadata:`), kept line by line so a rewrite changes only what it sets.
struct FrontMatter: Sendable {
    private(set) var lines: [String]
    var body: String
    let hasFence: Bool

    init(_ text: String) {
        let all = text.components(separatedBy: "\n")
        if all.first?.trimmingCharacters(in: .whitespaces) == "---",
            let end = all.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        {
            lines = Array(all[1..<end])
            body = all[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            hasFence = true
        } else {
            lines = []
            body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            hasFence = false
        }
    }

    /// The value of `key` at the top level or under `metadata:`.
    func value(_ key: String) -> String? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key):") else { continue }
            let raw = trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            return Self.unquoted(raw)
        }
        return nil
    }

    func date(_ key: String) -> Date? {
        guard let raw = value(key) else { return nil }
        return Self.parseDate(raw)
    }

    /// The first `# ` heading of the body, for a note whose index line is missing.
    var heading: String? {
        for line in body.split(separator: "\n") where line.hasPrefix("# ") {
            return line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    mutating func set(_ key: String, _ value: String) {
        if let index = lines.firstIndex(where: { $0.hasPrefix("\(key):") }) {
            lines[index] = "\(key): \(value)"
            dropContinuation(after: index, indent: 0)
        } else if let metadata = lines.firstIndex(where: { $0.hasPrefix("metadata:") }) {
            lines.insert("\(key): \(value)", at: metadata)
        } else {
            lines.append("\(key): \(value)")
        }
    }

    mutating func setMetadata(_ key: String, _ value: String) {
        guard let metadata = lines.firstIndex(where: { $0.hasPrefix("metadata:") }) else {
            lines.append("metadata:")
            lines.append("  \(key): \(value)")
            return
        }
        var index = metadata + 1
        while index < lines.count, lines[index].hasPrefix(" ") {
            if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("\(key):") {
                lines[index] = "  \(key): \(value)"
                dropContinuation(after: index, indent: 2)
                return
            }
            index += 1
        }
        lines.insert("  \(key): \(value)", at: index)
    }

    /// Removes the lines a replaced value continued on — a folded or literal block, or a list —
    /// which sit deeper than the key itself, so a rewrite never leaves an old value hanging.
    private mutating func dropContinuation(after index: Int, indent: Int) {
        var next = index + 1
        while next < lines.count {
            let line = lines[next]
            let leading = line.prefix { $0 == " " }.count
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, leading > indent else { break }
            lines.remove(at: next)
        }
        _ = next
    }

    var rendered: String {
        (["---"] + lines + ["---", "", body, ""]).joined(separator: "\n")
    }

    static func quoted(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let escaped = flat.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func unquoted(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        if raw.hasPrefix("\""), raw.hasSuffix("\"") {
            return String(raw.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if raw.hasPrefix("'"), raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: raw) { return date }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(raw.prefix(10)))
    }
}
