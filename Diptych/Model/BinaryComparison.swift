import Foundation

/// Two files compared byte by byte, for when at least one of them is not text.
///
/// A line-by-line comparison has nothing to say about a JPEG, and the window
/// that does it has nothing to offer either: find, wrap and ignore-spacing are
/// all about text. What somebody comparing two binaries wants is the answer to
/// one question -- are these the same file? -- and, when they are not, how far
/// they agree before they part.
///
/// Read in chunks rather than whole: two disk images are not going into memory
/// to answer a question that is usually settled by the first kilobyte.
struct BinaryComparison: Sendable, Equatable {

    let leftBytes: Int64
    let rightBytes: Int64
    /// Where the first differing byte is, or nil when neither file contradicts
    /// the other -- they are the same, or the shorter is the start of the
    /// longer.
    let firstDifference: Int64?

    /// Read this much at a time. Big enough that a large file is not a million
    /// system calls, small enough that two of them are not a memory problem.
    static let chunk = 1 << 20

    var isIdentical: Bool { firstDifference == nil && leftBytes == rightBytes }

    /// How much of the two files is the same, counted from the beginning.
    var commonPrefix: Int64 { firstDifference ?? min(leftBytes, rightBytes) }

    /// The shorter file is the exact beginning of the longer one.
    var oneIsTheStartOfTheOther: Bool {
        firstDifference == nil && leftBytes != rightBytes
    }

    // MARK: - Comparing

    static func compare(_ left: URL, _ right: URL) throws -> BinaryComparison {
        let leftHandle = try FileHandle(forReadingFrom: left)
        let rightHandle = try FileHandle(forReadingFrom: right)
        defer {
            try? leftHandle.close()
            try? rightHandle.close()
        }

        let leftSize = try size(of: left)
        let rightSize = try size(of: right)

        var offset: Int64 = 0
        while true {
            try Task.checkCancellation()
            let leftData = try leftHandle.read(upToCount: chunk) ?? Data()
            let rightData = try rightHandle.read(upToCount: chunk) ?? Data()
            if leftData.isEmpty || rightData.isEmpty { break }

            let shared = min(leftData.count, rightData.count)
            if let difference = firstDifference(leftData, rightData, within: shared) {
                return BinaryComparison(leftBytes: leftSize, rightBytes: rightSize,
                                        firstDifference: offset + Int64(difference))
            }
            offset += Int64(shared)
            // One chunk came back short: that file has ended, and everything
            // up to here matched.
            if leftData.count != rightData.count { break }
        }

        return BinaryComparison(leftBytes: leftSize, rightBytes: rightSize,
                                firstDifference: nil)
    }

    /// The offset of the first byte that differs in the first `count` bytes.
    ///
    /// `Data`'s own `==` answers whether two chunks match, which is the common
    /// case and much the faster route: only when it says no is it worth looking
    /// for where.
    private static func firstDifference(_ left: Data, _ right: Data,
                                        within count: Int) -> Int? {
        guard left.prefix(count) != right.prefix(count) else { return nil }
        return left.withUnsafeBytes { leftBytes in
            right.withUnsafeBytes { rightBytes -> Int in
                for index in 0 ..< count where leftBytes[index] != rightBytes[index] {
                    return index
                }
                return count
            }
        }
    }

    private static func size(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Saying it

    /// The whole answer, in the order it matters: same or not, then how far
    /// they agree, then how big they are.
    func verdict(left: String, right: String) -> String {
        if isIdentical {
            return leftBytes == 0
                ? "Both files are empty."
                : "The two files are exactly the same, byte for byte "
                  + "(\(Self.bytes(leftBytes)))."
        }

        if oneIsTheStartOfTheOther {
            let shorterIsLeft = leftBytes < rightBytes
            let shorter = shorterIsLeft ? left : right
            let longer = shorterIsLeft ? right : left
            let shorterSize = min(leftBytes, rightBytes)
            if shorterSize == 0 {
                return "The two files differ: \u{201C}\(shorter)\u{201D} is empty, and "
                    + "\u{201C}\(longer)\u{201D} is \(Self.bytes(max(leftBytes, rightBytes)))."
            }
            return "The two files differ, but nothing in them contradicts: "
                + "\u{201C}\(shorter)\u{201D} is exactly the first "
                + "\(Self.bytes(shorterSize)) of \u{201C}\(longer)\u{201D}, which goes on for "
                + "\(Self.bytes(max(leftBytes, rightBytes) - shorterSize)) more."
        }

        let where_ = commonPrefix == 0
            ? "The two files differ from the very first byte."
            : "The two files differ, but their first \(Self.bytes(commonPrefix)) are identical "
              + "\u{2014} they part at byte \(commonPrefix + 1) (offset "
              + String(format: "0x%llX", commonPrefix) + ")."
        return where_ + " \u{201C}\(left)\u{201D} is \(Self.bytes(leftBytes)), "
            + "\u{201C}\(right)\u{201D} is \(Self.bytes(rightBytes))."
    }

    /// "12 bytes", or "1.2 MB (1,234,567 bytes)" -- the round number to read
    /// and the exact one to act on.
    static func bytes(_ count: Int64) -> String {
        let exact = count.formatted(.number)
        guard count >= 1000 else { return "\(exact) byte\(count == 1 ? "" : "s")" }
        let readable = ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
        return "\(readable) (\(exact) bytes)"
    }
}
