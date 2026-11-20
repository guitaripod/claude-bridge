import Foundation

/// What an expert's task starts with: its charter, the skills it loads first, its notebook's index,
/// the latest journal entries, its bench as the machine just found it, and any guard that is
/// failing. Appended to Claude Code's own system prompt beside the client note, so it is part of
/// how the process was started and never part of the conversation: a carry never takes it along,
/// and nothing a person reads in the transcript is the brief.
///
/// It has a budget. Past it, the oldest journal entries go first, then the notes' summaries
/// (their titles stay, and the notebook's path tells the session where to read the rest), then
/// notes beyond what fits, with a line saying how many more there are.
enum ExpertBrief {
    static let budgetTokens = 4_000
    static let charsPerToken = 4
    static let journalShown = 5

    struct Inputs: Sendable {
        var expert: Expert
        var notebookPath: String
        var notes: [Note]
        var journal: [JournalEntry]
        var bench: [BenchItem]
        var guards: [GuardItem]
        var timeZone: TimeZone
    }

    static func tokens(_ text: String) -> Int { (text.count + charsPerToken - 1) / charsPerToken }

    static func text(_ inputs: Inputs) -> String {
        var journal = Array(inputs.journal.prefix(journalShown))
        var summaries = true
        var noteLimit = inputs.notes.count
        var rendered = render(inputs, journal: journal, summaries: summaries, noteLimit: noteLimit)
        while tokens(rendered) > budgetTokens {
            if journal.count > 1 {
                journal.removeLast()
            } else if summaries {
                summaries = false
            } else if noteLimit > 0 {
                noteLimit = max(0, noteLimit - max(1, noteLimit / 5))
            } else {
                break
            }
            rendered = render(inputs, journal: journal, summaries: summaries, noteLimit: noteLimit)
        }
        return rendered
    }

    private static func render(_ inputs: Inputs, journal: [JournalEntry], summaries: Bool, noteLimit: Int) -> String {
        let expert = inputs.expert
        var parts: [String] = []
        var opening = "You are working as \"\(expert.name)\", an expert kept on this machine by Tailscode."
        if !expert.purpose.isEmpty { opening += " \(expert.purpose)" }
        opening += " Each task you are given is a fresh conversation; what carries over between tasks is this brief, your notebook and your journal."
        parts.append(opening)

        let charter = expert.charter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !charter.isEmpty { parts.append("## Charter\n\(charter)") }

        if !expert.skills.isEmpty {
            parts.append(
                "## Skills\nLoad these skills before you start work: \(expert.skills.joined(separator: ", ")).")
        }

        var notebook = """
            ## Notebook
            Your notebook is \(inputs.notebookPath): one fact per Markdown file, indexed in MEMORY.md. \
            Read a note's file when its title bears on the task. Do not write to the notebook during the \
            task: when the task ends you will be asked for a debrief that proposes changes, and the \
            person accepts or skips each one.
            """
        let shown = inputs.notes.prefix(noteLimit)
        if shown.isEmpty, inputs.notes.isEmpty {
            notebook += "\nIt has no notes yet."
        }
        for note in shown {
            var line = "- \(note.title)"
            if summaries, !note.summary.isEmpty { line += " — \(note.summary)" }
            if note.stale { line += " (not confirmed for a while)" }
            line += " [\(note.id)]"
            notebook += "\n\(line)"
        }
        if inputs.notes.count > shown.count {
            notebook += "\n- …and \(inputs.notes.count - shown.count) more, listed in MEMORY.md."
        }
        parts.append(notebook)

        if !journal.isEmpty {
            var lines = "## Recent tasks (newest first)"
            for entry in journal {
                var line = "- \(day(entry.at, inputs.timeZone)) · \(entry.title): \(entry.outcome)"
                if !entry.measured.isEmpty { line += " Measured: \(entry.measured.joined(separator: "; "))." }
                lines += "\n\(line)"
            }
            parts.append(lines)
        }

        if !inputs.bench.isEmpty {
            var lines = "## Bench, as this machine found it when the task began"
            for item in inputs.bench {
                lines += "\n- \(benchLine(item))"
            }
            parts.append(lines)
        }

        let failing = inputs.guards.filter { $0.last.map { !$0.passed } ?? false }
        if !inputs.guards.isEmpty {
            var lines = "## Guards"
            if failing.isEmpty {
                let checked = inputs.guards.compactMap { $0.last?.at }.max()
                lines += "\nAll \(inputs.guards.count) guards passed"
                if let checked { lines += " when last run (\(moment(checked, inputs.timeZone)))" }
                lines += "."
            } else {
                for item in failing {
                    guard let run = item.last else { continue }
                    var line = "- Failing since \(moment(run.at, inputs.timeZone)): \(item.name) — `\(item.command)`"
                    if let value = run.value, let metric = item.metric {
                        line += " measured \(number(value))\(metric.unit.map { " \($0)" } ?? "")"
                        if let most = metric.atMost { line += ", at most \(number(most))" }
                        if let least = metric.atLeast { line += ", at least \(number(least))" }
                    }
                    if let output = run.output, !output.isEmpty {
                        line += "\n  Last output:\n" + CommandRunner.tail(output, lines: 12, bytes: 1_200)
                            .split(separator: "\n").map { "    \($0)" }.joined(separator: "\n")
                    }
                    lines += "\n\(line)"
                }
                let passing = inputs.guards.count - failing.count
                if passing > 0 { lines += "\n\(passing) other guards pass." }
            }
            parts.append(lines)
        }
        return parts.joined(separator: "\n\n")
    }

    static func benchLine(_ item: BenchItem) -> String {
        var line = item.name
        if let identifier = item.identifier, identifier.lowercased() != item.name.lowercased() {
            line += " (\(identifier))"
        }
        switch item.state {
        case "ready":
            var words = ["available"]
            if let transport = item.facts?["transport"] {
                words.append(transport == "wired" ? "by cable" : transport == "usb" ? "over USB" : "over the network")
            }
            if let version = item.facts?["osVersion"] { words.append("OS \(version)") }
            line += ": " + words.joined(separator: ", ")
        case "locked": line += ": connected but locked; ask the person to unlock it before testing on it"
        case "held":
            line += ": in use by another task"
            if let title = item.holder?.title { line += " (\"\(title)\")" }
            line += "; wait for it or use another device"
        case "absent": line += ": not reachable from this machine right now"
        default: line += ": not checked"
        }
        if let lock = item.lock, !lock.isEmpty {
            line += ". Hold `lockf -k -t 3600 \(lock) <command>` around anything you install or run on it"
        }
        if item.kind == "command", let command = item.command { line += ". Proved by `\(command)`" }
        return line + "."
    }

    private static func day(_ date: Date, _ zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = zone
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    private static func moment(_ date: Date, _ zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = zone
        formatter.dateFormat = "d MMM HH:mm"
        return formatter.string(from: date)
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}
