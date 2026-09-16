import Foundation

/// Minimal ZIP writer/reader — "store" method only, no compression — just enough to bundle
/// `snapshot.json` with speaker photos into one exportable/importable file
/// (`BackupService.archive`/`unarchive`). Not a general-purpose ZIP implementation: `read`
/// only understands what `write` itself produces, not arbitrary third-party archives.
enum ZipArchive {
    struct Entry {
        var name: String
        var data: Data
    }

    static func write(_ entries: [Entry]) -> Data {
        var output = Data()
        var central: [(name: Data, crc: UInt32, size: UInt32, offset: UInt32)] = []

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let offset = UInt32(output.count)

            output.append(le32(0x0403_4b50)) // local file header signature
            output.append(le16(20)) // version needed
            output.append(le16(0)) // flags
            output.append(le16(0)) // method: stored
            output.append(le16(0)) // mod time
            output.append(le16(0)) // mod date
            output.append(le32(crc))
            output.append(le32(UInt32(entry.data.count))) // compressed size
            output.append(le32(UInt32(entry.data.count))) // uncompressed size
            output.append(le16(UInt16(nameData.count)))
            output.append(le16(0)) // extra field length
            output.append(nameData)
            output.append(entry.data)

            central.append((nameData, crc, UInt32(entry.data.count), offset))
        }

        let centralStart = UInt32(output.count)
        for record in central {
            output.append(le32(0x0201_4b50)) // central directory header signature
            output.append(le16(20)) // version made by
            output.append(le16(20)) // version needed
            output.append(le16(0)) // flags
            output.append(le16(0)) // method
            output.append(le16(0)) // mod time
            output.append(le16(0)) // mod date
            output.append(le32(record.crc))
            output.append(le32(record.size)) // compressed size
            output.append(le32(record.size)) // uncompressed size
            output.append(le16(UInt16(record.name.count)))
            output.append(le16(0)) // extra length
            output.append(le16(0)) // comment length
            output.append(le16(0)) // disk number start
            output.append(le16(0)) // internal attributes
            output.append(le32(0)) // external attributes
            output.append(le32(record.offset))
            output.append(record.name)
        }
        let centralSize = UInt32(output.count) - centralStart

        output.append(le32(0x0605_4b50)) // end of central directory signature
        output.append(le16(0)) // disk number
        output.append(le16(0)) // disk with central directory
        output.append(le16(UInt16(central.count))) // entries on this disk
        output.append(le16(UInt16(central.count))) // total entries
        output.append(le32(centralSize))
        output.append(le32(centralStart))
        output.append(le16(0)) // comment length

        return output
    }

    /// Walks local file headers sequentially rather than trusting the central directory —
    /// fine since this only ever reads archives `write` itself produced.
    static func read(_ data: Data) -> [Entry] {
        let bytes = [UInt8](data)
        var entries: [Entry] = []
        var offset = 0
        while offset + 30 <= bytes.count, readLE32(bytes, offset) == 0x0403_4b50 {
            let compressedSize = Int(readLE32(bytes, offset + 18))
            let nameLength = Int(readLE16(bytes, offset + 26))
            let extraLength = Int(readLE16(bytes, offset + 28))
            let nameStart = offset + 30
            let dataStart = nameStart + nameLength + extraLength
            guard dataStart + compressedSize <= bytes.count else { break }
            let name = String(decoding: bytes[nameStart..<nameStart + nameLength], as: UTF8.self)
            entries.append(Entry(name: name, data: Data(bytes[dataStart..<dataStart + compressedSize])))
            offset = dataStart + compressedSize
        }
        return entries
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    private static func readLE16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { acc, i in acc | (UInt32(bytes[offset + i]) << (8 * i)) }
    }

    private static let crcTable: [UInt32] = (0...255).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1 != 0) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
