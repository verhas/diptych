import Foundation
import Observation

/// The cancel flag and the byte counter, shared between the thread doing the
/// copying and the main actor drawing the sheet.
///
/// Not an actor: the copy callback runs inside `copyfile(3)` on a dispatch
/// queue and cannot await anything. A lock around two words is the whole
/// synchronisation this needs.
final class TransferMonitor: @unchecked Sendable {

    private let lock = NSLock()
    private var cancelled = false
    private var bytes: Int64 = 0
    /// Bytes from items that finished, so each new item starts counting from
    /// where the last one stopped rather than from zero.
    private var completed: Int64 = 0
    private var item = ""
    private var lastReport = Date.distantPast

    /// Called at most ten times a second, on the copying thread. Reporting
    /// every callback would hop to the main actor thousands of times for one
    /// large file and cost more than the copy.
    var onProgress: (@Sendable (Int64, String) -> Void)?

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

    var completedBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    func addCompleted(_ amount: Int64) {
        lock.lock()
        completed += amount
        lock.unlock()
    }

    /// `bytes` is the running total across the whole transfer.
    func report(bytes newBytes: Int64, item newItem: String) {
        lock.lock()
        bytes = newBytes
        item = newItem
        let now = Date()
        let due = now.timeIntervalSince(lastReport) >= 0.1
        if due { lastReport = now }
        let callback = onProgress
        lock.unlock()

        if due { callback?(newBytes, newItem) }
    }

    /// The final figure, whatever the throttle last let through.
    func flush() {
        lock.lock()
        let (b, i, callback) = (bytes, item, onProgress)
        lock.unlock()
        callback?(b, i)
    }
}

/// What the progress sheet shows.
@MainActor
@Observable
final class TransferProgress {

    /// Nothing is shown before this. Most transfers are over well inside it,
    /// and a sheet that flashes up and vanishes is worse than no sheet.
    static let showAfter: Duration = .seconds(1)

    let verb: String
    let itemCount: Int
    private(set) var bytesTotal: Int64
    private(set) var bytesDone: Int64 = 0
    private(set) var currentItem = ""
    private(set) var itemsDone = 0
    private(set) var isCancelling = false

    private let startedAt = Date()

    init(verb: String, itemCount: Int, bytesTotal: Int64) {
        self.verb = verb
        self.itemCount = itemCount
        self.bytesTotal = bytesTotal
    }

    /// nil when the total is unknown, which makes the bar indeterminate rather
    /// than pretending to a precision it does not have.
    var fraction: Double? {
        guard bytesTotal > 0 else { return nil }
        return min(Double(bytesDone) / Double(bytesTotal), 1)
    }

    var detail: String {
        let done = ByteCountFormatter.string(fromByteCount: bytesDone, countStyle: .file)
        guard bytesTotal > 0 else { return done }
        let total = ByteCountFormatter.string(fromByteCount: bytesTotal, countStyle: .file)
        return "\(done) of \(total)"
    }

    /// Only once there is enough to extrapolate from. An estimate offered in
    /// the first moments of a copy is noise, and a wrong one is worse than none.
    var remaining: String? {
        let elapsed = Date().timeIntervalSince(startedAt)
        guard bytesTotal > 0, bytesDone > 0, elapsed > 2 else { return nil }
        let rate = Double(bytesDone) / elapsed
        guard rate > 0 else { return nil }
        let left = Double(bytesTotal - bytesDone) / rate
        guard left > 1, left < 60 * 60 * 24 else { return nil }

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = left < 60 ? [.second] : [.minute, .second]
        formatter.unitsStyle = .full
        return formatter.string(from: left).map { "about \($0) left" }
    }

    func update(bytes: Int64, item: String) {
        bytesDone = max(bytesDone, bytes)
        currentItem = item
    }

    func finishedItem() { itemsDone += 1 }
    func markCancelling() { isCancelling = true }
}
