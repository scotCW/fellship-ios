import Foundation

/// The geometric boundary of a geofenced room.
enum Boundary: Codable, Hashable, Sendable {
    /// Center + radius in meters.
    case circle(center: Coordinate, radiusMeters: Double)
    /// Axis-aligned box defined by two opposite corners.
    case box(cornerA: Coordinate, cornerB: Coordinate)
    /// Freeform outline traced by the user. Implicitly closed.
    case polygon(vertices: [Coordinate])

    var kindDescription: String {
        switch self {
        case .circle: return "Circle"
        case .box: return "Box"
        case .polygon: return "Freeform outline"
        }
    }
}

enum RoomKind: String, Codable, Hashable, Sendable {
    /// Membership in the zone is defined by a geographic boundary.
    case geofenced
    /// "In the room" means reachable over the mesh right now.
    case rangeBased
}

enum Permanence: String, Codable, Hashable, Sendable {
    case temporary
    case permanent
}

enum RoomAccess: String, Codable, Hashable, Sendable {
    /// Joinable only via explicit invite from an existing member.
    case inviteOnly
    /// Discoverable by mesh proximity; members auto-invite outsiders
    /// whose "open to invite" beacon lands inside the zone.
    case publicRoom = "public"
}

/// A room. Stored locally only — identically on every member's device.
/// There is intentionally no cloud representation of this type.
struct Room: Identifiable, Codable, Hashable, Sendable {
    /// Random 16-byte identifier, hex-encoded. Shared by all members.
    var id: String
    var name: String
    var kind: RoomKind
    /// nil for range-based rooms.
    var boundary: Boundary?
    var access: RoomAccess
    var permanence: Permanence
    /// For temporary rooms: the date after which the room auto-deletes.
    /// nil for permanent rooms.
    var expiresAt: Date?
    /// Whether members' precise coordinates are included in presence
    /// broadcasts for this room. Enforced at the broadcast level.
    var sharesPreciseLocation: Bool
    /// Local-only preference: silence notifications from this room.
    var isMuted: Bool
    var createdAt: Date
    /// The member ID (app identity key) of the room creator.
    var creatorID: String

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }
}

/// A member of a room as known locally.
struct Member: Identifiable, Codable, Hashable, Sendable {
    /// Hex of the member's Fellship identity public key (Curve25519, 32 bytes).
    var id: String
    var displayName: String
    /// Hex of the member's radio public key (for direct mesh routing), if known.
    var radioPublicKey: String?
    var joinedAt: Date
}

/// Live, non-persisted presence state for a member in one room.
struct MemberPresence: Hashable, Sendable {
    var memberID: String
    /// Last self-reported "am I inside the zone" flag (geofenced rooms),
    /// or simply "I'm here" for range-based rooms.
    var isInside: Bool
    /// Last reported coordinate — only present when the room shares locations.
    var coordinate: Coordinate?
    var lastHeard: Date

    func isFresh(interval: TimeInterval, now: Date = Date()) -> Bool {
        // Presence is considered stale after three missed broadcast intervals,
        // with a floor so very short intervals don't flap.
        let window = max(interval * 3, 90)
        return now.timeIntervalSince(lastHeard) < window
    }
}
