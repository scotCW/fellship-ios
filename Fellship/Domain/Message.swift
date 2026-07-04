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
