import Foundation

/// Little-endian binary writer matching the MeshCore companion serial format.
struct BinaryWriter {
    private(set) var data = Data()

    mutating func writeUInt8(_ v: UInt8) { data.append(v) }
    mutating func writeInt8(_ v: Int8) { data.append(UInt8(bitPattern: v)) }

    mutating func writeUInt16(_ v: UInt16) {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func writeUInt32(_ v: UInt32) {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func writeInt32(_ v: Int32) {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func writeBytes(_ bytes: Data) { data.append(bytes) }

    /// UTF-8 string with no terminator (MeshCore strings run to frame end).
    mutating func writeString(_ s: String) { data.append(Data(s.utf8)) }

    /// Fixed-width, zero-padded C string field.
    mutating func writeCString(_ s: String, fieldLength: Int) {
        var bytes = Data(s.utf8.prefix(fieldLength - 1))
        bytes.append(Data(repeating: 0, count: fieldLength - bytes.count))
        data.append(bytes)
    }
}

/// Little-endian binary reader tolerant of short frames: reads past the end
/// throw, so malformed radio frames become recoverable errors, not crashes.
struct BinaryReader {
    enum ReaderError: Error { case outOfBounds }

    private let data: Data
    private(set) var offset: Int = 0

    init(_ data: Data) {
        // Re-base so integer subscripts start at zero regardless of the
        // source Data's slice indices.
        self.data = Data(data)
    }

    var remainingCount: Int { data.count - offset }

    mutating func readUInt8() throws -> UInt8 {
        guard remainingCount >= 1 else { throw ReaderError.outOfBounds }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readInt8() throws -> Int8 {
        Int8(bitPattern: try readUInt8())
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readBytes(2)
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(4)
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, remainingCount >= count else { throw ReaderError.outOfBounds }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    /// Remaining bytes as UTF-8 (lossy) string.
    mutating func readStringToEnd() -> String {
        let bytes = data.subdata(in: offset..<data.count)
        offset = data.count
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Fixed-width zero-padded C string field.
    mutating func readCString(fieldLength: Int) throws -> String {
        let bytes = try readBytes(fieldLength)
        let terminated = bytes.prefix { $0 != 0 }
        return String(decoding: terminated, as: UTF8.self)
    }

    mutating func skip(_ count: Int) throws {
        _ = try readBytes(count)
    }
}
