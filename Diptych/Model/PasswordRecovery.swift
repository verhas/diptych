import Foundation

/// What the Recover Password window is opened on: the zip to try passwords
/// against.
struct PasswordRecoveryRequest: Codable, Hashable, Sendable {
    var archive: URL
}

/// Trying passwords against an encrypted zip, for an archive that is your own.
///
/// Two of us have had this happen: a zip arrives and the password the sender
/// read out was mistyped by one of us, or an archive turns up from years ago
/// with a password long forgotten. The verifier in `Archiving` can say whether
/// a candidate is the right one without unpacking anything and without running
/// tar, so a great many can be tried quickly; this decides *which* to try.
///
/// - **From a guess.** Given a password you half-remember, candidates radiate
///   outward from it by a keyboard-aware edit distance: the nearest first --
///   a neighbouring key struck, a letter's case wrong, two keys swapped, one
///   doubled or dropped -- then farther and farther. A sender's slip or your
///   own shaky memory is usually a key or two away, so this finds it long
///   before a blind search would reach it.
/// - **Brute force.** Every string up to a length you set, over an alphabet
///   you choose. Honest about itself: the search space and the time it would
///   take are worked out first and shown, because past a short password and a
///   small alphabet the answer is "not in your lifetime".
///
/// None of this can open an archive that is not yours to open. It only tries
/// passwords, which anyone may do to their own files and which free tools have
/// done for decades; serious recovery belongs to the GPU tools named in
/// `PasswordRecovery.professionalTools`. The legal note is `legalNotice`.
enum PasswordRecovery {

    /// Shown in the window, because recovery is lawful on your own archives and
    /// not on other people's.
    static let legalNotice =
        "Trying passwords is lawful on an archive that is yours, or one you "
        + "have the owner's permission to open -- a file you were sent, or one "
        + "of your own whose password you have lost. Using it to open someone "
        + "else's archive without their leave may be a crime where you live. "
        + "What you do with it is yours to answer for."

    /// Pointed to for anything past a short password: these use the GPU, which
    /// is orders of magnitude faster than any CPU search here.
    static let professionalTools =
        "For a long or truly unknown password, a GPU tool is far faster than "
        + "this: hashcat (mode 13600 for WinZip AES, 17200/17210/17225 for "
        + "ZipCrypto) and John the Ripper (zip2john, then john) run the search "
        + "on the graphics card, millions to billions of guesses a second. "
        + "Diptych's search is the CPU, and meant for a password nearly right."

    // MARK: - Alphabets

    /// The character sets a brute-force search can range over, smallest first:
    /// each larger one multiplies the space and so the time.
    enum Alphabet: String, CaseIterable, Identifiable, Sendable {
        case digits, lower, lowerDigits, alpha, alphaDigits, printable
        var id: String { rawValue }

        var characters: [Character] {
            let digits = Array("0123456789")
            let lower = Array("abcdefghijklmnopqrstuvwxyz")
            let upper = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            let symbols = Array("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~ ")
            switch self {
            case .digits:      return digits
            case .lower:       return lower
            case .lowerDigits: return lower + digits
            case .alpha:       return lower + upper
            case .alphaDigits: return lower + upper + digits
            case .printable:   return lower + upper + digits + symbols
            }
        }

        var label: String {
            switch self {
            case .digits:      return "Digits (0–9)"
            case .lower:       return "Lower-case letters"
            case .lowerDigits: return "Lower-case letters and digits"
            case .alpha:       return "Letters, both cases"
            case .alphaDigits: return "Letters and digits"
            case .printable:   return "Everything typable"
            }
        }
    }

    // MARK: - Candidate sources

    /// Somewhere the search pulls its next candidate from. Called only while
    /// the search holds its lock, so a source need not be thread-safe itself.
    protocol CandidateSource: AnyObject {
        func next() -> String?
        /// How many it will ever yield, when that is known (brute force) and
        /// small enough to hold in a `UInt64`; nil otherwise (from a guess, or
        /// a space too vast to count).
        var total: UInt64? { get }
    }

    /// Candidates radiating outward from a seed by keyboard-weighted edit
    /// distance, nearest first. A best-first walk: each string popped is handed
    /// back to be tried, and its single-edit neighbours are pushed on with
    /// their added cost. A string is kept the first time it is reached, which
    /// is not always by its cheapest path, so the order is approximate -- near
    /// enough for "the password is a typo or two away", which is the point.
    final class NearGuessSource: CandidateSource {
        private var heap = MinHeap()
        private var seen: Set<String> = []
        private var order = 0
        private var produced = 0
        private let maxCost: Double
        private let maxCandidates: Int
        private let maxLength: Int
        let total: UInt64? = nil

        init(seed: String, maxCost: Double = 7, maxCandidates: Int = 5_000_000) {
            self.maxCost = maxCost
            self.maxCandidates = maxCandidates
            // Insertions could grow a string without end; a typo does not, so
            // candidates are let grow only a little past the guess.
            self.maxLength = max(seed.count + 6, 16)
            push(seed, 0)
        }

        private func push(_ value: String, _ cost: Double) {
            guard cost <= maxCost, !seen.contains(value) else { return }
            seen.insert(value)
            order += 1
            heap.push(cost: cost, order: order, value: value)
        }

        func next() -> String? {
            guard produced < maxCandidates, let item = heap.pop() else { return nil }
            produced += 1
            for (neighbour, step) in KeyboardLayout.neighbours(of: item.value, maxLength: maxLength) {
                push(neighbour, item.cost + step)
            }
            return item.value
        }
    }

    /// Every string of length 1 up to `maxLength` over `alphabet`, shortest
    /// first: an odometer whose wheels are the alphabet.
    final class BruteForceSource: CandidateSource {
        private let alphabet: [Character]
        private let maxLength: Int
        private var length = 1
        private var wheels: [Int]
        private var done = false
        let total: UInt64?

        init(alphabet: [Character], maxLength: Int) {
            self.alphabet = alphabet
            self.maxLength = max(1, maxLength)
            self.wheels = [0]
            self.total = PasswordRecovery.space(alphabet: alphabet.count, maxLength: self.maxLength)
            if alphabet.isEmpty { done = true }
        }

        func next() -> String? {
            guard !done else { return nil }
            let candidate = String(wheels.map { alphabet[$0] })
            advance()
            return candidate
        }

        /// The odometer: turn the last wheel; on a full turn, carry left; when
        /// the first wheel turns over, add a wheel -- a longer password.
        private func advance() {
            var position = wheels.count - 1
            while position >= 0 {
                wheels[position] += 1
                if wheels[position] < alphabet.count { return }
                wheels[position] = 0
                position -= 1
            }
            if length == maxLength { done = true; return }
            length += 1
            wheels = [Int](repeating: 0, count: length)
        }
    }

    // MARK: - The search

    /// Runs a source's candidates against the zip across every core, stopping
    /// at the first that opens it or when told to. Lives off the main actor,
    /// its state reached only under its own lock.
    final class Search: @unchecked Sendable {

        struct Progress: Sendable, Equatable {
            let tried: UInt64
            /// Nil when the source cannot say how many there are.
            let total: UInt64?
            let latest: String
            /// Guesses a second, measured.
            let rate: Double
        }

        enum Outcome: Sendable, Equatable {
            case found(String)
            case exhausted
            case cancelled
        }

        private let verifier: Archiving.ZipPasswordVerifier
        private let source: CandidateSource
        /// Confirms a fast hit by truly decrypting, so a ZipCrypto false
        /// positive is not handed back as the answer. Nil leaves the fast
        /// verifier's word final -- used only where decrypting is not wanted.
        private let confirm: (@Sendable (String) -> Bool)?
        private let lock = NSLock()
        private var cancelled = false
        private var found: String?
        private var tried: UInt64 = 0

        init(verifier: Archiving.ZipPasswordVerifier, source: CandidateSource,
             confirm: (@Sendable (String) -> Bool)? = nil) {
            self.verifier = verifier
            self.source = source
            self.confirm = confirm
        }

        func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
        }

        /// Blocks until the answer is found, the candidates run out, or it is
        /// cancelled. `report` is called from whichever thread reaches a
        /// milestone, so the receiver must hop to its own actor.
        func run(report: @escaping @Sendable (Progress) -> Void) -> Outcome {
            let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
            let started = Date()
            DispatchQueue.concurrentPerform(iterations: cores) { _ in
                while true {
                    lock.lock()
                    if cancelled || found != nil { lock.unlock(); return }
                    let candidate = source.next()
                    lock.unlock()
                    guard let candidate else { return }   // the source is spent

                    // The fast check first; a hit is confirmed by truly
                    // decrypting, outside the lock, so a ZipCrypto false
                    // positive does not end the search at a wrong password.
                    var opens = verifier.accepts(candidate)
                    if opens, let confirm { opens = confirm(candidate) }

                    lock.lock()
                    tried &+= 1
                    let triedNow = tried
                    if opens { found = candidate; cancelled = true }
                    let stop = cancelled || found != nil
                    lock.unlock()

                    if opens || triedNow & 0x3FFF == 0 {
                        report(Progress(tried: triedNow, total: source.total, latest: candidate,
                                        rate: Double(triedNow)
                                            / max(Date().timeIntervalSince(started), 0.001)))
                    }
                    if stop { return }
                }
            }
            lock.lock(); defer { lock.unlock() }
            if let found { return .found(found) }
            return cancelled ? .cancelled : .exhausted
        }
    }

    // MARK: - Counting the cost

    /// How many strings of length 1 up to `maxLength` there are over an
    /// alphabet of `alphabet` characters, or nil when that overflows a
    /// `UInt64` -- which is itself the answer: too many to ever search.
    static func space(alphabet: Int, maxLength: Int) -> UInt64? {
        guard alphabet > 0, maxLength > 0 else { return 0 }
        var total: UInt64 = 0
        var power: UInt64 = 1
        for _ in 1...maxLength {
            let (p, overP) = power.multipliedReportingOverflow(by: UInt64(alphabet))
            if overP { return nil }
            power = p
            let (t, overT) = total.addingReportingOverflow(power)
            if overT { return nil }
            total = t
        }
        return total
    }

    /// Seconds a single guess costs on this machine, measured now, so the
    /// estimate suits the scheme (AES's PBKDF2 is thousands of times dearer
    /// than ZipCrypto's) and the hardware rather than a guessed constant.
    static func secondsPerGuess(_ verifier: Archiving.ZipPasswordVerifier) -> Double {
        let sample = "measure-the-rate-0"
        var count = 0
        let started = Date()
        // Run in short bursts until enough time has passed to time reliably.
        repeat {
            for _ in 0..<64 { _ = verifier.accepts(sample) }
            count += 64
        } while Date().timeIntervalSince(started) < 0.02 && count < 1_000_000
        let elapsed = Date().timeIntervalSince(started)
        return elapsed / Double(max(count, 1))
    }

    /// How long a brute-force search would take at worst, as a phrase. `space`
    /// nil means it overflowed a `UInt64`; the cores share the work.
    static func estimate(space: UInt64?, secondsPerGuess: Double,
                         cores: Int = ProcessInfo.processInfo.activeProcessorCount) -> String {
        guard let space else { return "effectively forever -- more guesses than can be counted" }
        let seconds = Double(space) * secondsPerGuess / Double(max(cores, 1))
        return describe(seconds: seconds)
    }

    static func describe(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "effectively forever" }
        let minute = 60.0, hour = 3_600.0, day = 86_400.0, year = 365.0 * day
        switch seconds {
        case ..<1:           return "under a second"
        case ..<minute:      return "about \(Int(seconds.rounded())) seconds"
        case ..<hour:        return "about \(Int((seconds / minute).rounded())) minutes"
        case ..<day:         return "about \(Int((seconds / hour).rounded())) hours"
        case ..<year:        return "about \(Int((seconds / day).rounded())) days"
        case ..<(1_000 * year):           return "about \(Int((seconds / year).rounded())) years"
        case ..<(1_000_000_000 * year):   return "millions of years"
        default:                          return "effectively forever -- longer than the universe"
        }
    }
}

// MARK: - Keyboard layout

/// A US-QWERTY keyboard as physical key positions, so a substitution costs
/// what the slip would have cost: a neighbouring key is cheap, a key across
/// the board dear, and the shifted twin of a key -- its upper case, its
/// symbol -- cheaper still, a held or missed Shift.
enum KeyboardLayout {

    private struct Key { let row: Double; let col: Double; let shift: Bool }

    /// Each row's characters unshifted and shifted, left to right, with the
    /// small horizontal stagger a real keyboard has.
    private static let position: [Character: Key] = {
        let rows: [(unshifted: String, shifted: String, offset: Double)] = [
            ("`1234567890-=", "~!@#$%^&*()_+", 0.0),
            ("qwertyuiop[]\\", "QWERTYUIOP{}|", 0.5),
            ("asdfghjkl;'",    "ASDFGHJKL:\"",  0.75),
            ("zxcvbnm,./",     "ZXCVBNM<>?",    1.25),
        ]
        var map: [Character: Key] = [:]
        for (r, row) in rows.enumerated() {
            let lower = Array(row.unshifted), upper = Array(row.shifted)
            for (c, character) in lower.enumerated() {
                map[character] = Key(row: Double(r), col: Double(c) + row.offset, shift: false)
            }
            for (c, character) in upper.enumerated() {
                map[character] = Key(row: Double(r), col: Double(c) + row.offset, shift: true)
            }
        }
        // The space bar, far below, reached from nowhere near the letters.
        map[" "] = Key(row: 4, col: 5, shift: false)
        return map
    }()

    /// Every character the layout knows, both cases -- the pool a substitution
    /// or insertion may draw from.
    static let allKeys: [Character] = Array(position.keys)

    /// What swapping `a` for `b` should cost: a Shift slip for the same key,
    /// otherwise the distance between the keys, with a little more when one is
    /// shifted and the other not. Unknown characters are treated as far away.
    static func substitutionCost(_ a: Character, _ b: Character) -> Double {
        guard let ka = position[a], let kb = position[b] else { return 2.5 }
        if ka.row == kb.row, ka.col == kb.col { return ka.shift == kb.shift ? 0 : 0.5 }
        let distance = ((ka.row - kb.row) * (ka.row - kb.row)
                        + (ka.col - kb.col) * (ka.col - kb.col)).squareRoot()
        return distance + (ka.shift == kb.shift ? 0 : 0.4)
    }

    /// Every string one edit from `s`, with that edit's cost: a near-key
    /// substitution, an adjacent swap, a deletion, or an insertion of a
    /// doubled or near key. Far substitutions and insertions are left out, so
    /// the frontier stays the shape of a plausible typo rather than all of it.
    static func neighbours(of s: String, maxLength: Int) -> [(String, Double)] {
        var result: [(String, Double)] = []
        let chars = Array(s)
        let n = chars.count

        // Substitutions with a nearby key, case twins included.
        for i in 0..<n {
            for c in allKeys where c != chars[i] {
                let cost = substitutionCost(chars[i], c)
                if cost <= 2.5 {
                    var copy = chars; copy[i] = c
                    result.append((String(copy), cost))
                }
            }
        }
        // Transposition of two adjacent keys.
        if n >= 2 {
            for i in 0..<(n - 1) where chars[i] != chars[i + 1] {
                var copy = chars; copy.swapAt(i, i + 1)
                result.append((String(copy), 0.7))
            }
        }
        // Deletions; dropping one of a doubled pair is the cheaper, commoner slip.
        for i in 0..<n {
            var copy = chars; copy.remove(at: i)
            let doubled = i > 0 && chars[i] == chars[i - 1]
            result.append((String(copy), doubled ? 0.7 : 1.0))
        }
        // Insertions: a doubled key, or a key next to one bordering the gap.
        if n < maxLength {
            for j in 0...n {
                var inserts: [(Character, Double)] = []
                if j > 0 { inserts.append((chars[j - 1], 0.7)) }
                if j < n { inserts.append((chars[j], 0.7)) }
                for base in [j > 0 ? chars[j - 1] : nil, j < n ? chars[j] : nil].compactMap({ $0 }) {
                    for c in allKeys {
                        let cost = substitutionCost(base, c)
                        if cost > 0, cost <= 1.3 { inserts.append((c, 1.0 + cost * 0.3)) }
                    }
                }
                for (c, cost) in inserts {
                    var copy = chars; copy.insert(c, at: j)
                    result.append((String(copy), cost))
                }
            }
        }
        return result
    }
}

// MARK: - A small binary heap

/// A min-heap of candidates ordered by cost, ties broken by insertion order so
/// the walk is deterministic. Swift has no priority queue of its own.
private struct MinHeap {
    private var items: [(cost: Double, order: Int, value: String)] = []

    var isEmpty: Bool { items.isEmpty }

    mutating func push(cost: Double, order: Int, value: String) {
        items.append((cost, order, value))
        siftUp(items.count - 1)
    }

    mutating func pop() -> (cost: Double, order: Int, value: String)? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let out = items.removeLast()
        if !items.isEmpty { siftDown(0) }
        return out
    }

    private func precedes(_ a: Int, _ b: Int) -> Bool {
        items[a].cost != items[b].cost ? items[a].cost < items[b].cost
                                       : items[a].order < items[b].order
    }

    private mutating func siftUp(_ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard precedes(child, parent) else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ index: Int) {
        var parent = index
        while true {
            let left = 2 * parent + 1, right = left + 1
            var best = parent
            if left < items.count, precedes(left, best) { best = left }
            if right < items.count, precedes(right, best) { best = right }
            guard best != parent else { break }
            items.swapAt(best, parent)
            parent = best
        }
    }
}
