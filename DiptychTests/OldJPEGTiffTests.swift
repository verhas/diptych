import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import Diptych

/// Quick Look's page for a TIFF of old-style JPEG pages, which macOS draws
/// only as a thumbnail.
final class OldJPEGTiffTests: XCTestCase {

    /// A small JPEG to put inside.
    private func jpeg(width: Int, height: Int) -> Data {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let cg = CIContext().createCGImage(image, from: image.extent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString,
                                                           1, nil)!
        CGImageDestinationAddImage(destination, cg, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A TIFF the way Office Document Imaging wrote one: each page's JPEG
    /// first, then its directory, compression 6, pointing at it.
    private func tiff(_ jpegs: [(Data, Int, Int)], littleEndian: Bool = true,
                      compression: Int = 6) -> Data {
        func bytes(_ value: Int, _ size: Int) -> [UInt8] {
            let little = (0..<size).map { UInt8((value >> (8 * $0)) & 0xFF) }
            return littleEndian ? little : little.reversed()
        }
        var file: [UInt8] = (littleEndian ? [0x49, 0x49] : [0x4D, 0x4D]) + bytes(42, 2) + bytes(0, 4)
        var previousNext = 4
        for (jpeg, width, height) in jpegs {
            let start = file.count
            file += jpeg
            let directory = file.count
            file.replaceSubrange(previousNext..<(previousNext + 4), with: bytes(directory, 4))
            let entries: [(Int, Int, Int)] = [   // tag, type, value
                (256, 4, width), (257, 4, height), (259, 3, compression), (262, 3, 6),
                (513, 4, start), (514, 4, jpeg.count),
            ]
            file += bytes(entries.count, 2)
            for (tag, type, value) in entries {
                file += bytes(tag, 2) + bytes(type, 2) + bytes(1, 4)
                file += type == 3 ? bytes(value, 2) + [0, 0] : bytes(value, 4)
            }
            previousNext = file.count
            file += bytes(0, 4)
        }
        return Data(file)
    }

    func testThePagesAreTakenOut() throws {
        let first = jpeg(width: 40, height: 60)
        let second = jpeg(width: 30, height: 20)
        for little in [true, false] {
            let pages = try XCTUnwrap(OldJPEGTiff.pages(of: tiff([(first, 40, 60), (second, 30, 20)],
                                                                 littleEndian: little)))
            XCTAssertEqual(pages.map(\.jpeg), [first, second])
            XCTAssertEqual(pages.map(\.width), [40, 30])
            XCTAssertEqual(pages.map(\.height), [60, 20])
        }
    }

    func testAnyOtherTIFFIsLeftToImageIO() {
        XCTAssertNil(OldJPEGTiff.pages(of: tiff([(jpeg(width: 4, height: 4), 4, 4)], compression: 7)))
        XCTAssertNil(OldJPEGTiff.pages(of: Data("not a tiff at all".utf8)))
        XCTAssertNil(OldJPEGTiff.pages(of: Data([0x49, 0x49, 42, 0, 0xFF, 0xFF, 0xFF, 0x7F, 0])),
                     "a directory past the end")
    }

    func testThePageShowsEveryPage() throws {
        let pages = try XCTUnwrap(OldJPEGTiff.pages(of: tiff([(jpeg(width: 8, height: 8), 8, 8),
                                                              (jpeg(width: 8, height: 8), 8, 8)])))
        let html = OldJPEGTiff.html(for: pages, name: "scan.tif", path: "/x")
        XCTAssertEqual(html.components(separatedBy: "data:image/jpeg;base64,").count, 3)
        XCTAssertTrue(html.contains("Page 2 of 2"))
    }
}
