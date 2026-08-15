import Foundation

/// How a message was scoped when it was sent.
enum MessageScope: String, Codable, Hashable, Sendable {
    /// Delivered to all current members of the room.
    case room
    /// Delivered only to members currently active in the zone / in range.
    case zone
    /// One-to-one message to a nearby device; no room involved.
    case direct
}

enum DeliveryState: String, Codable, Hashable, Sendable {
    /// Handed to the radio for transmission.
    case sent
    /// The mesh acknowledged the packet (direct messages only).
    case heard
    /// No acknowledgement arrived before the radio's estimated timeout.
    case timedOut
    /// Received from another member.
    case received
}

struct RoomMessage: Identifiable, Codable, Hashable, Sendable {
    var id: String
    /// Room ID, or the peer's ID for direct messages.
    var threadID: String
    var scope: MessageScope
    /// Sender's member ID (app identity key hex). Empty for system events.
    var senderID: String
    var senderName: String
    var text: String
    var sentAt: Date
    var delivery: DeliveryState
    var isFromMe: Bool

    /// True for locally generated entry/exit event lines shown inline in chat.
    var isSystemEvent: Bool = false

    /// Emoji reactions, keyed by emoji → the member IDs who reacted with it.
    /// Defaulted so messages stored before reactions existed still decode.
    var reactions: [String: [String]] = [:]

    /// Reactions in a stable display order (most-reacted first, then emoji),
    /// so the row doesn't reshuffle as identical counts arrive.
    var sortedReactions: [(emoji: String, memberIDs: [String])] {
        reactions
            .filter { !$0.value.isEmpty }
            .sorted {
                $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count
            }
            .map { (emoji: $0.key, memberIDs: $0.value) }
    }
}

// Swift's synthesized decoder *throws* on a missing key rather than falling
// back to a property's default value, so simply adding `reactions` would make
// every message stored by an earlier version fail to decode — silently wiping
// chat history on upgrade. Decoding by hand (in an extension, so the
// memberwise initializer survives) keeps old rows readable.
extension RoomMessage {
    enum CodingKeys: String, CodingKey {
        case id, threadID, scope, senderID, senderName, text, sentAt
        case delivery, isFromMe, isSystemEvent, reactions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        threadID = try c.decode(String.self, forKey: .threadID)
        scope = try c.decode(MessageScope.self, forKey: .scope)
        senderID = try c.decode(String.self, forKey: .senderID)
        senderName = try c.decode(String.self, forKey: .senderName)
        text = try c.decode(String.self, forKey: .text)
        sentAt = try c.decode(Date.self, forKey: .sentAt)
        delivery = try c.decode(DeliveryState.self, forKey: .delivery)
        isFromMe = try c.decode(Bool.self, forKey: .isFromMe)
        isSystemEvent = try c.decodeIfPresent(Bool.self, forKey: .isSystemEvent) ?? false
        reactions = try c.decodeIfPresent([String: [String]].self, forKey: .reactions) ?? [:]
    }
}

/// A pending room invite, in either direction.
struct Invite: Identifiable, Codable, Hashable, Sendable {
    enum State: String, Codable, Sendable {
        /// We sent an offer and are waiting for an accept.
        case offered
        /// We received an offer and the user hasn't decided yet.
        case received
        /// Invitee accepted; waiting for the key/manifest to arrive.
        case accepted
        /// Key delivered and room joined.
        case completed
        case declined
    }

    var id: String
    var roomID: String
    var roomName: String
    var roomKind: RoomKind
    var access: RoomAccess
    /// Radio public key (hex) of the other party.
    var peerRadioKey: String
    /// Fellship identity public key (hex) of the other party, once known.
    var peerIdentityKey: String?
    var peerName: String
    var state: State
    var isOutgoing: Bool
    /// True when this invite was generated automatically because an
    /// "open to invite" beacon landed inside a public room's zone.
    var isAutomatic: Bool
    var createdAt: Date
}
