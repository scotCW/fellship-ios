import Foundation
import CryptoKit

/// A MeshCore group channel the user has joined in classic mode.
///
/// MeshCore channels are just a name plus a shared secret: everyone holding
/// the same secret is "in" the channel, and the radio decrypts any traffic it
/// can match. Channel 0 is the well-known public channel and is always
/// present; slots 1…7 are what a companion app gets to configure.
struct MeshChannel: Codable, Identifiable, Equatable {
    var index: UInt8
    var name: String
    /// 16-byte channel PSK.
    var secret: Data
    var joinedAt: Date

    var id: UInt8 { index }

    /// Channel 0 — always joined, no secret to manage.
    static let publicIndex: UInt8 = 0

    /// Thread key used to store this channel's messages locally.
    var threadID: String { MeshChannel.threadID(forIndex: index) }

    static func threadID(forIndex index: UInt8) -> String {
        index == publicIndex ? "mc-public-channel" : "mc-channel-\(index)"
    }

    /// Channel names conventionally start with `#`; accept either form and
    /// display it consistently.
    var displayName: String {
        name.hasPrefix("#") ? name : "#\(name)"
    }

    /// MeshCore derives a channel's secret from its name when you join by
    /// name alone (the common "everyone on #general" case). Hashing the
    /// normalized name gives every device the same 16-byte PSK without
    /// anyone having to exchange key material.
    static func derivedSecret(forName name: String) -> Data {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "#", with: "")
        let digest = SHA256.hash(data: Data("meshcore.channel.\(normalized)".utf8))
        return Data(digest.prefix(16))
    }

    /// Parses a user-supplied secret: 32 hex chars (16 bytes) or base64.
    /// Returns nil when the text isn't a usable key.
    static func parseSecret(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let hex = Data(hexEncoded: trimmed), hex.count == 16 { return hex }
        if let b64 = Data(base64Encoded: trimmed), b64.count == 16 { return b64 }
        if let b64url = Data(base64URLEncoded: trimmed), b64url.count == 16 { return b64url }
        return nil
    }
}

/// The radio has one small set of channel slots (1…7) and *both* modes want
/// them: Fellship maps each room to a slot, and classic mode maps each joined
/// `#channel` to one. They allocate from opposite ends of the same range so
/// the two never silently overwrite each other's configuration.
enum ChannelSlotRegistry {
    static let usable: [UInt8] = [1, 2, 3, 4, 5, 6, 7]
    static let roomSlotsKey = "channelSlots"
    static let channelsKey = "mcJoinedChannels"

    /// Slots currently assigned to Fellship rooms.
    static func roomSlots(defaults: UserDefaults = .standard) -> Set<UInt8> {
        guard let raw = defaults.dictionary(forKey: roomSlotsKey) as? [String: Int] else { return [] }
        return Set(raw.values.map { UInt8(clamping: $0) })
    }

    /// Slots currently assigned to joined classic channels.
    static func classicSlots(defaults: UserDefaults = .standard) -> Set<UInt8> {
        Set(loadChannels(defaults: defaults).map(\.index))
    }

    static func loadChannels(defaults: UserDefaults = .standard) -> [MeshChannel] {
        guard let data = defaults.data(forKey: channelsKey),
              let list = try? JSONDecoder().decode([MeshChannel].self, from: data) else { return [] }
        return list
    }

    static func saveChannels(_ channels: [MeshChannel], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(channels) else { return }
        defaults.set(data, forKey: channelsKey)
    }

    /// Rooms fill from the bottom, channels from the top.
    static func freeRoomSlot(defaults: UserDefaults = .standard) -> UInt8? {
        let taken = roomSlots(defaults: defaults).union(classicSlots(defaults: defaults))
        return usable.first { !taken.contains($0) }
    }

    static func freeChannelSlot(defaults: UserDefaults = .standard) -> UInt8? {
        let taken = roomSlots(defaults: defaults).union(classicSlots(defaults: defaults))
        return usable.reversed().first { !taken.contains($0) }
    }
}
