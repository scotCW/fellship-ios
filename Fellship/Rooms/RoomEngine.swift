import Foundation
import CryptoKit

/// The app's brain: room lifecycle, the activation rule, presence, zone
/// entry/exit detection, chat, and invites. All state lives on this device;
/// all communication goes radio-to-radio through `MeshSession` (spec §1).
@MainActor
final class RoomEngine: ObservableObject {
    // MARK: - Published state

    // Setters are internal (not private) because RoomEngine+Mesh.swift in
    // this module mutates them; views treat them as read-only.
    @Published var rooms: [Room] = []
    @Published var invites: [Invite] = []
    /// roomID → memberID → live presence.
    @Published var presence: [String: [String: MemberPresence]] = [:]
    /// roomID → whether *my* device currently evaluates itself inside.
    @Published var myInside: [String: Bool] = [:]
    /// Radio contacts heard recently (for Nearby + invites).
    @Published var nearbyContacts: [MeshCore.Contact] = []
    /// Bumped whenever stored messages change, so chat views re-query.
    @Published var chatRevision = 0

    // MARK: - Dependencies

    let store: LocalStore
    let settings: AppSettings
    let notifications: NotificationService
    private(set) var session: MeshSession?

    // MARK: - Internals

    var membersCache: [String: [Member]] = [:]
    var channelSlots: [String: UInt8] = [:] // roomID → channel index 1...7
    var pendingAcks: [UInt32: String] = [:] // ackCRC → messageID
    var recentAutoInvites: [String: Date] = [:] // "roomID|radioKey" → sent at
    private var lastBeaconAt = Date.distantPast
    private var eventTask: Task<Void, Never>?
    private var sweepTimer: Timer?
    var seenMessageIDs = Set<String>()
    /// In-flight multi-part chats: messageID → (part index → text).
    var chatParts: [String: [UInt8: String]] = [:]
    var chatPartsStarted: [String: Date] = [:]

    var myIdentityHex: String { CryptoService.identityPublicKeyHex() }
    var myDisplayName: String {
        settings.displayName.isEmpty ? "Me" : settings.displayName
    }

    init(store: LocalStore, settings: AppSettings, notifications: NotificationService) {
        self.store = store
        self.settings = settings
        self.notifications = notifications
        loadFromStore()
        startSweepTimer()
    }

    private func loadFromStore() {
        rooms = (try? store.rooms()) ?? []
        let all = (try? store.invites()) ?? []
        var live: [Invite] = []
        for invite in all {
            // Any invite that never completed goes stale after a week — drop
            // it instead of resurfacing forever.
            let stale = Date().timeIntervalSince(invite.createdAt) > 7 * 86_400
            if invite.state == .completed || invite.state == .declined || stale {
                try? store.deleteInvite(invite.id)
            } else {
                live.append(invite)
            }
        }
        invites = live
        for room in rooms {
            membersCache[room.id] = (try? store.members(roomID: room.id)) ?? []
        }
        channelSlots = Self.loadSlots()
        sweepExpiredRooms()
    }

    // MARK: - Members

    func members(of room: Room) -> [Member] {
        membersCache[room.id] ?? []
    }

    private func addMember(_ member: Member, to roomID: String) {
        var list = membersCache[roomID] ?? []
        guard !list.contains(where: { $0.id == member.id }) else { return }
        list.append(member)
        membersCache[roomID] = list
        try? store.saveMember(member, roomID: roomID)
        objectWillChange.send()
    }

    private var selfMember: Member {
        Member(id: myIdentityHex, displayName: myDisplayName,
               radioPublicKey: nil, joinedAt: Date())
    }

    // MARK: - Room lifecycle

    @discardableResult
    func createRoom(name: String, kind: RoomKind, boundary: Boundary?,
                    access: RoomAccess, permanence: Permanence,
                    duration: TimeInterval?, sharesPreciseLocation: Bool) -> Room? {
        var idBytes = Data(count: 16)
        _ = idBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let room = Room(id: idBytes.hexEncoded,
                        name: name,
                        kind: kind,
                        boundary: kind == .geofenced ? boundary : nil,
                        access: access,
                        permanence: permanence,
                        expiresAt: permanence == .temporary ? Date().addingTimeInterval(duration ?? 86_400) : nil,
                        sharesPreciseLocation: sharesPreciseLocation,
                        isMuted: false,
                        createdAt: Date(),
                        creatorID: myIdentityHex)
        let key = CryptoService.generateRoomKey()
        do {
            try CryptoService.storeRoomKey(key, roomID: room.id)
            try store.saveRoom(room)
        } catch {
            CryptoService.deleteRoomKey(roomID: room.id)
            return nil
        }
        rooms.append(room)
        addMember(selfMember, to: room.id)
        Task { await ensureChannel(for: room) }
        return room
    }

    /// Irreversible, as the spec demands: key, history, membership all gone.
    func deleteRoom(_ room: Room) {
        try? store.deleteRoom(room.id)
        rooms.removeAll { $0.id == room.id }
        membersCache[room.id] = nil
        presence[room.id] = nil
        myInside[room.id] = nil
        if let slot = channelSlots.removeValue(forKey: room.id) {
            Self.persistSlots(channelSlots)
            // Scrub the PSK from the radio so a deleted room really is gone.
            Task { [session] in
                try? await session?.setChannel(index: slot, name: "", secret: Data(repeating: 0, count: 16))
            }
        }
    }

    func updateRoom(_ room: Room) {
        try? store.saveRoom(room)
        if let index = rooms.firstIndex(where: { $0.id == room.id }) {
            rooms[index] = room
        }
    }

    private func sweepExpiredRooms() {
        for room in rooms where room.isExpired {
            deleteRoom(room)
            notifications.post(.roomExpired(roomName: room.name), threadID: room.id)
        }
    }

    private func startSweepTimer() {
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sweepExpiredRooms()
                self?.sweepStalePresence()
            }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        sweepTimer = t
    }

    // MARK: - Activation rule (spec §3.1)

    /// A room is active iff at least one member's device currently reports
    /// being inside the boundary (geofenced) or reachable (range-based).
    /// My own device counts — for range-based rooms, being on the mesh at
    /// all makes me the room's reach, which is also what lets a brand-new
    /// public range room bootstrap its second member via auto-invite.
    func isActive(_ room: Room) -> Bool {
        activeMemberCount(room) > 0
    }

    /// Members currently inside/in-range, judged by fresh presence.
    func activeMemberCount(_ room: Room) -> Int {
        let interval = settings.updateIntervalSeconds
        let fresh = (presence[room.id] ?? [:]).values.filter {
            $0.isFresh(interval: interval) && $0.isInside
        }
        let mine: Int
        switch room.kind {
        case .geofenced: mine = myInside[room.id] == true ? 1 : 0
        case .rangeBased: mine = session != nil ? 1 : 0
        }
        return fresh.count + mine
    }

    func presenceList(for room: Room) -> [MemberPresence] {
        (presence[room.id] ?? [:]).values.sorted { $0.lastHeard > $1.lastHeard }
    }

    private func sweepStalePresence() {
        let interval = settings.updateIntervalSeconds
        var changed = false
        for (roomID, roomPresence) in presence {
            guard let room = rooms.first(where: { $0.id == roomID }) else { continue }
            for (memberID, p) in roomPresence where p.isInside && !p.isFresh(interval: interval) {
                presence[roomID]?[memberID]?.isInside = false
                changed = true
                if room.kind == .rangeBased, !room.isMuted {
                    let name = membersCache[roomID]?.first { $0.id == memberID }?.displayName ?? "A member"
                    notifications.post(.presenceLeft(memberName: name, roomName: room.name), threadID: roomID)
                }
            }
        }
        if changed { objectWillChange.send() }
    }

    // MARK: - Location tick → presence + zone detection

    /// Called once per global interval with the shared GPS read (spec §4's
    /// piggyback rule: one read feeds every room's broadcast).
    func handleTick(fix: LocationFix?) async {
        sweepExpiredRooms()

        if let fix {
            evaluateZones(at: fix.coordinate)
        }
        await broadcastPresence(fix: fix)
        await sendOpenToInviteBeaconIfNeeded(fix: fix)
    }

    /// Checks my own position against every geofenced boundary I hold
    /// (spec §3.1 — each device evaluates itself).
    private func evaluateZones(at coordinate: Coordinate) {
        for room in rooms {
            guard room.kind == .geofenced, let boundary = room.boundary else { continue }
            let inside = GeoMath.contains(boundary, point: coordinate)
            let wasInside = myInside[room.id]
            myInside[room.id] = inside
            guard let wasInside, wasInside != inside else { continue }

            // Record locally…
            let event = RoomMessage(id: UUID().uuidString,
                                    threadID: room.id,
                                    scope: .room,
                                    senderID: myIdentityHex,
                                    senderName: myDisplayName,
                                    text: inside ? "You entered the zone" : "You left the zone",
                                    sentAt: Date(),
                                    delivery: .sent,
                                    isFromMe: true,
                                    isSystemEvent: true)
            try? store.saveMessage(event)
            chatRevision += 1

            // …and tell the room over the mesh.
            Task { await self.broadcastZoneEvent(room: room, didEnter: inside) }
        }
    }

    // MARK: - Session attachment

    func attach(session: MeshSession) {
        self.session = session
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            let stream = await session.events()
            for await event in stream {
                await self.handleMeshEvent(event)
            }
        }
        Task {
            await self.ensureAllChannels()
            await self.refreshContacts()
        }
    }

    func detachSession() {
        session = nil
        eventTask?.cancel()
        eventTask = nil
    }

    func refreshContacts() async {
        guard let session else { return }
        if let contacts = try? await session.getContacts() {
            nearbyContacts = contacts.sorted { $0.lastAdvert > $1.lastAdvert }
        }
    }

    // MARK: - Channel slots (rooms ↔ radio channels)

    /// MeshCore companion firmware exposes a small set of channel slots;
    /// slot 0 is the public channel and is left untouched. Fellship maps each
    /// room to a slot 1…7, most-recently-created first when oversubscribed.
    private static func loadSlots() -> [String: UInt8] {
        (UserDefaults.standard.dictionary(forKey: "channelSlots") as? [String: Int])?
            .mapValues { UInt8(clamping: $0) } ?? [:]
    }

    private static func persistSlots(_ slots: [String: UInt8]) {
        UserDefaults.standard.set(slots.mapValues(Int.init), forKey: "channelSlots")
    }

    private func ensureAllChannels() async {
        for room in rooms.sorted(by: { $0.createdAt > $1.createdAt }) {
            await ensureChannel(for: room)
        }
    }

    func channelSlot(for roomID: String) -> UInt8? {
        channelSlots[roomID]
    }

    func ensureChannel(for room: Room) async {
        guard let session else { return }
        guard let key = CryptoService.roomKey(for: room.id) else { return }
        if let existing = channelSlots[room.id] {
            try? await session.setChannel(index: existing,
                                          name: "fs-\(room.id.prefix(8))",
                                          secret: CryptoService.channelPSK(roomKey: key))
            return
        }
        let used = Set(channelSlots.values)
        var slot: UInt8? = (1...7).first { !used.contains(UInt8($0)) }.map(UInt8.init)
        if slot == nil {
            // Oversubscribed: evict the slot belonging to the oldest room.
            let byAge = rooms.sorted { $0.createdAt < $1.createdAt }
            if let victim = byAge.first(where: { channelSlots[$0.id] != nil && $0.id != room.id }) {
                slot = channelSlots.removeValue(forKey: victim.id)
            }
        }
        guard let slot else { return }
        channelSlots[room.id] = slot
        Self.persistSlots(channelSlots)
        try? await session.setChannel(index: slot,
                                      name: "fs-\(room.id.prefix(8))",
                                      secret: CryptoService.channelPSK(roomKey: key))
    }

    // MARK: - Outgoing broadcasts

    /// Presence for every room, from the one shared fix. Whether coordinates
    /// are included is decided *here*, per room, before anything is
    /// transmitted (spec §3.4).
    private func broadcastPresence(fix: LocationFix?) async {
        guard let session else { return }
        for room in rooms {
            guard let key = CryptoService.roomKey(for: room.id),
                  let slot = channelSlots[room.id] else { continue }

            let inside: Bool
            switch room.kind {
            case .geofenced: inside = myInside[room.id] ?? false
            case .rangeBased: inside = true // reachable = present
            }

            let presencePayload = FellshipEnvelope.Presence(
                memberID: myIdentityHex,
                isInside: inside,
                coordinate: room.sharesPreciseLocation ? fix?.coordinate : nil,
                sentAt: Date())
            guard let text = try? FellshipEnvelope.sealRoomPayload(.presence(presencePayload),
                                                                   roomID: room.id, roomKey: key) else { continue }
            _ = try? await session.sendChannelText(text, channelIndex: slot)
        }
    }

    private func broadcastZoneEvent(room: Room, didEnter: Bool) async {
        guard let session,
              let key = CryptoService.roomKey(for: room.id),
              let slot = channelSlots[room.id] else { return }
        let event = FellshipEnvelope.ZoneEvent(memberID: myIdentityHex,
                                               didEnter: didEnter,
                                               sentAt: Date())
        if let text = try? FellshipEnvelope.sealRoomPayload(.zoneEvent(event),
                                                            roomID: room.id, roomKey: key) {
            _ = try? await session.sendChannelText(text, channelIndex: slot)
        }
    }

    /// "Open to invite" beacon (spec §3.3): a stock flood advert carrying the
    /// radio's advertised position — piggybacked on the location tick, never
    /// on its own schedule, and never more often than once a minute for mesh
    /// politeness.
    private func sendOpenToInviteBeaconIfNeeded(fix: LocationFix?) async {
        guard settings.publicRoomAlerts, let session else { return }
        guard Date().timeIntervalSince(lastBeaconAt) >= max(settings.updateIntervalSeconds, 60) else { return }
        lastBeaconAt = Date()
        if let fix, fix.source == .phone {
            // Radio has no usable GPS; push the phone position into the
            // radio's advert so the beacon carries a location. The advert is
            // an unencrypted, mesh-wide flood, so we deliberately coarsen the
            // coordinate — public-room discovery only needs the neighborhood,
            // and the app must never volunteer the exact point here.
            try? await session.setAdvertPosition(fix.coordinate.coarsened(toMeters: 250))
        }
        try? await session.sendSelfAdvert(flood: true)
    }

    // MARK: - Messaging (spec §5)

    /// Text per chat part, chosen so every sealed frame stays well inside a
    /// stock MeshCore text payload.
    static let chatPartLength = 48

    func sendRoomMessage(_ room: Room, text: String, zoneOnly: Bool) async {
        // 6 random bytes, hex — this exact ID travels on the wire so all
        // members dedupe (and reassemble parts) consistently.
        var idBytes = Data(count: 6)
        _ = idBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 6, $0.baseAddress!) }
        let messageID = idBytes.hexEncoded
        var message = RoomMessage(id: messageID,
                                  threadID: room.id,
                                  scope: zoneOnly ? .zone : .room,
                                  senderID: myIdentityHex,
                                  senderName: myDisplayName,
                                  text: text,
                                  sentAt: Date(),
                                  delivery: .timedOut,
                                  isFromMe: true)
        defer {
            try? store.saveMessage(message)
            seenMessageIDs.insert(messageID)
            chatRevision += 1
        }
        guard let session,
              let key = CryptoService.roomKey(for: room.id),
              let slot = channelSlots[room.id] else { return }

        // Split long texts across LoRa-sized parts sharing the message ID.
        let characters = Array(text)
        let parts: [String] = stride(from: 0, to: max(1, characters.count), by: Self.chatPartLength).map {
            String(characters[$0..<min($0 + Self.chatPartLength, characters.count)])
        }
        let partCount = UInt8(clamping: parts.count)

        var allSent = true
        var lastAck: UInt32?
        for (index, partText) in parts.enumerated() {
            let chat = FellshipEnvelope.Chat(messageID: messageID,
                                             memberID: myIdentityHex,
                                             zoneScoped: zoneOnly,
                                             text: partText,
                                             sentAt: message.sentAt,
                                             part: UInt8(index),
                                             partCount: partCount)
            guard let sealed = try? FellshipEnvelope.sealRoomPayload(.chat(chat),
                                                                     roomID: room.id, roomKey: key) else {
                allSent = false
                break
            }
            do {
                let result = try await session.sendChannelText(sealed, channelIndex: slot)
                if let result, result.expectedAckCRC != 0 { lastAck = result.expectedAckCRC }
            } catch {
                allSent = false
                break
            }
        }
        message.delivery = allSent ? .sent : .timedOut
        if allSent, let lastAck {
            pendingAcks[lastAck] = messageID
        }
    }

    func sendDirectMessage(toRadioKeyHex peerHex: String, peerName: String, text: String) async {
        let messageID = UUID().uuidString
        var message = RoomMessage(id: messageID,
                                  threadID: peerHex,
                                  scope: .direct,
                                  senderID: myIdentityHex,
                                  senderName: myDisplayName,
                                  text: text,
                                  sentAt: Date(),
                                  delivery: .timedOut,
                                  isFromMe: true)
        defer {
            try? store.saveMessage(message)
            chatRevision += 1
        }
        guard let session, let peerKey = Data(hexEncoded: peerHex) else { return }
        if let result = try? await session.sendDirectText(text, to: peerKey) {
            message.delivery = .sent
            if result.expectedAckCRC != 0 {
                pendingAcks[result.expectedAckCRC] = messageID
                scheduleAckTimeout(messageID: messageID, ackCRC: result.expectedAckCRC,
                                   after: TimeInterval(result.estimatedTimeoutMillis) / 1000)
            }
        }
    }

    /// Resends a direct message that never got a mesh ack (flood retry).
    func retryDirectMessage(_ message: RoomMessage) async {
        guard message.scope == .direct, message.isFromMe,
              let session, let peerKey = Data(hexEncoded: message.threadID) else { return }
        updateDelivery(messageID: message.id, threadHint: message.threadID, to: .sent)
        do {
            let result = try await session.sendDirectText(message.text, to: peerKey, attempt: 1)
            if result.expectedAckCRC != 0 {
                pendingAcks[result.expectedAckCRC] = message.id
                scheduleAckTimeout(messageID: message.id, ackCRC: result.expectedAckCRC,
                                   after: TimeInterval(result.estimatedTimeoutMillis) / 1000)
            }
        } catch {
            updateDelivery(messageID: message.id, threadHint: message.threadID, to: .timedOut)
        }
    }

    private func scheduleAckTimeout(messageID: String, ackCRC: UInt32, after seconds: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 5) * 1_000_000_000))
            guard let self else { return }
            if self.pendingAcks[ackCRC] == messageID {
                self.pendingAcks[ackCRC] = nil
                self.updateDelivery(messageID: messageID, threadHint: nil, to: .timedOut)
            }
        }
    }

    func updateDelivery(messageID: String, threadHint: String?, to state: DeliveryState) {
        // Message rows are keyed by ID; re-save with the new state.
        let threads: [String]
        if let threadHint {
            threads = [threadHint]
        } else {
            threads = rooms.map(\.id) + ((try? store.directThreadIDs()) ?? [])
        }
        for thread in threads {
            guard var message = (try? store.messages(threadID: thread))?.first(where: { $0.id == messageID }) else { continue }
            // Never downgrade: once the mesh confirmed it, a late local
            // timeout must not mark the message failed.
            if message.delivery == .heard && state == .timedOut { return }
            message.delivery = state
            try? store.saveMessage(message)
            chatRevision += 1
            return
        }
    }

    func messages(threadID: String) -> [RoomMessage] {
        (try? store.messages(threadID: threadID)) ?? []
    }

    func directThreads() -> [(peerHex: String, name: String, last: RoomMessage?)] {
        let ids = (try? store.directThreadIDs()) ?? []
        return ids.map { id in
            let name = nearbyContacts.first { $0.publicKey.hexEncoded == id }?.name
                ?? knownMemberName(radioKeyHex: id)
                ?? "Radio \(id.prefix(8))"
            return (id, name, messages(threadID: id).last)
        }
    }

    private func knownMemberName(radioKeyHex: String) -> String? {
        for members in membersCache.values {
            if let member = members.first(where: { $0.radioPublicKey == radioKeyHex }) {
                return member.displayName
            }
        }
        return nil
    }
}
