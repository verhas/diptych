import AppKit
import CryptoKit
import Foundation

/// A disk image, read without attaching it: its format and sizes, whether
/// it is encrypted, its code signature and stapled ticket, its partitions,
/// and -- where the file system can be read here -- the volume's name and
/// what is at its top.
nonisolated struct DiskImage {

    enum Problem: Error, CustomStringConvertible {
        case damaged(String)
        var description: String { switch self { case .damaged(let why): why } }
    }

    struct Item {
        var name: String
        var isFolder: Bool
        var isLink: Bool
        var size: UInt64?
        var hidden: Bool { name.hasPrefix(".") }
    }

    struct Volume {
        var fileSystem: String
        var name: String?
        var files: Int?
        var folders: Int?
        var encrypted = false
        var caseSensitive: Bool?
        var items: [Item] = []
        /// Why the top of the volume is not listed, when it is not.
        var unlisted: String?
    }

    struct Partition {
        var name: String
        var type: String
        var offset: Int64
        var size: Int64
        var volume: Volume?
    }

    static let extensions: Set<String> = ["dmg", "sparseimage", "sparsebundle", "asif", "iso", "cdr", "toast", "img", "smi"]

    let url: URL
    var format = ""
    var formatName = ""
    var fullSize: Int64?
    var storedSize: Int64 = 0
    var encryption: String?
    var checksum: String?
    var partitionScheme: String?
    var partitions: [Partition] = []
    var signature: MachOFile.CodeSignature?
    var stapled = false
    /// nil when not checked, otherwise the first difference, or "" for none.
    var signatureMismatch: String?
    var licenseText: String?
    var hasLicense = false
    var segments = 1
    var notes: [String] = []

    /// The largest image whose signed bytes are hashed.
    static let verifiedSize = 8 * 1024 * 1024 * 1024

    // MARK: - Reading

    static func looksLikeImage(_ data: Data) -> Bool {
        if data.count >= 512, data.suffix(512).prefix(4) == Data("koly".utf8) { return true }
        let head = data.prefix(8)
        return head == Data("encrcdsa".utf8) || head.prefix(4) == Data("sprs".utf8) || head.prefix(4) == Data("shdw".utf8)
    }

    /// `data` is the whole file, mapped; `verify` hashes what the signature
    /// covers, `listing` reads the partitions and volumes.
    init(url: URL, data: Data, verify: Bool, listing: Bool = true) throws {
        self.url = url
        storedSize = Int64(data.count)
        let reader = BinaryReader(data, bigEndian: true)

        if data.prefix(8) == Data("encrcdsa".utf8) {
            format = ""
            let bits = (try? reader.u32(24)) ?? 0
            encryption = bits == 128 || bits == 256 ? "AES-\(bits)" : "yes"
            formatName = "Encrypted disk image"
            notes.append("Encrypted: what is in it cannot be read without its password, and none is asked for here.")
            return
        }
        if data.count > 512, data.suffix(8) == Data("cdsaencr".utf8) {
            format = ""
            encryption = "yes (old form)"
            formatName = "Encrypted disk image"
            notes.append("Encrypted: what is in it cannot be read without its password, and none is asked for here.")
            return
        }
        if data.prefix(4) == Data("sprs".utf8) {
            format = "UDSP"
            formatName = "Sparse disk image"
            if let sectors = try? reader.u32(16) { fullSize = Int64(sectors) * 512 }
            if listing, let disk = SparseDisk(data: data) { readDisk(disk) }
            return
        }
        if data.prefix(4) == Data("shdw".utf8) {
            format = "ASIF"
            formatName = "Apple sparse image (ASIF)"
            if let sectors = try? reader.u64(48), sectors > 0, sectors < 1 << 50 { fullSize = Int64(sectors) * 512 }
            return
        }
        if data.count >= 512, data.suffix(512).prefix(4) == Data("koly".utf8) {
            try readUDIF(data, verify: verify, listing: listing)
            return
        }
        // No trailer: a raw image, the bytes of a disk as they are.
        format = url.pathExtension.lowercased() == "iso" ? "ISO" : "UDRW"
        formatName = format == "ISO" ? "Disc image" : "Raw disk image"
        fullSize = Int64(data.count)
        guard listing else { return }
        readDisk(RawDisk(data: data))
        if partitions.isEmpty {
            throw Problem.damaged("It is not a disk image read here: no trailer of a current one, no partition map "
                                  + "and no file system recognised. Old images (NDIF, before Mac OS X 10.2) are not read.")
        }
    }

    /// An old sparse bundle: a folder of bands.
    init(bundle url: URL, listing: Bool = true) throws {
        self.url = url
        guard let info = (try? Data(contentsOf: url.appendingPathComponent("Info.plist")))
                .flatMap({ try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }),
              let size = (info["size"] as? NSNumber)?.int64Value,
              let band = (info["band-size"] as? NSNumber)?.int64Value, band > 0 else {
            throw Problem.damaged("Its Info.plist cannot be read.")
        }
        format = "UDSB"
        formatName = "Sparse bundle disk image"
        fullSize = size
        if listing { storedSize = AppBundle.size(of: url).bytes }
        // An encrypted bundle keeps its encryption header in "token"; an
        // unencrypted one has it empty.
        if let token = try? Data(contentsOf: url.appendingPathComponent("token")), !token.isEmpty {
            encryption = "yes"
            notes.append("Encrypted: what is in it cannot be read without its password, and none is asked for here.")
            return
        }
        if listing { readDisk(BandDisk(folder: url.appendingPathComponent("bands"), bandSize: band, size: size)) }
    }

    private mutating func readUDIF(_ data: Data, verify: Bool, listing: Bool) throws {
        let reader = BinaryReader(data, bigEndian: true)
        let koly = data.count - 512
        let flags = try reader.u32(koly + 12)
        let dataForkOffset = try reader.u64(koly + 24), dataForkLength = try reader.u64(koly + 32)
        segments = Int(try reader.u32(koly + 60))
        let checksumType = try reader.u32(koly + 80)
        checksum = [0: nil, 2: "CRC32", 4: "MD5"][checksumType] ?? "type \(checksumType)"
        let xmlOffset = Int(clamping: try reader.u64(koly + 216)), xmlLength = Int(clamping: try reader.u64(koly + 224))
        let signatureOffset = Int(clamping: try reader.u64(koly + 296))
        let signatureLength = Int(clamping: try reader.u64(koly + 304))
        let sectors = try reader.u64(koly + 492)
        guard sectors < 1 << 50 else { throw Problem.damaged("Its trailer gives an impossible size.") }
        fullSize = Int64(sectors) * 512
        storedSize = Int64(clamping: dataForkLength)
        if flags & 1 == 0 { notes.append("Not flattened: part of it may be in a resource fork that is not read here.") }
        if segments > 1 { notes.append("One segment of \(segments): the others are separate files.") }

        if signatureLength > 0, reader.contains(signatureOffset, signatureLength) {
            let blob = try reader.bytes(signatureOffset, signatureLength)
            let blobs = BinaryReader(blob, bigEndian: true)
            signature = try? MachOFile.CodeSignature.read(blobs, code: Data(), verify: false)
            stapled = Self.blobTypes(blobs).contains(0x1_0002)
            if verify, signature != nil {
                signatureMismatch = Self.mismatch(data: data, signature: blobs, koly: koly)
            }
        }

        // The resource fork, as XML: the partitions and their chunk tables.
        var chunks: [UDIFDisk.Chunk] = []
        if xmlLength > 0, reader.contains(xmlOffset, xmlLength),
           let plist = try? PropertyListSerialization.propertyList(from: reader.bytes(xmlOffset, xmlLength), format: nil)
            as? [String: Any],
           let fork = plist["resource-fork"] as? [String: Any] {
            let blocks = fork["blkx"] as? [[String: Any]] ?? []
            var types: [UInt32: UInt64] = [:]
            for block in blocks {
                guard let table = block["Data"] as? Data else { continue }
                let mish = BinaryReader(table, bigEndian: true)
                guard (try? mish.u32(0)) == 0x6D69_7368,
                      let first = try? mish.u64(8), let dataOffset = try? mish.u64(24),
                      let count = try? mish.u32(200) else { continue }
                for index in 0..<Int(min(count, 1_000_000)) {
                    let at = 204 + index * 40
                    guard let type = try? mish.u32(at), let sector = try? mish.u64(at + 8),
                          let length = try? mish.u64(at + 16), let offset = try? mish.u64(at + 24),
                          let stored = try? mish.u64(at + 32) else { break }
                    if type == 0xFFFF_FFFF { break }
                    if type == 0x7FFF_FFFE { continue }
                    // A chunk outside the disk or the file is damage: left out.
                    let (start, over1) = first.addingReportingOverflow(sector)
                    let (stop, over2) = start.addingReportingOverflow(length)
                    let (at1, over3) = dataForkOffset.addingReportingOverflow(dataOffset)
                    let (place, over4) = at1.addingReportingOverflow(offset)
                    let (atEnd, over5) = place.addingReportingOverflow(stored)
                    guard !(over1 || over2 || over3 || over4 || over5), stop <= sectors,
                          type & 0x8000_0000 == 0 && type != 1 || atEnd <= UInt64(data.count) else { continue }
                    types[type, default: 0] += length
                    chunks.append(.init(sector: start, sectors: length, type: type, offset: place, length: stored))
                }
            }
            (format, formatName) = Self.format(types)
            if format == "UDBZ" || format == "UDCO" {
                notes.append("What is on it is not read here: its compression (\(format == "UDBZ" ? "bzip2" : "ADC")) is not one this reads.")
            }
            hasLicense = fork["LPic"] != nil
            if hasLicense { licenseText = Self.license(fork) }
        } else {
            format = "UDIF"
            formatName = "Disk image"
            notes.append("Its table of partitions cannot be read.")
        }
        chunks.sort { $0.sector < $1.sector }
        if listing, !chunks.isEmpty { readDisk(UDIFDisk(data: data, chunks: chunks, size: Int64(sectors) * 512)) }
    }

    private static func format(_ types: [UInt32: UInt64]) -> (String, String) {
        let compressed = types.filter { $0.key & 0x8000_0000 != 0 }
        guard let main = compressed.max(by: { $0.value < $1.value })?.key else {
            return ("UDRO", "Read-only disk image, not compressed")
        }
        return switch main {
        case 0x8000_0004: ("UDCO", "Read-only disk image, ADC-compressed")
        case 0x8000_0005: ("UDZO", "Read-only disk image, zlib-compressed")
        case 0x8000_0006: ("UDBZ", "Read-only disk image, bzip2-compressed")
        case 0x8000_0007: ("ULFO", "Read-only disk image, LZFSE-compressed")
        case 0x8000_0008: ("ULMO", "Read-only disk image, LZMA-compressed")
        default: ("UDIF", "Read-only disk image, compressed")
        }
    }

    /// The license agreement shown before the image opens: the first plain
    /// text (MacRoman) or styled text (RTF) one in the resource fork.
    private static func license(_ fork: [String: Any]) -> String? {
        func first(_ key: String) -> Data? {
            (fork[key] as? [[String: Any]])?.compactMap { $0["Data"] as? Data }.first
        }
        if let rtf = first("RTF "),
           let text = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                              documentAttributes: nil).string {
            return text
        }
        if let text = first("TEXT") { return String(data: text, encoding: .macOSRoman) }
        return nil
    }

    static func blobTypes(_ reader: BinaryReader) -> [UInt32] {
        guard let count = try? reader.u32(8) else { return [] }
        return (0..<Int(min(count, 64))).compactMap { try? reader.u32(12 + $0 * 8) }
    }

    /// The signature of a disk image covers the bytes before it, in one
    /// hash, and the trailer with the signature's length left out (slot 6).
    private static func mismatch(data: Data, signature: BinaryReader, koly: Int) -> String? {
        guard let count = try? signature.u32(8) else { return nil }
        var best: (at: Int, rank: Int)?
        for index in 0..<Int(min(count, 64)) {
            guard let type = try? signature.u32(12 + index * 8), type == 0 || (type >= 0x1000 && type < 0x1005),
                  let at = try? Int(signature.u32(16 + index * 8)),
                  let hash = try? signature.u8(at + 37) else { continue }
            let rank = [1: 0, 3: 1, 2: 2, 4: 3][Int(hash)] ?? -1
            if best == nil || rank > best!.rank { best = (at, rank) }
        }
        guard let at = best?.at,
              let hashOffset = try? Int(signature.u32(at + 16)), let codeLimit = try? Int(signature.u32(at + 32)),
              let size = try? Int(signature.u8(at + 36)), let type = try? signature.u8(at + 37),
              let hash = MachOFile.CodeSignature.Directory.Hash(rawValue: type),
              let specials = try? Int(signature.u32(at + 24)) else { return nil }
        guard codeLimit <= data.count else { return "The signature covers more than the file holds." }
        guard codeLimit <= verifiedSize else { return nil }
        if let expected = try? signature.bytes(at + hashOffset, size),
           Array(hash.digest(data.prefix(codeLimit)).prefix(size)) != Array(expected) {
            return "Its contents changed after signing."
        }
        if specials >= 6, let expected = try? signature.bytes(at + hashOffset - 6 * size, size),
           expected.contains(where: { $0 != 0 }) {
            var trailer = Data(data.suffix(512))
            trailer.replaceSubrange(304..<312, with: Data(count: 8))
            if Array(hash.digest(trailer).prefix(size)) != Array(expected) {
                return "Its trailer changed after signing."
            }
        }
        return ""
    }

    // MARK: - Partitions and volumes

    private mutating func readDisk(_ disk: Disk) {
        guard let first = disk.read(0, 4096) else { return }
        let sector = 512
        if first.count >= 1024, first[first.startIndex + 512..<first.startIndex + 520] == Data("EFI PART".utf8) {
            partitionScheme = "GUID partition map"
            let header = BinaryReader(first[first.startIndex + 512..<first.startIndex + 1024])
            guard let entries = try? header.u64(72), let count = try? header.u32(80),
                  let size = try? header.u32(84), size >= 128, size <= 1024, count <= 1024, entries < 1 << 40,
                  let table = disk.read(Int64(entries) * Int64(sector), Int(count) * Int(size)) else { return }
            let reader = BinaryReader(table)
            for index in 0..<Int(count) {
                let at = index * Int(size)
                guard let type = try? reader.bytes(at, 16), type.contains(where: { $0 != 0 }),
                      let start = try? reader.u64(at + 32), let end = try? reader.u64(at + 40),
                      end >= start, end < 1 << 50,
                      let nameBytes = try? reader.bytes(at + 56, 72) else { continue }
                let name = String(data: nameBytes, encoding: .utf16LittleEndian)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
                let offset = Int64(start) * Int64(sector), length = Int64(end - start + 1) * Int64(sector)
                partitions.append(Partition(name: name, type: Self.gptType(Array(type)), offset: offset, size: length,
                                            volume: Self.volume(disk, at: offset, size: length)))
            }
        } else if first.count >= 1024, first[first.startIndex + 512..<first.startIndex + 514] == Data("PM".utf8) {
            partitionScheme = "Apple partition map"
            guard let map = disk.read(512, 512 * 64) else { return }
            let reader = BinaryReader(map, bigEndian: true)
            let count = min(Int((try? reader.u32(4)) ?? 0), 63)
            for index in 0..<count {
                let at = index * 512
                guard (try? reader.bytes(at, 2)) == Data("PM".utf8),
                      let start = try? reader.u32(at + 8), let blocks = try? reader.u32(at + 12) else { continue }
                let name = reader.string(at + 16, limit: 32), type = reader.string(at + 48, limit: 32)
                guard type != "Apple_partition_map", type != "Apple_Free" else { continue }
                let offset = Int64(start) * 512, length = Int64(blocks) * 512
                partitions.append(Partition(name: name, type: type, offset: offset, size: length,
                                            volume: Self.volume(disk, at: offset, size: length)))
            }
        } else if let volume = Self.volume(disk, at: 0, size: disk.size) {
            partitions.append(Partition(name: "", type: "", offset: 0, size: disk.size, volume: volume))
        } else if first.count >= 512, first[first.startIndex + 510] == 0x55, first[first.startIndex + 511] == 0xAA {
            partitionScheme = "Master boot record"
            let reader = BinaryReader(first)
            for index in 0..<4 {
                let at = 446 + index * 16
                guard let type = try? reader.u8(at + 4), type != 0,
                      let start = try? reader.u32(at + 8), let sectors = try? reader.u32(at + 12) else { continue }
                let offset = Int64(start) * 512, length = Int64(sectors) * 512
                partitions.append(Partition(name: "", type: String(format: "type %02X", type), offset: offset,
                                            size: length, volume: Self.volume(disk, at: offset, size: length)))
            }
        }
    }

    private static func gptType(_ bytes: [UInt8]) -> String {
        // Mixed-endian GUID, as written in the table.
        let a = bytes[0..<4].reversed(), b = bytes[4..<6].reversed(), c = bytes[6..<8].reversed()
        let hex = { (part: [UInt8]) in part.map { String(format: "%02X", $0) }.joined() }
        let guid = "\(hex(Array(a)))-\(hex(Array(b)))-\(hex(Array(c)))-\(hex(Array(bytes[8..<10])))-\(hex(Array(bytes[10..<16])))"
        return [
            "48465300-0000-11AA-AA11-00306543ECAC": "Apple_HFS",
            "7C3457EF-0000-11AA-AA11-00306543ECAC": "Apple_APFS",
            "55465300-0000-11AA-AA11-00306543ECAC": "Apple_UFS",
            "426F6F74-0000-11AA-AA11-00306543ECAC": "Apple_Boot",
            "C12A7328-F81F-11D2-BA4B-00A0C93EC93B": "EFI",
            "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7": "Microsoft basic data",
            "0FC63DAF-8483-4772-8E79-3D69D8477DE4": "Linux file system",
        ][guid] ?? guid
    }

    /// The file system at `offset`, if it is one recognised here.
    static func volume(_ disk: Disk, at offset: Int64, size: Int64) -> Volume? {
        guard let head = disk.read(offset, 4096), head.count >= 2048 else { return nil }
        let reader = BinaryReader(head)
        if (try? reader.bytes(32, 4)) == Data("NXSB".utf8) { return APFS.volume(disk, at: offset) }
        if let signature = try? reader.bytes(1024, 2), signature == Data("H+".utf8) || signature == Data("HX".utf8) {
            return HFSPlus.volume(disk, at: offset, caseSensitive: signature == Data("HX".utf8))
        }
        if (try? reader.bytes(3, 8)) == Data("EXFAT   ".utf8) { return Volume(fileSystem: "exFAT") }
        if (try? reader.bytes(3, 8)) == Data("NTFS    ".utf8) { return Volume(fileSystem: "NTFS") }
        if head[head.startIndex + 510] == 0x55, head[head.startIndex + 511] == 0xAA {
            func label(_ at: Int) -> String? {
                let text = String(decoding: (try? reader.bytes(at, 11)) ?? Data(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                return text.isEmpty || text == "NO NAME" ? nil : text
            }
            if (try? reader.bytes(82, 5)) == Data("FAT32".utf8) { return Volume(fileSystem: "FAT32", name: label(71)) }
            if (try? reader.bytes(54, 3)) == Data("FAT".utf8) { return Volume(fileSystem: "FAT", name: label(43)) }
        }
        if let descriptor = disk.read(offset + 32768, 2048), descriptor.count == 2048,
           descriptor[descriptor.startIndex + 1..<descriptor.startIndex + 6] == Data("CD001".utf8) {
            let name = String(decoding: descriptor[descriptor.startIndex + 40..<descriptor.startIndex + 72], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\0")))
            return Volume(fileSystem: "ISO 9660", name: name.isEmpty ? nil : name,
                          unlisted: "Listing a disc's files is not done here.")
        }
        return nil
    }
}

// MARK: - Reading the disk inside

/// The bytes of the disk the image holds, by offset.
nonisolated protocol Disk {
    var size: Int64 { get }
    func read(_ offset: Int64, _ length: Int) -> Data?
}

nonisolated struct RawDisk: Disk {
    let data: Data
    var size: Int64 { Int64(data.count) }
    func read(_ offset: Int64, _ length: Int) -> Data? {
        guard offset >= 0, offset < Int64(data.count) else { return nil }
        let start = data.startIndex + Int(offset)
        return Data(data[start..<min(data.endIndex, start + length)])
    }
}

/// A sparse image: a header with a table of bands, then the bands in the
/// order they were first written. A band never written reads as zeros.
nonisolated struct SparseDisk: Disk {
    let data: Data
    let bandSize: Int64
    let size: Int64
    /// Logical band to where it is stored.
    let slots: [Int64: Int64]

    static let header: Int64 = 4096

    init?(data: Data) {
        let reader = BinaryReader(data, bigEndian: true)
        guard let sectorsPerBand = try? reader.u32(8), sectorsPerBand > 0, let sectors = try? reader.u32(16) else { return nil }
        self.data = data
        bandSize = Int64(sectorsPerBand) * 512
        size = Int64(sectors) * 512
        let bands = Int((size + bandSize - 1) / bandSize)
        var slots: [Int64: Int64] = [:]
        for slot in 0..<min(bands, (Int(Self.header) - 64) / 4) {
            guard let band = try? reader.u32(64 + slot * 4), band > 0 else { continue }
            slots[Int64(band) - 1] = Self.header + Int64(slot) * bandSize
        }
        self.slots = slots
    }

    func read(_ offset: Int64, _ length: Int) -> Data? {
        guard offset >= 0, offset < size, length <= 64 * 1024 * 1024 else { return nil }
        var out = Data(), position = offset
        let end = min(size, offset + Int64(length))
        while position < end {
            let band = position / bandSize, inside = position % bandSize
            let take = Int(min(bandSize - inside, end - position))
            if let stored = slots[band], stored + inside + Int64(take) <= Int64(data.count) {
                let start = data.startIndex + Int(stored + inside)
                out += data[start..<start + take]
            } else {
                out += Data(count: take)
            }
            position += Int64(take)
        }
        return out
    }
}

/// A sparse bundle: bands of a fixed size, a missing band all zeros.
nonisolated struct BandDisk: Disk {
    let folder: URL
    let bandSize: Int64
    let size: Int64
    func read(_ offset: Int64, _ length: Int) -> Data? {
        guard offset >= 0, offset < size, length <= 64 * 1024 * 1024 else { return nil }
        var out = Data(), position = offset
        let end = min(size, offset + Int64(length))
        while position < end {
            let band = position / bandSize, inside = position % bandSize
            let take = Int(min(bandSize - inside, end - position))
            var piece = Data(count: take)
            if let handle = try? FileHandle(forReadingFrom: folder.appendingPathComponent(String(band, radix: 16))) {
                try? handle.seek(toOffset: UInt64(inside))
                if let read = try? handle.read(upToCount: take) { piece.replaceSubrange(0..<read.count, with: read) }
                try? handle.close()
            }
            out += piece
            position += Int64(take)
        }
        return out
    }
}

/// A UDIF image's disk: chunks, each stored raw, as zeros, or compressed.
nonisolated final class UDIFDisk: Disk {
    struct Chunk {
        var sector: UInt64
        var sectors: UInt64
        var type: UInt32
        var offset: UInt64
        var length: UInt64
    }

    let data: Data
    let chunks: [Chunk]
    let size: Int64
    private var cache: [Int: Data] = [:]
    private var order: [Int] = []
    /// The most decompressed bytes read for one listing.
    private var budget = 256 * 1024 * 1024

    init(data: Data, chunks: [Chunk], size: Int64) {
        self.data = data
        self.chunks = chunks
        self.size = size
    }

    func read(_ offset: Int64, _ length: Int) -> Data? {
        guard offset >= 0, offset < size, length > 0 else { return nil }
        var out = Data(), position = offset
        let end = min(size, offset + Int64(length))
        while position < end {
            let sector = UInt64(position / 512)
            // The last chunk starting at or before the sector.
            var low = 0, high = chunks.count - 1, found = -1
            while low <= high {
                let middle = (low + high) / 2
                if chunks[middle].sector <= sector { found = middle; low = middle + 1 } else { high = middle - 1 }
            }
            guard found >= 0, sector < chunks[found].sector + chunks[found].sectors else { return out.isEmpty ? nil : out }
            let chunk = chunks[found]
            let inside = Int(position - Int64(chunk.sector) * 512) // chunks are checked to lie inside the disk
            let available = Int(chunk.sectors) * 512 - inside
            let take = min(available, Int(end - position))
            guard take > 0 else { return out.isEmpty ? nil : out }
            switch chunk.type {
            case 0, 2:
                // Zeros: nothing stored.
                out += Data(count: take)
            case 1:
                // Stored as it is: read in place, however large the chunk.
                let start = Int(chunk.offset) + inside
                guard start >= 0, start + take <= data.count else { return out.isEmpty ? nil : out }
                out += data[data.startIndex + start..<data.startIndex + start + take]
            default:
                guard let bytes = decoded(found), inside + take <= bytes.count else { return out.isEmpty ? nil : out }
                out += bytes[bytes.startIndex + inside..<bytes.startIndex + inside + take]
            }
            position += Int64(take)
        }
        return out
    }

    private func decoded(_ index: Int) -> Data? {
        if let hit = cache[index] { return hit }
        let chunk = chunks[index]
        let expanded = Int(chunk.sectors) * 512
        guard expanded <= 64 * 1024 * 1024, budget > 0 else { return nil }
        let reader = BinaryReader(data)
        let stored = { try? reader.bytes(Int(chunk.offset), Int(chunk.length)) }
        let result: Data?
        switch chunk.type {
        case 0x8000_0005: result = stored().flatMap { Decompress.zlib($0, limit: expanded) }
        case 0x8000_0007: result = stored().flatMap { Decompress.decode($0, .lzfse, limit: expanded) }
        case 0x8000_0008: result = stored().flatMap { Decompress.decode($0, .lzma, limit: expanded) }
        default: result = nil
        }
        guard let result else { return nil }
        budget -= result.count
        cache[index] = result
        order.append(index)
        if order.count > 16 { cache[order.removeFirst()] = nil }
        return result
    }
}

// MARK: - HFS+

nonisolated enum HFSPlus {

    static func volume(_ disk: Disk, at offset: Int64, caseSensitive: Bool) -> DiskImage.Volume? {
        guard let header = disk.read(offset + 1024, 512) else { return nil }
        let reader = BinaryReader(header, bigEndian: true)
        var volume = DiskImage.Volume(fileSystem: caseSensitive ? "Mac OS Extended, case-sensitive (HFSX)"
                                      : "Mac OS Extended (HFS+)")
        volume.caseSensitive = caseSensitive
        volume.files = (try? reader.u32(32)).map(Int.init)
        volume.folders = (try? reader.u32(36)).map { Int($0) - 1 }
        guard let blockSize = try? Int64(reader.u32(40)), blockSize >= 512, blockSize <= 1 << 20 else { return volume }
        var extents: [(start: Int64, count: Int64)] = []
        for index in 0..<8 {
            guard let start = try? reader.u32(272 + 16 + index * 8), let count = try? reader.u32(272 + 20 + index * 8),
                  count > 0 else { break }
            extents.append((Int64(start), Int64(count)))
        }
        /// A byte of the catalog file, as a byte of the disk.
        func diskOffset(_ position: Int64) -> Int64? {
            var skipped: Int64 = 0
            for extent in extents {
                let length = extent.count * blockSize
                if position < skipped + length { return offset + extent.start * blockSize + position - skipped }
                skipped += length
            }
            return nil
        }
        func node(_ number: UInt32, size: Int) -> Data? {
            guard let at = diskOffset(Int64(number) * Int64(size)) else { return nil }
            return disk.read(at, size)
        }
        guard let head = node(0, size: 512), let nodeSize = try? Int(BinaryReader(head, bigEndian: true).u16(32)),
              nodeSize >= 512, let headerNode = node(0, size: nodeSize),
              let firstLeaf = try? BinaryReader(headerNode, bigEndian: true).u32(24) else { return volume }

        var current = firstLeaf, visited = 0
        var done = false
        while current != 0, visited < 4096, !done, let data = node(current, size: nodeSize) {
            visited += 1
            let page = BinaryReader(data, bigEndian: true)
            let count = Int((try? page.u16(10)) ?? 0)
            for index in 0..<count {
                guard let start = try? Int(page.u16(nodeSize - 2 * (index + 1))),
                      let keyLength = try? Int(page.u16(start)), let parent = try? page.u32(start + 2),
                      let nameLength = try? Int(page.u16(start + 6)),
                      let nameBytes = try? page.bytes(start + 8, nameLength * 2) else { continue }
                let name = String(data: nameBytes, encoding: .utf16BigEndian) ?? ""
                let record = start + 2 + keyLength
                if parent == 1, volume.name == nil { volume.name = name }
                if parent > 2 { done = true; break }
                guard parent == 2, let type = try? page.u16(record) else { continue }
                if name.hasPrefix("\u{0}") || name.hasPrefix(".HFS+ Private") || name == ".journal"
                    || name == ".journal_info_block" { continue }
                if type == 1 {
                    volume.items.append(.init(name: name, isFolder: true, isLink: false, size: nil))
                } else if type == 2 {
                    let creator = try? page.bytes(record + 48, 8)
                    let link = creator == Data("slnkrhap".utf8)
                    volume.items.append(.init(name: name, isFolder: false, isLink: link,
                                              size: link ? nil : try? page.u64(record + 88)))
                }
                if volume.items.count >= 1000 { done = true; break }
            }
            current = (try? page.u32(0)) ?? 0
        }
        return volume
    }
}

// MARK: - APFS

nonisolated enum APFS {

    static func volume(_ disk: Disk, at offset: Int64) -> DiskImage.Volume? {
        var volume = DiskImage.Volume(fileSystem: "APFS")
        volume.unlisted = "What is on it cannot be read here: it may be damaged."
        guard let first = disk.read(offset, 4096) else { return volume }
        let container = BinaryReader(first)
        guard let blockSize = try? Int(container.u32(36)), blockSize >= 4096, blockSize <= 65536,
              let omapAddress = try? container.u64(160), let fsID = try? container.u64(184), fsID != 0 else {
            return volume
        }
        func block(_ address: UInt64) -> Data? {
            guard address < 1 << 40 else { return nil }
            return disk.read(offset + Int64(address) * Int64(blockSize), blockSize)
        }
        guard let omapBlock = block(omapAddress), let treeAddress = try? BinaryReader(omapBlock).u64(48),
              let volumeAddress = lookup(fsID, tree: treeAddress, block: block, blockSize: blockSize),
              let superblock = block(volumeAddress) else { return volume }
        let reader = BinaryReader(superblock)
        guard (try? reader.bytes(32, 4)) == Data("APSB".utf8) else { return volume }
        volume.name = reader.string(704, limit: 256)
        volume.files = (try? reader.u64(184)).map { Int(clamping: $0) }
        volume.folders = (try? reader.u64(192)).map { max(Int(clamping: $0) - 1, 0) }
        let incompatible = (try? reader.u64(56)) ?? 0
        volume.caseSensitive = incompatible & 0x1 == 0
        if volume.caseSensitive == true { volume.fileSystem = "APFS, case-sensitive" }
        let flags = (try? reader.u64(264)) ?? 1
        if flags & 1 == 0 {
            volume.encrypted = true
            volume.fileSystem += ", encrypted"
            volume.unlisted = "Its files are encrypted."
            return volume
        }
        guard let volumeOmap = try? reader.u64(128), let rootTree = try? reader.u64(136),
              let omap = block(volumeOmap), let volumeTree = try? BinaryReader(omap).u64(48),
              let root = lookup(rootTree, tree: volumeTree, block: block, blockSize: blockSize) else { return volume }
        volume.unlisted = nil
        volume.items = listRoot(root, block: block, blockSize: blockSize) {
            lookup($0, tree: volumeTree, block: block, blockSize: blockSize)
        }
        return volume
    }

    /// One B-tree node's records: keys and values as byte ranges.
    private static func records(_ node: Data, blockSize: Int) -> (leaf: Bool, items: [(key: Data, value: Data)])? {
        let reader = BinaryReader(node)
        guard let flags = try? reader.u16(32), let level = try? reader.u16(34), let count = try? Int(reader.u32(36)),
              let tableOffset = try? Int(reader.u16(40)), let tableLength = try? Int(reader.u16(42)),
              count < 10_000 else { return nil }
        let fixed = flags & 4 != 0, root = flags & 1 != 0
        let keys = 56 + tableOffset + tableLength
        let values = blockSize - (root ? 40 : 0)
        var items: [(Data, Data)] = []
        for index in 0..<count {
            let entry = 56 + tableOffset + index * (fixed ? 4 : 8)
            if fixed {
                guard let k = try? Int(reader.u16(entry)), let v = try? Int(reader.u16(entry + 2)),
                      let key = try? reader.bytes(keys + k, 16),
                      let value = try? reader.bytes(values - v, level == 0 ? 16 : 8) else { continue }
                items.append((key, value))
            } else {
                guard let k = try? Int(reader.u16(entry)), let kl = try? Int(reader.u16(entry + 2)),
                      let v = try? Int(reader.u16(entry + 4)), let vl = try? Int(reader.u16(entry + 6)),
                      let key = try? reader.bytes(keys + k, kl) else { continue }
                let value = v == 0xFFFF ? Data() : ((try? reader.bytes(values - v, vl)) ?? Data())
                items.append((key, value))
            }
        }
        return (level == 0, items)
    }

    /// An object map's physical address for a virtual object, the newest version.
    static func lookup(_ oid: UInt64, tree: UInt64, block: (UInt64) -> Data?, blockSize: Int) -> UInt64? {
        var address = tree
        for _ in 0..<16 {
            guard let node = block(address), let (leaf, items) = records(node, blockSize: blockSize) else { return nil }
            let keyed = items.compactMap { item -> (UInt64, Data)? in
                guard let id = try? BinaryReader(item.key).u64(0) else { return nil }
                return (id, item.value)
            }
            if leaf {
                guard let match = keyed.last(where: { $0.0 == oid }) else { return nil }
                return try? BinaryReader(match.1).u64(8)
            }
            guard let child = keyed.last(where: { $0.0 <= oid }) ?? keyed.first,
                  let next = try? BinaryReader(child.1).u64(0) else { return nil }
            address = next
        }
        return nil
    }

    /// What is at the top of the volume: the directory records of the root
    /// folder (object 2), with the sizes their inodes record.
    private static func listRoot(_ root: UInt64, block: (UInt64) -> Data?, blockSize: Int,
                                 resolve: (UInt64) -> UInt64?) -> [DiskImage.Item] {
        var entries: [(id: UInt64, name: String, type: UInt16)] = []
        var sizes: [UInt64: UInt64] = [:]
        var visited = 0
        func walk(_ address: UInt64, depth: Int) -> Bool {
            visited += 1
            guard depth < 12, visited < 4000, let node = block(address),
                  let (leaf, items) = records(node, blockSize: blockSize) else { return false }
            for item in items {
                guard let header = try? BinaryReader(item.key).u64(0) else { continue }
                let id = header & 0x0FFF_FFFF_FFFF_FFFF, type = header >> 60
                if !leaf {
                    // Children whose keys start before or at the root folder,
                    // or hold inodes of what it lists.
                    guard let child = try? BinaryReader(item.value).u64(0), let physical = resolve(child) else { continue }
                    if !walk(physical, depth: depth + 1) { return false }
                    continue
                }
                if id == 2, type == 9, item.key.count >= 12 {
                    let reader = BinaryReader(item.key)
                    let length = Int(((try? reader.u32(8)) ?? 0) & 0x3FF)
                    let name = reader.string(12, limit: length)
                    let value = BinaryReader(item.value)
                    if let file = try? value.u64(0), let flags = try? value.u16(16) {
                        entries.append((file, name, flags & 0xF))
                    }
                } else if type == 3, entries.contains(where: { $0.id == id }) {
                    sizes[id] = dstreamSize(item.value)
                }
                // Past the root folder's records and every inode it names.
                if id > 2, let last = entries.map(\.id).max(), id > last, !entries.isEmpty { return false }
                if entries.count >= 1000 { return false }
            }
            return true
        }
        _ = walk(root, depth: 0)
        return entries.map { entry in
            DiskImage.Item(name: entry.name, isFolder: entry.type == 4, isLink: entry.type == 10,
                           size: entry.type == 8 ? sizes[entry.id] : nil)
        }
    }

    /// A file's size, from its inode's data-stream extended field.
    private static func dstreamSize(_ value: Data) -> UInt64? {
        let reader = BinaryReader(value)
        guard let count = try? Int(reader.u16(92)) else { return nil }
        var data = 96 + count * 4
        for index in 0..<count {
            guard let type = try? reader.u8(96 + index * 4), let size = try? Int(reader.u16(96 + index * 4 + 2)) else { return nil }
            if type == 8 { return try? reader.u64(data) }
            data += (size + 7) / 8 * 8
        }
        return nil
    }
}
