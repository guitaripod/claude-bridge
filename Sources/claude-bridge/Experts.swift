import Foundation

/// A device or service an expert works with, as the person described it, and — when served — what
/// the machine found when it last looked. The state fields are never stored: a stored item is only
/// its description, and every answer proves it again or says when it last did.
struct BenchItem: Codable, Sendable, Equatable {
    var id: String
    var name: String
    /// `appleDevice` (an iPhone, iPad or other device the machine reaches with devicectl or
    /// pymobiledevice3), `command` (a probe that exits 0 when the thing is there), or `port`.
    var kind: String
    /// For an Apple device: its UDID, its CoreDevice identifier or its name.
    var identifier: String?
    var command: String?
    var host: String?
    var port: Int?
    /// A lock file the expert holds around work on this item (`lockf -k <file> …`), so two tasks
    /// never install on the same iPad at once and the bench can say which task holds it.
    var lock: String?
    /// `ready`, `absent`, `locked`, `held` or `unknown`.
    var state: String?
    /// Facts the proof found, as keys and values a client words: `model`, `os`, `osVersion`,
    /// `transport` (`wired`, `network`, `usb`), `output` (a probe's first line).
    var facts: [String: String]?
    var holder: BenchHolder?
    var checkedAt: Date?

    static let kinds: Set<String> = ["appleDevice", "command", "port"]

    /// The item as it is stored: its description without anything a proof found.
    var described: BenchItem {
        BenchItem(
            id: id, name: name, kind: kind, identifier: identifier, command: command, host: host,
            port: port, lock: lock)
    }
}

struct BenchHolder: Codable, Sendable, Equatable {
    var sessionID: String?
    var title: String?
    var pid: Int32?
}

/// A command that has to keep passing for the expert's world to be well: a test run, or a number
/// the command prints held under (or over) a line.
struct GuardItem: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var command: String
    var directory: String?
    var metric: GuardMetric?
    /// Seconds a run is given before it is stopped and counted as failed.
    var timeout: Int?
    /// Served, never stored: the latest run, the runs before it, and whether one is going now.
    var last: GuardRun?
    var history: [GuardRun]?
    var running: Bool?

    var described: GuardItem {
        GuardItem(
            id: id, name: name, command: command, directory: directory, metric: metric,
            timeout: timeout)
    }
}

/// A number read out of a guard's output: the last match of `pattern`'s first group.
struct GuardMetric: Codable, Sendable, Equatable {
    var pattern: String
    var atMost: Double?
    var atLeast: Double?
    var unit: String?
}

struct GuardRun: Codable, Sendable, Equatable {
    var at: Date
    var passed: Bool
    var seconds: Double
    var exitCode: Int32?
    var value: Double?
    /// The output's last lines, for a run that failed.
    var output: String?
    /// `timeout` when the run was stopped, `metric` when the number missed its line, `exit`
    /// when the command failed, `missing` when the value could not be read.
    var failure: String?
}

struct NotebookFacts: Codable, Sendable, Equatable {
    var path: String
    var adopted: Bool
    var notes: Int
    var stale: Int
    var retired: Int
}

/// One fact in an expert's notebook: a file with a front matter, the format of a Claude Code
/// memory folder, so an adopted folder and a new one read alike.
struct Note: Codable, Sendable, Equatable {
    /// The file name inside the notebook.
    var id: String
    var title: String
    var summary: String
    var body: String?
    var type: String?
    var written: Date?
    var confirmed: Date?
    var source: String?
    var stale: Bool
    var retired: NoteRetirement?
}

struct NoteRetirement: Codable, Sendable, Equatable {
    var at: Date?
    var reason: String?
}

struct JournalEntry: Codable, Sendable, Equatable {
    var id: String
    var sessionID: String?
    var title: String
    var at: Date
    var outcome: String
    var measured: [String]
    var commits: [String]
}

/// A change to the notebook an expert proposes at the end of a task. Nothing is written until the
/// person accepts it.
struct Proposal: Codable, Sendable, Equatable {
    var id: String
    /// `add`, `change` or `retire`.
    var op: String
    /// The note a change or a retirement is about, by file name.
    var note: String?
    var title: String
    var summary: String
    var body: String
    var reason: String
    /// `pending`, `accepted` or `skipped`.
    var state: String
}

struct Debrief: Codable, Sendable, Equatable {
    var sessionID: String
    var expertID: String
    var at: Date
    /// How many of the person's messages the task had when this debrief read it, so a task that
    /// went on afterwards is debriefed again when it next finishes.
    var coveredTurns: Int
    /// `drafting`, `open` (proposals wait for the person), `settled` or `failed`.
    var state: String
    var failure: String?
    var journal: JournalEntry?
    var proposals: [Proposal]

    var pending: Int { state == "open" ? proposals.filter { $0.state == "pending" }.count : 0 }
}

struct ExpertTaskRef: Codable, Sendable, Equatable {
    var sessionID: String
    var title: String
    var updatedAt: Date
    var active: Bool
    /// The debrief's state, when the task has one.
    var debrief: String?
}

/// An expert as it is stored: who it is and what it carries into every task.
struct Expert: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var glyph: String
    var hue: String
    var purpose: String
    var directory: String?
    var model: String?
    var effort: String?
    var charter: String
    var skills: [String]
    /// A memory folder adopted as the notebook; nil keeps one beside the expert.
    var notebookPath: String?
    var bench: [BenchItem]
    var guards: [GuardItem]
    /// When the guards run on their own; nil runs them only when asked.
    var guardRule: ScheduleRule?
    var timeZone: String
    var createdAt: Date
    var updatedAt: Date

    static let hues: Set<String> = [
        "blue", "orange", "green", "purple", "pink", "teal", "indigo", "red", "yellow", "gray",
    ]
}

/// An expert as a client reads it: what it is, and what the machine knows about it now.
struct ExpertView: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var glyph: String
    var hue: String
    var purpose: String
    var directory: String?
    var model: String?
    var effort: String?
    var charter: String
    var skills: [String]
    var notebookPath: String?
    var bench: [BenchItem]
    var guards: [GuardItem]
    var guardRule: ScheduleRule?
    var guardNext: Date?
    var timeZone: String
    var createdAt: Date
    var updatedAt: Date
    var notebook: NotebookFacts
    var journal: [JournalEntry]
    /// The task running now, when one is.
    var task: ExpertTaskRef?
    var tasks: [ExpertTaskRef]
    /// Notebook proposals waiting for the person, across every open debrief.
    var pending: Int
    var briefTokens: Int
    var watches: [String]
}

struct ExpertDraft: Codable, Sendable {
    var name: String
    var glyph: String?
    var hue: String?
    var purpose: String?
    var directory: String?
    var model: String?
    var effort: String?
    var charter: String?
    var skills: [String]?
    var notebookPath: String?
    var bench: [BenchItem]?
    var guards: [GuardItem]?
    var guardRule: ScheduleRule?
    var timeZone: String?
    /// Notes written into the notebook as the expert is made.
    var notes: [DraftNote]?
}

struct DraftNote: Codable, Sendable, Equatable {
    var title: String
    var summary: String
    var body: String
    var type: String?
    /// False for a fact that held only on the day it was drafted from; a client offers it
    /// unticked.
    var lasting: Bool?
}

struct ExpertPatch: Codable, Sendable {
    var name: String?
    var glyph: String?
    var hue: String?
    var purpose: String?
    var directory: String?
    var model: String?
    var effort: String?
    var charter: String?
    var skills: [String]?
    var notebookPath: String?
    var bench: [BenchItem]?
    var guards: [GuardItem]?
    var guardRule: ScheduleRule?
    /// True clears the guard rule, since a nil rule in a patch means "unchanged".
    var guardsOnDemand: Bool?
    var timeZone: String?
}

struct ExpertDraftRequest: Codable, Sendable {
    var session: String?
    var skill: String?
}

struct ExpertTaskRequest: Codable, Sendable {
    var text: String
    var title: String?
    var model: String?
    var effort: String?
    var directory: String?
}

struct ExpertTaskStarted: Codable, Sendable {
    var session: SessionSummary
    var queued: Int?
}

struct DebriefDecision: Codable, Sendable {
    var accepted: [String]
    var skipped: [String]?
    /// Words the person changed before accepting, by proposal id.
    var edits: [String: ProposalEdit]?
}

struct ProposalEdit: Codable, Sendable {
    var title: String?
    var summary: String?
    var body: String?
}

struct SkillInfo: Codable, Sendable, Equatable {
    var name: String
    var description: String
    var path: String
}

struct ExpertBriefPreview: Codable, Sendable {
    var text: String
    var tokens: Int
}

enum ExpertError: Error, CustomStringConvertible, Sendable {
    case invalid(String)
    case unknown
    case unknownSession
    case busy(String)

    var description: String {
        switch self {
        case .invalid(let why): return why
        case .unknown: return "There is no such expert on this machine."
        case .unknownSession: return "That conversation is not one of this machine's expert tasks."
        case .busy(let why): return why
        }
    }
}
