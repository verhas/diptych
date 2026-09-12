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

    /// How many blocking calls may be in flight at once.
    ///
    /// Growing threads is the point, but not without end. Dispatch stops
    /// creating them at 64, and a machine with several sleeping USB disks can
    /// reach that with nothing but directory listings: each one waits seconds
    /// for a disk to spin up, the next arrives before the last returns, and at
    /// 64 the whole process stops -- every queue in it, not only this one.
    /// Sampling it says so in as many words: "too many dispatch threads
    /// blocked in synchronous operations".
    ///
    /// Held well below that, so a slow disk makes Diptych wait rather than
    /// making it stop.
    private static let permits = DispatchSemaphore(value: 12)

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                permits.wait()
                defer { permits.signal() }
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                permits.wait()
                defer { permits.signal() }
                continuation.resume(returning: work())
            }
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
