import Foundation

/// Encodes/decodes a contact as a compact QR string so nodes can be shared
/// face-to-face. Fellship's own format (`MCC1:` + base64url of a fixed binary
/// layout) — independent of any other app's scheme.
///
/// Layout after the prefix: publicKey(32) | type(1) | flags(1) | latµ°(int32)
/// | lonµ°(int32) | name(UTF-8, to end).
enum ContactCard {
    static let qrPrefix = "MCC1:"

    static func encode(publicKey: Data, type: UInt8, flags: UInt8,
                       name: String, coordinate: Coordinate) -> String {
        var w = BinaryWriter()
        var key = publicKey.prefix(32)
        if key.count < 32 { key.append(Data(count: 32 - key.count)) }
        w.writeBytes(key)
        w.writeUInt8(type)
        w.writeUInt8(flags)
        w.writeInt32(coordinate.microdegreesLat)
        w.writeInt32(coordinate.microdegreesLon)
        w.writeString(String(name.prefix(31)))
        return qrPrefix + w.data.base64URLEncoded
    }

    static func encode(_ contact: MeshCore.Contact) -> String {
        encode(publicKey: contact.publicKey, type: contact.type, flags: contact.flags,
               name: contact.name, coordinate: contact.coordinate)
    }

    /// Parses a scanned/pasted card into a Contact ready for AddUpdateContact.
    /// A newly imported contact has an unknown route (outPathLength -1), so the
    /// radio re-discovers the best path.
    static func decode(_ string: String) -> MeshCore.Contact? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(qrPrefix),
              let raw = Data(base64URLEncoded: String(trimmed.dropFirst(qrPrefix.count))),
              raw.count >= 42 else { return nil }
        var r = BinaryReader(raw)
        guard let key = try? r.readBytes(32),
              let type = try? r.readUInt8(),
              let flags = try? r.readUInt8(),
              let lat = try? r.readInt32(),
              let lon = try? r.readInt32() else { return nil }
        let name = r.readStringToEnd()
        return MeshCore.Contact(
            publicKey: key,
            type: type,
            flags: flags,
            outPathLength: -1,
            outPath: Data(),
            name: name,
            lastAdvert: Date(),
            coordinate: Coordinate(microdegreesLat: lat, microdegreesLon: lon),
            lastModified: Date())
    }
}
