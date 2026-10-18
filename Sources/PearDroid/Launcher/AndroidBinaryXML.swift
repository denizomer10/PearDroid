import Foundation

/// Minimal parser for Android's binary XML (AXML) format, just deep enough to
/// read the `package`, `versionName`, `versionCode` and (string) `label`
/// attributes out of an APK's compiled `AndroidManifest.xml`.
///
/// The format is a sequence of chunks: a string pool followed by a stream of
/// element/namespace nodes. Only the `manifest` and `application`
/// start-elements are inspected.
enum AndroidBinaryXML {

    struct Manifest {
        var packageName: String?
        var versionName: String?
        var versionCode: Int?
        var label: String?
        var labelResourceId: UInt32?
    }

    private enum ChunkType {
        static let stringPool: UInt16 = 0x0001
        static let xml: UInt16 = 0x0003
        static let startElement: UInt16 = 0x0102
    }

    private enum ValueType {
        static let reference: UInt8 = 0x01
        static let string: UInt8 = 0x03
        static let intDec: UInt8 = 0x10
    }

    private static let wantedAttributes: Set<String> = ["package", "versionName", "versionCode", "label"]

    static func parseManifest(_ data: Data) -> Manifest? {
        var reader = ByteReader(data)

        // File header.
        guard reader.u16() == ChunkType.xml else { return nil }
        _ = reader.u16()          // header size
        _ = reader.u32()          // total size

        // String pool chunk.
        let poolStart = reader.offset
        guard reader.u16() == ChunkType.stringPool else { return nil }
        _ = reader.u16()          // header size
        guard let poolSize = reader.u32(),
              let stringCount = reader.u32(),
              let _ = reader.u32(),   // style count
              let flags = reader.u32(),
              let stringsStart = reader.u32(),
              let _ = reader.u32()    // styles start
        else { return nil }

        let isUTF8 = (flags & 0x0000_0100) != 0
        let offsetsStart = reader.offset
        var offsets: [Int] = []
        offsets.reserveCapacity(Int(stringCount))
        for index in 0..<Int(stringCount) {
            guard let relative = reader.u32(at: offsetsStart + index * 4) else { return nil }
            offsets.append(Int(relative))
        }

        let stringsBase = poolStart + Int(stringsStart)
        func string(at index: Int) -> String? {
            guard index >= 0, index < offsets.count else { return nil }
            return decodeString(data, at: stringsBase + offsets[index], utf8: isUTF8)
        }

        var manifest = Manifest()
        reader.seek(poolStart + Int(poolSize))

        while reader.remaining >= 8 {
            let chunkStart = reader.offset
            guard let type = reader.u16(),
                  let _ = reader.u16(),        // header size
                  let chunkSize = reader.u32(),
                  chunkSize >= 8
            else { break }

            if type == ChunkType.startElement,
               let element = parseStartElement(reader, chunkStart: chunkStart, string: string) {
                switch element.name {
                case "manifest":
                    if manifest.packageName == nil { manifest.packageName = element.strings["package"] }
                    if manifest.versionName == nil { manifest.versionName = element.strings["versionName"] }
                    if manifest.versionCode == nil { manifest.versionCode = element.ints["versionCode"] }
                case "application":
                    if manifest.label == nil { manifest.label = element.strings["label"] }
                    if manifest.labelResourceId == nil { manifest.labelResourceId = element.references["label"] }
                default:
                    break
                }
            }

            let next = chunkStart + Int(chunkSize)
            guard next > chunkStart else { break }
            reader.seek(next)
        }

        if manifest.packageName == nil && manifest.label == nil && manifest.labelResourceId == nil { return nil }
        return manifest
    }

    // MARK: - Element parsing

    private struct Element {
        let name: String
        var strings: [String: String] = [:]
        var ints: [String: Int] = [:]
        var references: [String: UInt32] = [:]
    }

    private static func parseStartElement(_ reader: ByteReader,
                                          chunkStart: Int,
                                          string: (Int) -> String?) -> Element? {
        var cursor = ByteReader(reader.bytes, offset: chunkStart + 8)
        _ = cursor.u32()   // line number
        _ = cursor.u32()   // comment
        _ = cursor.u32()   // namespace
        guard let nameIndex = cursor.u32(),
              let _ = cursor.u16(),   // attribute start
              let _ = cursor.u16(),   // attribute size
              let attributeCount = cursor.u16()
        else { return nil }
        _ = cursor.u16()   // id index
        _ = cursor.u16()   // class index
        _ = cursor.u16()   // style index

        guard let name = string(Int(nameIndex)) else { return nil }
        var element = Element(name: name)

        for _ in 0..<Int(attributeCount) {
            guard let _ = cursor.u32(),          // namespace
                  let attrNameIndex = cursor.u32(),
                  let _ = cursor.u32(),          // raw value
                  let _ = cursor.u16(),          // typed value size
                  let _ = cursor.u8(),           // res0
                  let dataType = cursor.u8(),
                  let attrData = cursor.u32()
            else { break }

            guard let attrName = string(Int(attrNameIndex)),
                  wantedAttributes.contains(attrName) else { continue }

            switch dataType {
            case ValueType.string:
                if let value = string(Int(attrData)) { element.strings[attrName] = value }
            case ValueType.intDec:
                element.ints[attrName] = Int(attrData)
            case ValueType.reference:
                element.references[attrName] = attrData
            default:
                break
            }
        }
        return element
    }

    // MARK: - String pool decoding

    private static func decodeString(_ data: Data, at index: Int, utf8: Bool) -> String? {
        var reader = ByteReader(data, offset: index)
        if utf8 {
            // UTF-8 pools store two length prefixes: the length in UTF-16 code
            // units, then the length in UTF-8 bytes.
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
}
