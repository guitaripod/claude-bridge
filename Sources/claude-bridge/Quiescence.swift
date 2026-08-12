import Foundation

/// Whether this machine is doing anything a restart would destroy.
///
/// There is no single symbol for busy. A turn this bridge started lives in memory; a turn somebody
/// started in a terminal on the same machine exists only as a transcript growing on disk; and a
/// sign-in halfway through its two-machine handshake is a pseudo-terminal belonging to neither. A
/// restart ends all three, so the question gets one answer composed in one place — and until the
/// observer has actually looked once it answers *not quiet* rather than quiet, because a turn
/// adopted milliseconds ago has not reached any of those three yet and "nothing has been counted"
/// must never read as "nothing is running".
struct MachineQuiet: Codable, Sendable {
    var quiet: Bool
    /// Conversations with work in flight, however it was started.
    var turns: Int
    /// What is happening, in words worth showing a person. Absent when nothing is.
    var reason: String?

    static let unknown = MachineQuiet(
        quiet: false, turns: 0, reason: "This machine has not finished counting what it is doing.")

    static func read(turns: Int, signingIn: Bool, swept: Bool) -> MachineQuiet {
        guard swept else { return .unknown }
        if turns > 0 {
            return MachineQuiet(
                quiet: false, turns: turns,
                reason: turns == 1
                    ? "A turn is running on that machine."
                    : "\(turns) turns are running on that machine.")
        }
        if signingIn {
            return MachineQuiet(
                quiet: false, turns: 0,
                reason: "Somebody is halfway through signing Claude in on that machine.")
        }
        return MachineQuiet(quiet: true, turns: 0)
    }
}
