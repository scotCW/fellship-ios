import Foundation
import CryptoKit

/// Fellship's application-layer wire format. Everything a room exchanges —
/// presence, chat, zone events — is encrypted with the room key *before* it
/// touches the mesh, independent of whatever encryption MeshCore's transport
/// applies (spec §6).
///
/// Room traffic rides the room's MeshCore channel as a text message:
///     "~F1~" + base64url( roomIDPrefix(8) || sealedBox )
/// where sealedBox = ChaChaPoly(roomKey, AAD: full room ID) over a plaintext
/// `Payload`. Invite traffic rides direct messages with the same framing but
/// its own payload types; the room key itself only ever travels inside a
/// Curve25519 sealed box addressed to the invitee.
enum FellshipEnvelope {
    static let textPrefix = "~F1~"

    enum PayloadType: UInt8 {
        case presence = 1
        case chat = 2
        case zoneChat = 3
        case zoneEvent = 4
        case inviteOffer = 16
        case inviteAccept = 17
        case roomKeyDelivery = 18
        case memberAnnounce = 19
    }

    // MARK: - Payload bodies

    /// Periodic presence beacon inside a room. Coordinates are included only
    /// when the room's visibility setting allows — enforced here at the
    /// broadcast level, not in the UI (spec §3.4).
    struct Presence: Codable, Equatable {
        var memberID: String
        var name: String
        var isInside: Bool
        var latitude: Double?
        var longitude: Double?
        var sentAt: Date

        var coordinate: Coordinate? {
            guard let latitude, let longitude else { return nil }
            return Coordinate(latitude: latitude, longitude: longitude)
        }
    }

    struct Chat: Codable, Equatable {
        var messageID: String
        var memberID: String
        var name: String
        var text: String
        var sentAt: Date
    }

    /// "I crossed the boundary" — every device evaluates its own GPS against
    /// the shared boundary and announces transitions (spec §3.1).
    struct ZoneEvent: Codable, Equatable {
        var memberID: String
        var name: String
        var didEnter: Bool
        var sentAt: Date
    }

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
        /// Curve25519 sealed box over `RoomManifest` JSON.
        var sealedManifest: Data
    }

    /// Everything a new member needs to reconstruct the room locally.
    struct RoomManifest: Codable, Equatable {
        var room: Room
        var members: [Member]
        var roomKeyData: Data
    }

    /// Announces a new member to the rest of the room (sent on the room
    /// channel by the inviter after key delivery).
    struct MemberAnnounce: Codable, Equatable {
        var member: Member
    }

    // MARK: - Encoding

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    /// Builds the channel text for an encrypted room payload.
    static func sealRoomText<T: Encodable>(_ payload: T, type: PayloadType,
                                           roomID: String, roomKey: SymmetricKey) throws -> String {
        var plaintext = Data([type.rawValue])
        plaintext.append(try encoder.encode(payload))
        let sealed = try CryptoService.seal(plaintext, roomKey: roomKey, roomID: roomID)
        guard let prefix = Data(hexEncoded: String(roomID.prefix(16))) else {
            throw CryptoService.CryptoError.malformedPayload
        }
        return textPrefix + (prefix + sealed).base64URLEncoded
    }

    /// Extracts the 8-byte room ID prefix from received channel text, so the
    /// receiver knows which room key to try. Returns nil for non-Fellship text.
    static func roomIDPrefix(fromText text: String) -> String? {
        guard text.hasPrefix(textPrefix),
              let raw = Data(base64URLEncoded: String(text.dropFirst(textPrefix.count))),
              raw.count > 8 else { return nil }
        return raw.prefix(8).hexEncoded
    }

    /// Decrypts and decodes a room payload. The caller resolves the room key
    /// from the prefix returned by `roomIDPrefix(fromText:)`.
    static func openRoomText(_ text: String, roomID: String,
                             roomKey: SymmetricKey) throws -> (type: PayloadType, body: Data) {
        guard text.hasPrefix(textPrefix),
              let raw = Data(base64URLEncoded: String(text.dropFirst(textPrefix.count))),
              raw.count > 8 else {
            throw CryptoService.CryptoError.malformedPayload
        }
        let sealed = raw.dropFirst(8)
        let plaintext = try CryptoService.open(Data(sealed), roomKey: roomKey, roomID: roomID)
        guard let first = plaintext.first, let type = PayloadType(rawValue: first) else {
            throw CryptoService.CryptoError.malformedPayload
        }
        return (type, Data(plaintext.dropFirst()))
    }

    static func decodeBody<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        try decoder.decode(type, from: body)
    }

    // MARK: - Direct-message envelopes (invites)

    /// Direct-message payloads are not room-key encrypted (the recipient may
    /// not have the room yet); sensitive material inside them (the room key)
    /// is sealed to the recipient's identity key. MeshCore's own
    /// contact-to-contact encryption covers the outer layer in transit.
    static func sealDirectText<T: Encodable>(_ payload: T, type: PayloadType) throws -> String {
        var plaintext = Data([type.rawValue])
        plaintext.append(try encoder.encode(payload))
        return textPrefix + plaintext.base64URLEncoded
    }

    static func openDirectText(_ text: String) throws -> (type: PayloadType, body: Data) {
        guard text.hasPrefix(textPrefix),
              let raw = Data(base64URLEncoded: String(text.dropFirst(textPrefix.count))),
              let first = raw.first, let type = PayloadType(rawValue: first) else {
            throw CryptoService.CryptoError.malformedPayload
        }
        return (type, Data(raw.dropFirst()))
    }

    static func encodeManifest(_ manifest: RoomManifest) throws -> Data {
        try encoder.encode(manifest)
    }

    static func decodeManifest(_ data: Data) throws -> RoomManifest {
        try decoder.decode(RoomManifest.self, from: data)
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
