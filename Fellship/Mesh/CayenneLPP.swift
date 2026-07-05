import Foundation

/// Minimal, tolerant Cayenne Low Power Payload decoder — the format MeshCore
/// nodes use for telemetry responses. Only the types MeshCore hardware
/// actually sends are decoded; an unknown type stops parsing (lengths of
/// unknown types can't be guessed) and returns what was read so far.
enum CayenneLPP {
    struct Reading: Equatable, Identifiable {
        var id: String { "\(channel)-\(label)" }
        var channel: UInt8
        var label: String
        var value: String
    }

    static func decode(_ data: Data) -> [Reading] {
        var readings: [Reading] = []
        var r = BinaryReader(data)
        while r.remainingCount >= 2 {
            guard let channel = try? r.readUInt8(),
                  let type = try? r.readUInt8() else { break }
            do {
                switch type {
                case 0x00, 0x01: // digital in/out — 1 byte
                    let v = try r.readUInt8()
                    readings.append(Reading(channel: channel, label: "Digital", value: "\(v)"))
                case 0x02: // analog input — 2 bytes signed, 0.01
                    let raw = Int16(bitPattern: try r.readUInt16BigEndian())
                    readings.append(Reading(channel: channel, label: "Analog",
                                            value: String(format: "%.2f", Double(raw) / 100)))
                case 0x67: // temperature — 2 bytes signed, 0.1 °C
                    let raw = Int16(bitPattern: try r.readUInt16BigEndian())
                    readings.append(Reading(channel: channel, label: "Temperature",
                                            value: String(format: "%.1f °C", Double(raw) / 10)))
                case 0x68: // humidity — 1 byte, 0.5 %
                    let raw = try r.readUInt8()
                    readings.append(Reading(channel: channel, label: "Humidity",
                                            value: String(format: "%.1f %%", Double(raw) / 2)))
                case 0x73: // barometer — 2 bytes, 0.1 hPa
                    let raw = try r.readUInt16BigEndian()
                    readings.append(Reading(channel: channel, label: "Pressure",
                                            value: String(format: "%.1f hPa", Double(raw) / 10)))
                case 0x74: // voltage — 2 bytes, 0.01 V (battery on MeshCore nodes)
                    let raw = try r.readUInt16BigEndian()
                    readings.append(Reading(channel: channel, label: "Voltage",
                                            value: String(format: "%.2f V", Double(raw) / 100)))
                case 0x88: // GPS — 3×3 bytes signed (lat/lon 1e-4°, alt 0.01 m)
                    let lat = Double(try r.readInt24BigEndian()) / 10_000
                    let lon = Double(try r.readInt24BigEndian()) / 10_000
                    let alt = Double(try r.readInt24BigEndian()) / 100
                    readings.append(Reading(channel: channel, label: "GPS",
                                            value: String(format: "%.4f, %.4f (%.0f m)", lat, lon, alt)))
                default:
                    return readings // unknown type: length unknowable, stop
                }
            } catch {
                break // truncated frame — keep what we decoded
            }
        }
        return readings
    }
}

extension BinaryReader {
    /// Cayenne LPP is big-endian, unlike the rest of the companion protocol.
    mutating func readUInt16BigEndian() throws -> UInt16 {
        let bytes = try readBytes(2)
        return UInt16(bytes[bytes.startIndex]) << 8 | UInt16(bytes[bytes.startIndex + 1])
    }

    mutating func readInt24BigEndian() throws -> Int32 {
        let bytes = try readBytes(3)
        var value = Int32(bytes[bytes.startIndex]) << 16
            | Int32(bytes[bytes.startIndex + 1]) << 8
            | Int32(bytes[bytes.startIndex + 2])
        if value & 0x800000 != 0 {
            value -= 0x1000000 // sign-extend 24-bit
        }
        return value
    }
}
