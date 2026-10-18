import Foundation

/// Little-endian cursor over a byte buffer. Shared by the ZIP and Android
/// binary-XML parsers.
struct ByteReader {
    let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    init(_ data: Data, offset: Int = 0) {
        self.bytes = [UInt8](data)
        self.offset = offset
    }

    var count: Int { bytes.count }
    var remaining: Int { max(0, bytes.count - offset) }

    func canRead(_ n: Int) -> Bool { offset + n <= bytes.count }

    mutating func u8() -> UInt8? {
        guard canRead(1) else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() -> UInt16? {
        guard canRead(2) else { return nil }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    mutating func u32() -> UInt32? {
        guard canRead(4) else { return nil }
        defer { offset += 4 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    mutating func skip(_ n: Int) { offset = min(bytes.count, offset + n) }

    mutating func seek(_ index: Int) { offset = max(0, min(bytes.count, index)) }

    func u16(at index: Int) -> UInt16? {
        guard index + 2 <= bytes.count else { return nil }
        return UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
    }

    func u32(at index: Int) -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        return UInt32(bytes[index])
            | (UInt32(bytes[index + 1]) << 8)
            | (UInt32(bytes[index + 2]) << 16)
            | (UInt32(bytes[index + 3]) << 24)
    }

    func slice(_ start: Int, _ length: Int) -> ArraySlice<UInt8>? {
        guard start >= 0, length >= 0, start + length <= bytes.count else { return nil }
        return bytes[start..<(start + length)]
    }
}
