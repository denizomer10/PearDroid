import Foundation
import Compression

/// Error thrown by the minimal ZIP reader.
enum ZipError: Error, CustomStringConvertible {
    case notAZip
    case corrupt
    case unsupportedCompression(UInt16)

    var description: String {
        switch self {
        case .notAZip: return "not a ZIP archive"
        case .corrupt: return "corrupt ZIP structure"
        case .unsupportedCompression(let method): return "unsupported ZIP compression method \(method)"
        }
    }
}

/// One entry in the ZIP central directory.
struct ZipEntry {
    let name: String
    let compressionMethod: UInt16
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
}

/// A deliberately small, read-only ZIP reader. It is enough to pull individual
/// entries (such as an APK's `AndroidManifest.xml`) out of an archive without
/// shelling out or pulling in third-party dependencies.
///
/// Deflated entries are expanded with Apple's Compression framework, whose
/// `COMPRESSION_ZLIB` algorithm is the raw DEFLATE stream that ZIP uses.
struct ZipReader {
    private let bytes: [UInt8]

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        bytes = [UInt8](data)
        guard Self.endOfCentralDirectory(bytes) != nil else { throw ZipError.notAZip }
    }

    private static func endOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let signature: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        let lowerBound = max(0, bytes.count - 22 - 65535)
        var index = bytes.count - 22
        while index >= lowerBound {
            if bytes[index] == signature[0], bytes[index + 1] == signature[1],
               bytes[index + 2] == signature[2], bytes[index + 3] == signature[3] {
                return index
            }
            index -= 1
        }
        return nil
    }

    private static func le16(_ bytes: [UInt8], _ index: Int) -> UInt16 {
        UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
    }

    private static func le32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        UInt32(bytes[index])
            | (UInt32(bytes[index + 1]) << 8)
            | (UInt32(bytes[index + 2]) << 16)
            | (UInt32(bytes[index + 3]) << 24)
    }

    func entries() throws -> [ZipEntry] {
        guard let eocd = Self.endOfCentralDirectory(bytes) else { throw ZipError.notAZip }
        let count = Int(Self.le16(bytes, eocd + 10))
        let centralOffset = Int(Self.le32(bytes, eocd + 16))

        var index = centralOffset
        var result: [ZipEntry] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            guard index + 46 <= bytes.count, Self.le32(bytes, index) == 0x0201_4b50 else {
                throw ZipError.corrupt
            }
            let method = Self.le16(bytes, index + 10)
            let compressedSize = Int(Self.le32(bytes, index + 20))
            let uncompressedSize = Int(Self.le32(bytes, index + 24))
            let nameLength = Int(Self.le16(bytes, index + 28))
            let extraLength = Int(Self.le16(bytes, index + 30))
            let commentLength = Int(Self.le16(bytes, index + 32))
            let localOffset = Int(Self.le32(bytes, index + 42))

            guard index + 46 + nameLength <= bytes.count else { throw ZipError.corrupt }
            let nameBytes = bytes[(index + 46)..<(index + 46 + nameLength)]
            let name = String(decoding: nameBytes, as: UTF8.self)

            result.append(ZipEntry(name: name,
                                   compressionMethod: method,
                                   compressedSize: compressedSize,
                                   uncompressedSize: uncompressedSize,
                                   localHeaderOffset: localOffset))
            index += 46 + nameLength + extraLength + commentLength
        }
        return result
    }

    func data(for entry: ZipEntry) throws -> Data {
        let localOffset = entry.localHeaderOffset
        guard localOffset + 30 <= bytes.count, Self.le32(bytes, localOffset) == 0x0403_4b50 else {
            throw ZipError.corrupt
        }
        let nameLength = Int(Self.le16(bytes, localOffset + 26))
        let extraLength = Int(Self.le16(bytes, localOffset + 28))
        let start = localOffset + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= bytes.count else { throw ZipError.corrupt }

        let compressed = Array(bytes[start..<(start + entry.compressedSize)])
        switch entry.compressionMethod {
        case 0:
            return Data(compressed)
        case 8:
            return try Self.inflate(compressed, expectedSize: entry.uncompressedSize)
        default:
            throw ZipError.unsupportedCompression(entry.compressionMethod)
        }
    }

    private static func inflate(_ source: [UInt8], expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        guard !source.isEmpty else { throw ZipError.corrupt }
        var destination = [UInt8](repeating: 0, count: expectedSize)
        let written = source.withUnsafeBufferPointer { sourceBuffer in
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                compression_decode_buffer(destinationBuffer.baseAddress!, expectedSize,
                                          sourceBuffer.baseAddress!, source.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw ZipError.corrupt }
        return Data(destination)
    }
}
