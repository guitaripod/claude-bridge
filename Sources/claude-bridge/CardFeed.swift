import Foundation

/// Hands the Live Activity pusher what happened to each conversation in the order it happened.
///
/// Every call used to ride a task of its own, and separate tasks reach an actor in no promised
/// order: a queued prompt's turn began on the wire before the turn ahead of it had finished, the
/// card heard the new turn start first and the old one end last, and settled while the new turn
/// ran on with nothing to bring it back.
final class CardFeed: Sendable {
    typealias Step = @Sendable () async -> Void

    private let continuation: AsyncStream<Step>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<Step>.makeStream()
        self.continuation = continuation
        Task.detached {
            for await step in stream { await step() }
        }
    }

    func send(_ step: @escaping Step) {
        continuation.yield(step)
    }

    /// Returns once everything sent before it has reached the pusher.
    func drained() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            continuation.yield { done.resume() }
        }
    }
}
