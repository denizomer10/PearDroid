import Foundation

/// Resolves a string resource id (as referenced from `AndroidManifest.xml`)
/// against an APK's compiled resource table (`resources.arsc`). Only the
/// default configuration is considered — enough to recover a canonical app
/// label such as "Worms 4" from `android:label="@string/app_name"`.
enum AndroidResources {

    private enum Chunk {
        static let table: UInt16 = 0x0002
        static let stringPool: UInt16 = 0x0001
        static let package: UInt16 = 0x0200
        static let type: UInt16 = 0x0201
    }

    private enum ValueType {
        static let string: UInt8 = 0x03
    }

    static func resolveString(in data: Data, resourceId: UInt32) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count > 12, u16(bytes, 0) == Chunk.table else { return nil }
        let tableHeaderSize = Int(u16(bytes, 2))

        var position = tableHeaderSize
        guard position + 8 <= bytes.count, u16(bytes, position) == Chunk.stringPool else { return nil }
        let globalPool = stringPool(bytes, at: position)
        position += Int(u32(bytes, position + 4))

        let typeId = UInt8((resourceId >> 16) & 0xFF)
        let entryIndex = Int(resourceId & 0xFFFF)

        while position + 8 <= bytes.count {
            let type = u16(bytes, position)
            let size = Int(u32(bytes, position + 4))
            guard size > 0 else { break }
            if type == Chunk.package,
               let value = resolve(inPackage: bytes, at: position, typeId: typeId, entryIndex: entryIndex, pool: globalPool) {
                return value
            }
            position += size
        }
        return nil
    }

    // MARK: - Package / type walking

    private static func resolve(inPackage bytes: [UInt8],
                                at packageStart: Int,
                                typeId: UInt8,
                                entryIndex: Int,
                                pool: [String?]) -> String? {
        let headerSize = Int(u16(bytes, packageStart + 2))
        let packageSize = Int(u32(bytes, packageStart + 4))
        let packageEnd = packageStart + packageSize

        var position = packageStart + headerSize
        var fallback: String?
        while position + 8 <= packageEnd {
            let type = u16(bytes, position)
            let size = Int(u32(bytes, position + 4))
            guard size > 0 else { break }
            if type == Chunk.type,
               let entry = typeEntry(bytes: bytes, at: position, typeId: typeId, entryIndex: entryIndex, pool: pool) {
                if entry.isDefault { return entry.value }
                if fallback == nil { fallback = entry.value }
            }
            position += size
        }
        return fallback
    }

    private static func typeEntry(bytes: [UInt8],
                                  at start: Int,
                                  typeId: UInt8,
                                  entryIndex: Int,
                                  pool: [String?]) -> (isDefault: Bool, value: String)? {
        guard u16(bytes, start) == Chunk.type else { return nil }
        let headerSize = Int(u16(bytes, start + 2))
        guard bytes[start + 8] == typeId else { return nil }

        let entryCount = Int(u32(bytes, start + 12))
        let entriesStart = Int(u32(bytes, start + 16))
        guard entryIndex >= 0, entryIndex < entryCount else { return nil }

        let offsetsBase = start + headerSize
        let offset = Int(u32(bytes, offsetsBase + entryIndex * 4))
        guard offset != 0xFFFF_FFFF else { return nil }

        let entryPosition = start + entriesStart + offset
        guard entryPosition + 8 <= bytes.count else { return nil }

        let entrySize = Int(u16(bytes, entryPosition))
        let flags = u16(bytes, entryPosition + 2)
        guard flags & 0x0001 == 0 else { return nil } // complex (bag) entry — not a plain string

        let valuePosition = entryPosition + entrySize
        guard valuePosition + 8 <= bytes.count else { return nil }
        let dataType = bytes[valuePosition + 3]
        let data = u32(bytes, valuePosition + 4)
        guard dataType == ValueType.string else { return nil }

        let index = Int(data)
        guard index >= 0, index < pool.count, let value = pool[index] else { return nil }
        return (isDefaultConfig(bytes, typeStart: start, headerSize: headerSize), value)
    }

    private static func isDefaultConfig(_ bytes: [UInt8], typeStart: Int, headerSize: Int) -> Bool {
        // ResTable_type::config begins right after the fixed fields (20 bytes).
        let configStart = typeStart + 20
        guard configStart + 4 <= bytes.count else { return true }
        let configSize = Int(u32(bytes, configStart))
        if configSize <= 4 { return true }
        let end = min(configStart + configSize, bytes.count)
        var index = configStart + 4
        while index < end {
            if bytes[index] != 0 { return false }
            index += 1
        }
        return true
    }

    // MARK: - String pool

    private static func stringPool(_ bytes: [UInt8], at start: Int) -> [String?] {
        guard u16(bytes, start) == Chunk.stringPool else { return [] }
        let stringCount = Int(u32(bytes, start + 8))
        let flags = u32(bytes, start + 16)
        let stringsStart = Int(u32(bytes, start + 20))
        let isUTF8 = (flags & 0x0000_0100) != 0
        let offsetsBase = start + 28
        let base = start + stringsStart

        var result: [String?] = []
        result.reserveCapacity(stringCount)
        for index in 0..<stringCount {
            let relative = Int(u32(bytes, offsetsBase + index * 4))
            result.append(decodeString(bytes, at: base + relative, utf8: isUTF8))
        }
        return result
    }

    private static func decodeString(_ bytes: [UInt8], at index: Int, utf8: Bool) -> String? {
        var reader = ByteReader(bytes, offset: index)
        if utf8 {
            // UTF-8 pools store two length prefixes: UTF-16 code-unit length,
            // then UTF-8 byte length.
            guard readUTFLength(&reader) != nil, let byteLength = readUTFLength(&reader) else { return nil }
            guard let slice = reader.slice(reader.offset, byteLength) else { return nil }
            return String(decoding: slice, as: UTF8.self)
        } else {
            guard var length = reader.u16() else { return nil }
            if length & 0x8000 != 0 {
                guard let next = reader.u16() else { return nil }
                length = ((length & 0x7FFF) << 16) | next
            }
            guard let slice = reader.slice(reader.offset, Int(length) * 2) else { return nil }
            let start = slice.startIndex
            let scalars = stride(from: 0, to: slice.count, by: 2).map { offset -> UInt16 in
                UInt16(slice[start + offset]) | (UInt16(slice[start + offset + 1]) << 8)
            }
            return String(decoding: scalars, as: UTF16.self)
        }
    }

    /// Reads a UTF-8 string-pool length field (1 or 2 bytes, high-bit extended).
    private static func readUTFLength(_ reader: inout ByteReader) -> Int? {
        guard let first = reader.u8() else { return nil }
        if first & 0x80 != 0 {
            guard let next = reader.u8() else { return nil }
            return (Int(first & 0x7F) << 8) | Int(next)
        }
        return Int(first)
    }

    // MARK: - Little-endian helpers

    private static func u16(_ bytes: [UInt8], _ index: Int) -> UInt16 {
        guard index + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
    }

    private static func u32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        guard index + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[index])
            | (UInt32(bytes[index + 1]) << 8)
            | (UInt32(bytes[index + 2]) << 16)
            | (UInt32(bytes[index + 3]) << 24)
    }
}
