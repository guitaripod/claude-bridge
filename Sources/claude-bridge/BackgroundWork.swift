import Foundation

/// One workflow run that outlived nothing, and how far its journal had got when we looked.
///
/// The progress mark is what separates a run still worth continuing from one that is simply
/// stuck: offered once and unchanged since, it is abandoned; longer than last time, it moved.
struct OrphanedRun: Sendable, Equatable {
    var id: String
    var progress: Int
}

/// Work a turn started in the background and did not live long enough to finish.
///
/// A headless `claude -p` is one process per turn: workflows, subagents and background shell
/// commands all live inside it, and the runner terminates it once its output reaches EOF. Anything
/// still running dies there. The harness notices on the *next* turn and says so — which is why a
/// person watching from a phone sees a session that looks finished, and has to send something,
/// anything, before the work picks itself back up. Naming the orphans here is what lets the bridge
/// send that something on their behalf.
struct PendingBackground: Sendable, Equatable {
    /// Workflow runs whose journal records agents that started and never returned.
    var workflows: [OrphanedRun]

    var isEmpty: Bool { workflows.isEmpty }

    /// What is unfinished, in words worth showing a person.
    var reason: String {
        switch workflows.count {
        case 0: return "Nothing is unfinished."
        case 1: return "A workflow was still running when the turn ended."
        default: return "\(workflows.count) workflows were still running when the turn ended."
        }
    }

    static let none = PendingBackground(workflows: [])
}

/// Reads the harness's own on-disk record of what a turn left running.
///
/// Nothing here talks to the CLI. A workflow journal — one line per agent, `started` when it is
/// launched and `result` when it returns — is the only evidence that survives the process, so it
/// is also the only thing a bridge that outlives the process can read.
///
/// Background shell commands are deliberately *not* counted. Their output files carry no marker
/// separating one the turn was waiting on from the hundreds written by ordinary foreground tool
/// calls, so every heuristic over them fires constantly on work that finished perfectly well.
enum BackgroundScan {
    /// Runs older than this are somebody's abandoned experiment, not work in flight.
    static let recency: TimeInterval = 3600

    /// Claude Code names a project directory by replacing every path separator with a dash.
    static func projectSlug(for directory: String) -> String {
        directory.replacingOccurrences(of: "/", with: "-")
    }

    static func pending(
        claudeSessionID: String?, directory: String?, now: Date = Date()
    ) -> PendingBackground {
        guard let claudeSessionID, !claudeSessionID.isEmpty, let directory, !directory.isEmpty
        else { return .none }
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(
                ".claude/projects/\(projectSlug(for: directory))/\(claudeSessionID)/subagents/workflows",
                isDirectory: true)
        guard let runs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return .none }
        let orphans = runs.compactMap { run -> OrphanedRun? in
            guard let progress = orphanProgress(run, now: now) else { return nil }
            return OrphanedRun(id: run.lastPathComponent, progress: progress)
        }
        return PendingBackground(workflows: orphans.sorted { $0.id < $1.id })
    }

    /// A journal holding more `started` lines than `result` lines never delivered every agent it
    /// launched. Comparing the two counts is deliberate: a run that legitimately returned early
    /// still balances, and a run killed mid-fan-out cannot.
    private static func orphanProgress(_ run: URL, now: Date) -> Int? {
        let journal = run.appendingPathComponent("journal.jsonl")
        guard let modified = try? journal.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate,
            now.timeIntervalSince(modified) < recency,
            let text = try? String(contentsOf: journal, encoding: .utf8)
        else { return nil }
        var started = 0
        var finished = 0
        for line in text.split(separator: "\n") {
            if line.contains("\"type\":\"started\"") { started += 1 }
            if line.contains("\"type\":\"result\"") { finished += 1 }
        }
        guard started > finished else { return nil }
        return started + finished
    }
}

/// How many turns in a row the bridge may pick a session back up on its own.
///
/// The cap exists because the signal is a heuristic about someone else's files: a workflow that
/// genuinely cannot finish would otherwise be relaunched forever, burning tokens on a phone in
/// somebody's pocket. Any prompt a person sends resets the count, because a person watching is a
/// better judge of whether to keep going than this rule is.
enum AutoContinue {
    static let limit = 8

    static let prompt = """
        The previous turn ended while background work was still running, so that work was stopped \
        rather than finished. Pick it back up: check what was left unfinished, resume it where it \
        can be resumed, and carry on with the task that started it. Do not start over.
        """
}

/// A turn that ended because the account ran out of session quota rather than because the work
/// finished.
///
/// This is not an error to report and forget: the work is still there, and the only thing standing
/// between it and finishing is time. The refusal names the hour it lifts, so the bridge can wait
/// exactly that long and carry on by itself — which is the difference between a run that pauses
/// overnight and a run that ends there.
enum Cooldown {
    /// A little past the stated minute, because a reset announced for 11:10pm is not reliably
    /// spendable at 11:10:00pm.
    static let margin: TimeInterval = 90

    static func mentionsLimit(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("session limit") || lowered.contains("usage limit")
            || lowered.contains("rate limit")
    }

    /// The next moment the stated clock time comes around. A reset "at 11:10pm" written at 8pm is
    /// tonight; the same words written at 11:30pm mean tomorrow.
    static func resetsAt(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard mentionsLimit(text), let clock = clock(in: text) else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = clock.hour
        components.minute = clock.minute
        components.second = 0
        guard let candidate = calendar.date(from: components) else { return nil }
        if candidate > now { return candidate }
        return calendar.date(byAdding: .day, value: 1, to: candidate)
    }

    private static func clock(in text: String) -> (hour: Int, minute: Int)? {
        let pattern = #"resets\s+(\d{1,2})(?::(\d{2}))?\s*([ap]m)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = expression.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        guard let rawHour = group(1).flatMap(Int.init), let suffix = group(3)?.lowercased()
        else { return nil }
        let minute = group(2).flatMap(Int.init) ?? 0
        var hour = rawHour % 12
        if suffix == "pm" { hour += 12 }
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return (hour, minute)
    }

    static func notice(_ moment: Date, formatter: DateFormatter = Cooldown.formatter) -> String {
        "The session limit was reached. Picking the work back up at \(formatter.string(from: moment))."
    }

    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
