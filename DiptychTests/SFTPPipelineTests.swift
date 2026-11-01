import XCTest
@testable import Diptych

/// Many SFTP requests under way at once, against a fake server whose answers
/// come back late and out of order.
final class SFTPPipelineTests: XCTestCase {

    /// A server file, and what was asked of it.
    actor Server {
        var bytes: Data
        /// The most bytes it answers in one read, as servers cap their answers.
        let cap: Int
        private(set) var underWay = 0
        private(set) var mostUnderWay = 0
        private(set) var writes: [UInt64: Data] = [:]

        init(bytes: Data = Data(), cap: Int = .max) {
            self.bytes = bytes
            self.cap = cap
        }

        func read(_ offset: UInt64, _ length: UInt32) async -> Data {
            begin()
            await jitter(offset)
            defer { underWay -= 1 }
            let start = Int(offset)
            guard start < bytes.count else { return Data() }
            let end = min(bytes.count, start + min(Int(length), cap))
            return bytes.subdata(in: start..<end)
        }

        func write(_ piece: Data, _ offset: UInt64) async {
            begin()
            await jitter(offset)
            defer { underWay -= 1 }
            writes[offset] = piece
        }

        func grow(by more: Data) { bytes.append(more) }

        private func begin() {
            underWay += 1
            mostUnderWay = max(mostUnderWay, underWay)
        }

        /// Answers late, by an amount that depends on the offset: out of order.
        private func jitter(_ offset: UInt64) async {
            try? await Task.sleep(for: .microseconds(Int(offset % 7) * 300))
        }
    }

    private static func bytes(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
    }

    /// Writes into a buffer at their offsets, in the order they come.
    private final class Sink {
        var data = Data()
        func write(_ piece: Data, _ offset: UInt64) {
            let end = Int(offset) + piece.count
            if data.count < end { data.append(Data(count: end - data.count)) }
            data.replaceSubrange(Int(offset)..<end, with: piece)
        }
    }

    func testASendIsWrittenWholeWithManyWritesUnderWay() async throws {
        let original = Self.bytes(1_000_000)
        let server = Server()
        var reader = 0
        let sent = try await SFTPPipeline.send(
            next: {
                guard reader < original.count else { return nil }
                let end = min(original.count, reader + SFTPPipeline.writePiece)
                defer { reader = end }
                return original.subdata(in: reader..<end)
            },
            write: { piece, offset in await server.write(piece, offset) },
            window: 8)

        XCTAssertEqual(sent, UInt64(original.count))
        let sink = Sink()
        for (offset, piece) in await server.writes { sink.write(piece, offset) }
        XCTAssertEqual(sink.data, original)
        let most = await server.mostUnderWay
        XCTAssertGreaterThan(most, 1, "one at a time: not pipelined")
        XCTAssertLessThanOrEqual(most, 8)
    }

    func testAFailedWriteEndsTheSend() async {
        struct Refused: Error {}
        var given = 0
        do {
            _ = try await SFTPPipeline.send(
                next: {
                    given += 1
                    return given > 100 ? nil : Data(count: 10)
                },
                write: { _, offset in if offset == 300 { throw Refused() } },
                window: 4)
            XCTFail("the failure was hidden")
        } catch {
            XCTAssertTrue(error is Refused)
        }
    }

    /// The server caps what one read answers: each read comes back short, and the
    /// rest is asked again. The file still arrives whole.
    func testAReceiveWithShortAnswersArrivesWhole() async throws {
        let original = Self.bytes(300_000)
        let server = Server(bytes: original, cap: 10_000)
        let sink = Sink()
        let end = try await SFTPPipeline.receive(
            expected: UInt64(original.count),
            read: { offset, length in await server.read(offset, length) },
            write: { piece, offset in sink.write(piece, offset) },
            window: 16)

        XCTAssertEqual(end, UInt64(original.count))
        XCTAssertEqual(sink.data, original)
        let most = await server.mostUnderWay
        XCTAssertGreaterThan(most, 1, "one at a time: not pipelined")
        XCTAssertLessThanOrEqual(most, 16)
    }

    /// Grown on the server since it was opened: what it has now is read.
    func testAReceiveReadsWhatAFileGrewBy() async throws {
        let original = Self.bytes(100_000)
        let server = Server(bytes: original)
        await server.grow(by: Self.bytes(5_000))
        let sink = Sink()
        let end = try await SFTPPipeline.receive(
            expected: UInt64(original.count),
            read: { offset, length in await server.read(offset, length) },
            write: { piece, offset in sink.write(piece, offset) })

        XCTAssertEqual(end, 105_000)
        XCTAssertEqual(sink.data, original + Self.bytes(5_000))
    }

    /// Shortened on the server since it was opened: where it ended is said, so
    /// the caller can refuse it as not the whole file.
    func testAReceiveSaysWhereAShortenedFileEnded() async throws {
        let server = Server(bytes: Self.bytes(70_000))
        let sink = Sink()
        let end = try await SFTPPipeline.receive(
            expected: 200_000,
            read: { offset, length in await server.read(offset, length) },
            write: { piece, offset in sink.write(piece, offset) })

        XCTAssertEqual(end, 70_000)
        XCTAssertEqual(sink.data, Self.bytes(70_000))
    }

    /// No size given: read to the end, one piece at a time.
    func testAReceiveWithNoSizeReadsToTheEnd() async throws {
        let original = Self.bytes(80_000)
        let server = Server(bytes: original)
        let sink = Sink()
        let end = try await SFTPPipeline.receive(
            expected: nil,
            read: { offset, length in await server.read(offset, length) },
            write: { piece, offset in sink.write(piece, offset) })

        XCTAssertEqual(end, 80_000)
        XCTAssertEqual(sink.data, original)
    }
}
