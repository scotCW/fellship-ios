import Foundation
import CryptoKit

/// Fellship's application-layer wire format. Everything a room exchanges —
/// presence, chat, zone events — is encrypted with the room key *before* it
/// touches the mesh, independent of whatever encryption MeshCore's transport
/// applies (spec §6).
///
/// LoRa is tiny: a MeshCore text payload tops out around 160 bytes, so room
/// traffic uses hand-packed binary bodies, not JSON:
///
///     channel text = "~F1~" + base64url( roomIDPrefix(8) || ChaChaPoly box )
///
/// Direct-message payloads (the invite handshake) are JSON for flexibility
/// but split into chunks that each fit a LoRa frame:
///
///     dm text = "~F2~" + base64url( msgID(4) || index(1) || count(1) || data )
///
/// The room key itself only ever travels inside a Curve25519 sealed box
/// addressed to the invitee (or via QR, face to face).
enum FellshipEnvelope {
    static let roomPrefix = "~F1~"
    static let directPrefix = "~F2~"

    enum PayloadType: UInt8 {
        case presence = 1
        case chat = 2
        case zoneEvent = 4
        case memberAnnounce = 5
        case inviteOffer = 16
        case inviteAccept = 17
        case roomKeyDelivery = 18
    }

    enum EnvelopeError: Error {
        case malformed
        case unknownType
        case tooManyChunks
    }

    // MARK: - Payload models

    /// Periodic presence beacon inside a room. Coordinates are included only
    /// when the room's visibility setting allows — enforced at the broadcast
    /// level, not in the UI (spec §3.4). `memberID` on the wire is an 8-byte
    /// identity-key prefix (hex); receivers resolve it against membership.
    struct Presence: Equatable {
        var memberID: String
        var isInside: Bool
        var coordinate: Coordinate?
        var sentAt: Date
    }

    /// One chat frame. Messages longer than a LoRa frame travel as several
    /// parts sharing a message ID; receivers reassemble before display.
    struct Chat: Equatable {
        var messageID: String   // 6 random bytes, hex (shared by all parts)
        var memberID: String
        var zoneScoped: Bool
        var text: String
        var sentAt: Date
        var part: UInt8 = 0
        var partCount: UInt8 = 1
    }

    /// "I crossed the boundary" — every device evaluates its own GPS against
    /// the shared boundary and announces transitions (spec §3.1).
    struct ZoneEvent: Equatable {
        var memberID: String
        var didEnter: Bool
        var sentAt: Date
    }

    /// Announces a member (with full identity key + name) on the room
    /// channel, so presence prefixes resolve to names.
    struct MemberAnnounce: Equatable {
        var member: Member
    }

    enum RoomPayload: Equatable {
        case presence(Presence)
        case chat(Chat)
        case zoneEvent(ZoneEvent)
        case memberAnnounce(MemberAnnounce)
    }

    // Invite handshake payloads (JSON over chunked DMs).

    struct InviteOffer: Codable, Equatable {
        var inviteID: String
        var roomID: String
        var roomName: String
        var roomKind: RoomKind
        var access: RoomAccess
        var inviterIdentityKey: String
        var inviterName: String
        var isAutomatic: Bool
    }

    struct InviteAccept: Codable, Equatable {
        var inviteID: String
        var roomID: String
        var inviteeIdentityKey: String
        var inviteeName: String
    }

    /// The room manifest + key, sealed to the invitee's identity key.
    struct RoomKeyDelivery: Codable, Equatable {
        var inviteID: String
        var roomID: String
        var sealedManifest: Data
    }

    /// Everything a new member needs to reconstruct the room locally.
    struct RoomManifest: Codable, Equatable {
        var room: Room
        var members: [Member]
        var roomKeyData: Data
    }

    // MARK: - Member ID prefix helpers

    /// 8-byte identity prefix used on the wire (16 hex chars).
    static func wirePrefix(ofMemberID id: String) -> Data {
        if let data = Data(hexEncoded: id), data.count >= 8 {
            return data.prefix(8)
        }
        // Defensive: derive a stable prefix from whatever the ID is.
        return Data(SHA256.hash(data: Data(id.utf8))).prefix(8)
    }

    // MARK: - Room payload binary codec

    private static func encodeBody(_ payload: RoomPayload) -> Data {
        var w = BinaryWriter()
        switch payload {
        case .presence(let p):
            w.writeUInt8(PayloadType.presence.rawValue)
            var flags: UInt8 = p.isInside ? 0b01 : 0
            if p.coordinate != nil { flags |= 0b10 }
            w.writeUInt8(flags)
            w.writeBytes(wirePrefix(ofMemberID: p.memberID))
            w.writeUInt32(UInt32(clamping: Int(p.sentAt.timeIntervalSince1970)))
            if let coordinate = p.coordinate {
                w.writeInt32(coordinate.microdegreesLat)
                w.writeInt32(coordinate.microdegreesLon)
            }
        case .chat(let c):
            w.writeUInt8(PayloadType.chat.rawValue)
            w.writeUInt8(c.zoneScoped ? 1 : 0)
            // 6-byte IDs keep a 60-char message inside one LoRa frame.
            var msgID = Data(hexEncoded: c.messageID) ?? Data(count: 6)
            if msgID.count < 6 { msgID.append(Data(count: 6 - msgID.count)) }
            w.writeBytes(msgID.prefix(6))
            w.writeBytes(wirePrefix(ofMemberID: c.memberID).prefix(6))
            w.writeUInt32(UInt32(clamping: Int(c.sentAt.timeIntervalSince1970)))
            w.writeUInt8(c.part)
            w.writeUInt8(max(1, c.partCount))
            w.writeString(c.text)
        case .zoneEvent(let e):
            w.writeUInt8(PayloadType.zoneEvent.rawValue)
            w.writeUInt8(e.didEnter ? 1 : 0)
            w.writeBytes(wirePrefix(ofMemberID: e.memberID))
            w.writeUInt32(UInt32(clamping: Int(e.sentAt.timeIntervalSince1970)))
        case .memberAnnounce(let a):
            w.writeUInt8(PayloadType.memberAnnounce.rawValue)
            let identity = Data(hexEncoded: a.member.id) ?? Data(count: 32)
            w.writeBytes(identity.prefix(32) + Data(count: max(0, 32 - identity.count)))
            let radio = a.member.radioPublicKey.flatMap { Data(hexEncoded: $0) }
            w.writeUInt8(radio != nil ? 1 : 0)
            if let radio {
                w.writeBytes(radio.prefix(32) + Data(count: max(0, 32 - radio.count)))
            }
            w.writeString(String(a.member.displayName.prefix(24)))
        }
        return w.data
    }

    private static func decodeBody(_ data: Data) throws -> RoomPayload {
        var r = BinaryReader(data)
        guard let type = PayloadType(rawValue: try r.readUInt8()) else {
            throw EnvelopeError.unknownType
        }
        switch type {
        case .presence:
            let flags = try r.readUInt8()
            let member = try r.readBytes(8).hexEncoded
            let ts = Date(timeIntervalSince1970: TimeInterval(try r.readUInt32()))
            var coordinate: Coordinate?
            if flags & 0b10 != 0 {
                coordinate = Coordinate(microdegreesLat: try r.readInt32(),
                                        microdegreesLon: try r.readInt32())
            }
            return .presence(Presence(memberID: member, isInside: flags & 0b01 != 0,
                                      coordinate: coordinate, sentAt: ts))
        case .chat:
            let flags = try r.readUInt8()
            let messageID = try r.readBytes(6).hexEncoded
            let member = try r.readBytes(6).hexEncoded
            let ts = Date(timeIntervalSince1970: TimeInterval(try r.readUInt32()))
            let part = try r.readUInt8()
            let partCount = try r.readUInt8()
            let text = r.readStringToEnd()
            return .chat(Chat(messageID: messageID, memberID: member,
                              zoneScoped: flags & 1 != 0, text: text, sentAt: ts,
                              part: part, partCount: max(1, partCount)))
        case .zoneEvent:
            let flags = try r.readUInt8()
            let member = try r.readBytes(8).hexEncoded
            let ts = Date(timeIntervalSince1970: TimeInterval(try r.readUInt32()))
            return .zoneEvent(ZoneEvent(memberID: member, didEnter: flags & 1 != 0, sentAt: ts))
        case .memberAnnounce:
            let identity = try r.readBytes(32).hexEncoded
            let hasRadio = try r.readUInt8() == 1
            let radio = hasRadio ? try r.readBytes(32).hexEncoded : nil
            let name = r.readStringToEnd()
            return .memberAnnounce(MemberAnnounce(member: Member(
                id: identity,
                displayName: name.isEmpty ? "Member \(identity.prefix(6))" : name,
                radioPublicKey: radio,
                joinedAt: Date())))
        default:
            throw EnvelopeError.unknownType
        }
    }

    /// Builds the channel text for an encrypted room payload.
    static func sealRoomPayload(_ payload: RoomPayload, roomID: String,
                                roomKey: SymmetricKey) throws -> String {
        let body = encodeBody(payload)
        let sealed = try CryptoService.seal(body, roomKey: roomKey, roomID: roomID)
        guard let prefix = Data(hexEncoded: String(roomID.prefix(16))) else {
            throw EnvelopeError.malformed
        }
        return roomPrefix + (prefix + sealed).base64URLEncoded
    }

    /// Extracts the 8-byte room ID prefix from received channel text, so the
    /// receiver knows which room key to try. Returns nil for non-Fellship text.
    static func roomIDPrefix(fromText text: String) -> String? {
        guard text.hasPrefix(roomPrefix),
              let raw = Data(base64URLEncoded: String(text.dropFirst(roomPrefix.count))),
              raw.count > 8 else { return nil }
        return raw.prefix(8).hexEncoded
    }

    static func openRoomPayload(_ text: String, roomID: String,
                                roomKey: SymmetricKey) throws -> RoomPayload {
        guard text.hasPrefix(roomPrefix),
              let raw = Data(base64URLEncoded: String(text.dropFirst(roomPrefix.count))),
              raw.count > 8 else {
            throw EnvelopeError.malformed
        }
        let body = try CryptoService.open(Data(raw.dropFirst(8)), roomKey: roomKey, roomID: roomID)
        return try decodeBody(body)
    }

    // MARK: - Direct-message chunked payloads (invite handshake)

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    /// Splits a payload into DM-sized texts. Each chunk's base64 stays under
    /// ~140 characters so it fits a stock MeshCore text frame.
    static func directChunks<T: Encodable>(_ payload: T, type: PayloadType,
                                           chunkDataSize: Int = 96) throws -> [String] {
        var full = Data([type.rawValue])
        full.append(try jsonEncoder.encode(payload))
        let msgID = UInt32.random(in: 1..<UInt32.max)
        let pieces = stride(from: 0, to: full.count, by: chunkDataSize).map {
            full.subdata(in: $0..<min($0 + chunkDataSize, full.count))
        }
        guard pieces.count <= 255 else { throw EnvelopeError.tooManyChunks }
        return pieces.enumerated().map { index, piece in
            var w = BinaryWriter()
            w.writeUInt32(msgID)
            w.writeUInt8(UInt8(index))
            w.writeUInt8(UInt8(pieces.count))
            w.writeBytes(piece)
            return directPrefix + w.data.base64URLEncoded
        }
    }

    static func isDirectEnvelope(_ text: String) -> Bool {
        text.hasPrefix(directPrefix)
    }

    static func decodeDirectPayload<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        try jsonDecoder.decode(type, from: body)
    }

    static func encodeManifest(_ manifest: RoomManifest) throws -> Data {
        try jsonEncoder.encode(manifest)
    }

    static func decodeManifest(_ data: Data) throws -> RoomManifest {
        try jsonDecoder.decode(RoomManifest.self, from: data)
    }

    /// Reassembles chunked direct payloads per sender. Partial messages are
    /// dropped after `timeout` so lost LoRa frames can't leak memory.
    final class DirectAssembler {
        private struct Partial {
            var chunks: [UInt8: Data] = [:]
            var count: UInt8
            var startedAt = Date()
        }

        private var partials: [String: Partial] = [:] // "senderHex|msgID"
        private let timeout: TimeInterval

        init(timeout: TimeInterval = 300) {
            self.timeout = timeout
        }

        /// Feed one DM text; returns the completed (type, body) when the last
        /// chunk arrives, nil otherwise. Not a Fellship envelope → nil.
        func ingest(senderHex: String, text: String) -> (type: PayloadType, body: Data)? {
            guard text.hasPrefix(FellshipEnvelope.directPrefix),
                  let raw = Data(base64URLEncoded: String(text.dropFirst(FellshipEnvelope.directPrefix.count))),
                  raw.count > 6 else { return nil }
            var r = BinaryReader(raw)
            guard let msgID = try? r.readUInt32(),
                  let index = try? r.readUInt8(),
                  let count = try? r.readUInt8(),
                  count > 0, index < count else { return nil }
            let data = Data(raw.dropFirst(6))

            sweep()
            // Hard cap so a chunk flood can't grow memory; oldest partials
            // are least likely to ever complete.
            if partials.count >= 32,
               let oldest = partials.min(by: { $0.value.startedAt < $1.value.startedAt }) {
                partials[oldest.key] = nil
            }
            let key = "\(senderHex)|\(msgID)"
            var partial = partials[key] ?? Partial(count: count)
            guard partial.count == count else {
                partials[key] = nil
                return nil
            }
            partial.chunks[index] = data
            guard partial.chunks.count == Int(count) else {
                partials[key] = partial
                return nil
            }
            partials[key] = nil
            var full = Data()
            for i in 0..<count {
                guard let piece = partial.chunks[i] else { return nil }
                full.append(piece)
            }
            guard let first = full.first, let type = PayloadType(rawValue: first) else { return nil }
            return (type, Data(full.dropFirst()))
        }

        private func sweep() {
            let cutoff = Date().addingTimeInterval(-timeout)
            partials = partials.filter { $0.value.startedAt > cutoff }
        }
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        self.init(base64Encoded: s)
    }
}
