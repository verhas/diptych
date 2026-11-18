import Foundation

/// A bill of materials (`Bom`), the list of what an installer package puts
/// where: a block store holding a B-tree of paths, each with its kind, mode,
/// owner and size. Big-endian throughout.
nonisolated struct Bom {

    struct Item {
        enum Kind { case file, directory, link, device }
        var path: String
        var kind: Kind
        var mode: UInt16
        var user: UInt32
        var group: UInt32
        var size: UInt64
        var link: String?
    }

    struct Bad: Error, CustomStringConvertible {
        var description: String { "Its bill of materials cannot be read." }
    }

    static let maximumItems = 500_000

    let items: [Item]

    static func looksLikeBom(_ data: Data) -> Bool { data.prefix(8) == Data("BOMStore".utf8) }

    init(data: Data) throws {
        guard Self.looksLikeBom(data) else { throw Bad() }
        let reader = BinaryReader(data, bigEndian: true)
        let indexAt = Int(try reader.u32(16)), varsAt = Int(try reader.u32(24))
        let blockCount = Int(try reader.u32(indexAt))
        func block(_ index: UInt32) throws -> (at: Int, length: Int) {
            guard Int(index) < blockCount else { throw Bad() }
            let at = Int(try reader.u32(indexAt + 4 + Int(index) * 8))
            let length = Int(try reader.u32(indexAt + 8 + Int(index) * 8))
            guard reader.contains(at, length) else { throw Bad() }
            return (at, length)
        }
        var variables: [String: UInt32] = [:]
        var at = varsAt + 4
        for _ in 0..<min(Int(try reader.u32(varsAt)), 64) {
            let index = try reader.u32(at), length = Int(try reader.u8(at + 4))
            variables[String(decoding: try reader.bytes(at + 5, length), as: UTF8.self)] = index
            at += 5 + length
        }
        guard let pathsVariable = variables["Paths"] else { throw Bad() }
        let tree = try block(pathsVariable)
        guard try reader.bytes(tree.at, 4) == Data("tree".utf8) else { throw Bad() }

        // Down the leftmost branch to the first leaf, then along the leaves.
        var node = try reader.u32(tree.at + 8)
        var depth = 0
        while depth < 64 {
            let paths = try block(node)
            guard try reader.u16(paths.at) == 0 else { break }
            node = try reader.u32(paths.at + 12)
            depth += 1
        }
        var names: [UInt32: (parent: UInt32, name: String)] = [:]
        var raw: [(id: UInt32, info: (at: Int, length: Int))] = []
        var visited: Set<UInt32> = []
        while node != 0, visited.insert(node).inserted, raw.count < Self.maximumItems {
            let paths = try block(node)
            let count = Int(try reader.u16(paths.at + 2))
            for index in 0..<count {
                let entry = paths.at + 12 + index * 8
                let info1 = try block(try reader.u32(entry)), file = try block(try reader.u32(entry + 4))
                let id = try reader.u32(info1.at)
                let info2 = try block(try reader.u32(info1.at + 4))
                let parent = try reader.u32(file.at)
                names[id] = (parent, reader.string(file.at + 4, limit: file.length - 4))
                raw.append((id, info2))
            }
            node = try reader.u32(paths.at + 4)
        }

        func path(_ id: UInt32) -> String {
            var parts: [String] = [], current = id, steps = 0
            while let (parent, name) = names[current], steps < 256 {
                parts.append(name)
                current = parent
                steps += 1
            }
            return parts.reversed().joined(separator: "/")
        }
        items = raw.compactMap { id, info in
            guard info.length >= 31, let type = try? reader.u8(info.at) else { return nil }
            let kind: Item.Kind = switch type {
            case 2: .directory
            case 3: .link
            case 4: .device
            default: .file
            }
            var item = Item(path: path(id), kind: kind, mode: (try? reader.u16(info.at + 4)) ?? 0,
                            user: (try? reader.u32(info.at + 6)) ?? 0, group: (try? reader.u32(info.at + 10)) ?? 0,
                            size: UInt64((try? reader.u32(info.at + 18)) ?? 0))
            if kind == .link, let length = try? Int(reader.u32(info.at + 27)), length > 0 {
                item.link = reader.string(info.at + 31, limit: min(length, info.length - 31))
            }
            return item
        }
    }
}

/// A cpio archive, as an installer package's scripts come: the old portable
/// ("odc", octal) or the new ("newc", hex) form.
nonisolated enum CPIO {

    struct Member {
        var name: String
        var mode: UInt32
        var data: Data
        var isFile: Bool { mode & 0o170000 == 0o100000 }
        var isExecutable: Bool { mode & 0o111 != 0 }
    }

    static func members(_ data: Data, limit: Int = 2000) -> [Member] {
        var out: [Member] = []
        var at = data.startIndex
        func field(_ start: Int, _ length: Int, radix: Int) -> Int? {
            guard start + length <= data.endIndex else { return nil }
            return Int(String(decoding: data[start..<start + length], as: UTF8.self), radix: radix)
        }
        while out.count < limit, at + 76 <= data.endIndex {
            let magic = String(decoding: data[at..<at + 6], as: UTF8.self)
            let name: String, mode: Int, size: Int, dataAt: Int
            if magic == "070707" {
                guard let m = field(at + 18, 6, radix: 8), let nameSize = field(at + 59, 6, radix: 8),
                      let fileSize = field(at + 65, 11, radix: 8), nameSize > 0,
                      at + 76 + nameSize <= data.endIndex else { break }
                name = String(decoding: data[at + 76..<at + 76 + nameSize - 1], as: UTF8.self)
                mode = m; size = fileSize; dataAt = at + 76 + nameSize
            } else if magic == "070701" || magic == "070702" {
                guard at + 110 <= data.endIndex, let m = field(at + 14, 8, radix: 16),
                      let fileSize = field(at + 54, 8, radix: 16), let nameSize = field(at + 94, 8, radix: 16),
                      nameSize > 0, at + 110 + nameSize <= data.endIndex else { break }
                name = String(decoding: data[at + 110..<at + 110 + nameSize - 1], as: UTF8.self)
                mode = m; size = fileSize
                dataAt = (at + 110 + nameSize - data.startIndex + 3) / 4 * 4 + data.startIndex
            } else {
                break
            }
            if name == "TRAILER!!!" { break }
            guard size >= 0, dataAt + size <= data.endIndex else { break }
            out.append(Member(name: name.hasPrefix("./") ? String(name.dropFirst(2)) : name,
                              mode: UInt32(mode), data: data[dataAt..<dataAt + size]))
            at = dataAt + size
            if magic != "070707" { at = (at - data.startIndex + 3) / 4 * 4 + data.startIndex }
        }
        return out
    }
}
