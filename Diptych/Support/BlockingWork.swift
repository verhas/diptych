import Foundation

/// Runs blocking file-system work off the main thread *and* off the Swift
/// concurrency pool.
///
/// `Task.detached` would be the obvious choice and is the wrong one here. The
/// cooperative pool has about as many threads as the machine has cores, and it
/// expects work to yield rather than block. A `contentsOfDirectory` on a USB
/// disk that is still spinning up blocks for seconds, and a few of those park
/// enough of the pool to stall everything else -- including whatever the UI is
/// waiting on. A dedicated concurrent queue grows threads instead of starving.
enum BlockingWork {

    private static let queue = DispatchQueue(label: "dev.verhas.Diptych.filesystem",
                                             qos: .userInitiated,
                                             attributes: .concurrent)

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

/// A cancellation signal that can cross into blocking code.
///
/// `Task.isCancelled` is only meaningful inside a task; the work here runs on a
/// dispatch queue, so the flag is carried explicitly and polled between items.
/// The syscall in flight cannot be interrupted -- but everything after it can be
/// abandoned, which is the difference between a stale listing arriving late and
/// a stale listing being computed in full first.
final class CancellationFlag: @unchecked Sendable {

    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
