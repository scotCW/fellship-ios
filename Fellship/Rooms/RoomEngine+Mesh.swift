import Foundation
import CryptoKit

// MARK: - Incoming mesh traffic, invites, QR joining, demo seeding.

extension RoomEngine {
    private static let directAssembler = FellshipEnvelope.DirectAssembler()

    func handleMeshEvent(_ event: MeshEvent) async {
        switch event {
        case .channelMessage(let message):
            handleChannelText(message.text)
        case .contactMessage(let message, let sender):
            await handleDirectText(message.text, sender: sender)
        case .advertHeard(let contact):
            upsertNearby(contact)
            await autoInviteIfEligible(contact: contact)
        case .sendConfirmed(let ackCRC, _):
            if let messageID = pendingAcks.removeValue(forKey: ackCRC) {
                updateDelivery(messageID: messageID, threadHint: nil, to: .heard)
            }
        case .stateChanged, .selfInfoUpdated, .batteryUpdated, .deviceInfoUpdated:
            break // owned by AppState
        }
    }

    private func upsertNearby(_ contact: MeshCore.Contact) {
        var list = nearbyContacts.filter { $0.publicKey != contact.publicKey }
        list.insert(contact, at: 0)
        nearbyContacts = list.sorted { $0.lastAdvert > $1.lastAdvert }
    }

    // MARK: - Wire member-ID resolution

    /// Wire payloads carry an 8-byte identity prefix. Resolve it to a full
    /// member where possible; otherwise the prefix itself acts as a
    /// provisional ID (full IDs start with it, so upgrades are seamless).
    func resolveMemberID(_ wireID: String, roomID: String) -> String {
        if let member = (membersCache[roomID] ?? []).first(where: { $0.id.hasPrefix(wireID) }) {
            return member.id
        }
        return wireID
    }

    func displayName(forMemberID id: String, roomID: String) -> String {
        if id == myIdentityHex { return myDisplayName }
        if let member = (membersCache[roomID] ?? []).first(where: { $0.id.hasPrefix(id) || id.hasPrefix($0.id) }) {
            return member.displayName
        }
        return "Member \(id.prefix(6))"
    }

    private var myWirePrefixHex: String {
        FellshipEnvelope.wirePrefix(ofMemberID: myIdentityHex).hexEncoded
    }

    // MARK: - Room channel traffic

    func handleChannelText(_ text: String) {
        guard let prefix = FellshipEnvelope.roomIDPrefix(fromText: text),
              let room = rooms.first(where: { $0.id.hasPrefix(prefix) }),
              let key = CryptoService.roomKey(for: room.id),
              let payload = try? FellshipEnvelope.openRoomPayload(text, roomID: room.id, roomKey: key)
        else { return } // not ours / not decryptable — ignore silently

        switch payload {
        case .presence(let p):
            guard !myIdentityHex.hasPrefix(p.memberID) else { return }
            applyPresence(p, in: room)
        case .chat(let chat):
            guard !myIdentityHex.hasPrefix(chat.memberID) else { return }
            applyChat(chat, in: room)
        case .zoneEvent(let event):
            guard !myIdentityHex.hasPrefix(event.memberID) else { return }
            applyZoneEvent(event, in: room)
        case .memberAnnounce(let announce):
            noteMember(announce.member, in: room.id)
        }
    }

    private func applyPresence(_ p: FellshipEnvelope.Presence, in room: Room) {
        let memberID = resolveMemberID(p.memberID, roomID: room.id)
        // Coordinates are honored only if this room shares locations — a
        // belt-and-braces check on top of the sender's broadcast-level
        // enforcement.
        let coordinate = room.sharesPreciseLocation ? p.coordinate : nil
        let previous = presence[room.id]?[memberID]
        presence[room.id, default: [:]][memberID] = MemberPresence(
            memberID: memberID,
            isInside: p.isInside,
            coordinate: coordinate,
            lastHeard: Date())

        // Range-based rooms: fresh presence from someone previously silent
        // means they came into range (spec §3.1B).
        if room.kind == .rangeBased, !room.isMuted {
            let wasFresh = previous?.isFresh(interval: settings.updateIntervalSeconds) ?? false
            if !wasFresh {
                notifications.post(.presenceJoined(memberName: displayName(forMemberID: memberID, roomID: room.id),
                                                   roomName: room.name),
                                   threadID: room.id)
            }
        }
    }

    private func applyChat(_ chat: FellshipEnvelope.Chat, in room: Room) {
        // Zone-scoped delivery (spec §5.2): if I'm not currently in the zone,
        // the message is not for me right now — drop it entirely.
        if chat.zoneScoped {
            let amPresent: Bool
            switch room.kind {
            case .geofenced: amPresent = myInside[room.id] ?? false
            case .rangeBased: amPresent = true // I received it ⇒ I'm in range
            }
            guard amPresent else { return }
        }
        guard !seenMessageIDs.contains(chat.messageID) else { return }

        var chat = chat
        if chat.partCount > 1 {
            // Buffer parts until the set completes; stale partials expire.
            let cutoff = Date().addingTimeInterval(-300)
            for (id, started) in chatPartsStarted where started < cutoff {
                chatParts[id] = nil
                chatPartsStarted[id] = nil
            }
            var parts = chatParts[chat.messageID] ?? [:]
            if parts.isEmpty { chatPartsStarted[chat.messageID] = Date() }
            parts[chat.part] = chat.text
            guard parts.count == Int(chat.partCount) else {
                chatParts[chat.messageID] = parts
                return
            }
            chatParts[chat.messageID] = nil
            chatPartsStarted[chat.messageID] = nil
            chat.text = (0..<chat.partCount).compactMap { parts[$0] }.joined()
        }

        seenMessageIDs.insert(chat.messageID)
        let senderID = resolveMemberID(chat.memberID, roomID: room.id)
        let senderName = displayName(forMemberID: senderID, roomID: room.id)
        let message = RoomMessage(id: chat.messageID,
                                  threadID: room.id,
                                  scope: chat.zoneScoped ? .zone : .room,
                                  senderID: senderID,
                                  senderName: senderName,
                                  text: chat.text,
                                  sentAt: chat.sentAt,
                                  delivery: .received,
                                  isFromMe: false)
        try? store.saveMessage(message)
        chatRevision += 1
        if !room.isMuted {
            notifications.post(.message(senderName: senderName, roomName: room.name,
                                        preview: chat.text), threadID: room.id)
        }
    }

    private func applyZoneEvent(_ event: FellshipEnvelope.ZoneEvent, in room: Room) {
        let memberID = resolveMemberID(event.memberID, roomID: room.id)
        let name = displayName(forMemberID: memberID, roomID: room.id)
        let line = RoomMessage(id: UUID().uuidString,
                               threadID: room.id,
                               scope: .room,
                               senderID: memberID,
                               senderName: name,
                               text: event.didEnter ? "\(name) entered the zone" : "\(name) left the zone",
                               sentAt: event.sentAt,
                               delivery: .received,
                               isFromMe: false,
                               isSystemEvent: true)
        try? store.saveMessage(line)
        chatRevision += 1
        if !room.isMuted {
            notifications.post(event.didEnter
                ? .zoneEntry(memberName: name, roomName: room.name)
                : .zoneExit(memberName: name, roomName: room.name),
                threadID: room.id)
        }
    }

    private func noteMember(_ member: Member, in roomID: String, keepExistingName: Bool = false) {
        var list = (try? store.members(roomID: roomID)) ?? []
        if let index = list.firstIndex(where: { $0.id == member.id }) {
            var updated = list[index]
            if !keepExistingName && !member.displayName.isEmpty {
                updated.displayName = member.displayName
            }
            if updated.radioPublicKey == nil { updated.radioPublicKey = member.radioPublicKey }
            list[index] = updated
            try? store.saveMember(updated, roomID: roomID)
        } else {
            list.append(member)
            try? store.saveMember(member, roomID: roomID)
        }
        membersCache[roomID] = list
        // Migrate any provisional (prefix-keyed) presence to the full ID.
        if var roomPresence = presence[roomID] {
            for (key, value) in roomPresence where member.id.hasPrefix(key) && key != member.id {
                roomPresence[member.id] = MemberPresence(memberID: member.id,
                                                         isInside: value.isInside,
                                                         coordinate: value.coordinate,
                                                         lastHeard: value.lastHeard)
                roomPresence[key] = nil
            }
            presence[roomID] = roomPresence
        }
        objectWillChange.send()
    }

    // MARK: - Direct messages (invites + plain 1:1 chat, spec §5.3)

    func handleDirectText(_ text: String, sender: MeshCore.Contact?) async {
        let senderHex = sender?.publicKey.hexEncoded ?? "unknown"

        if FellshipEnvelope.isDirectEnvelope(text) {
            if let (type, body) = Self.directAssembler.ingest(senderHex: senderHex, text: text) {
                await handleInvitePayload(type: type, body: body, sender: sender)
            }
            return // chunk consumed (or awaiting siblings) — never show raw
        }

        // Plain 1:1 proximity chat.
        guard let sender else { return }
        let message = RoomMessage(id: UUID().uuidString,
                                  threadID: senderHex,
                                  scope: .direct,
                                  senderID: senderHex,
                                  senderName: sender.name,
                                  text: text,
                                  sentAt: Date(),
                                  delivery: .received,
                                  isFromMe: false)
        try? store.saveMessage(message)
        chatRevision += 1
        notifications.post(.message(senderName: sender.name, roomName: nil, preview: text),
                           threadID: senderHex)
    }

    private func handleInvitePayload(type: FellshipEnvelope.PayloadType, body: Data,
                                     sender: MeshCore.Contact?) async {
        switch type {
        case .inviteOffer:
            guard let offer = try? FellshipEnvelope.decodeDirectPayload(FellshipEnvelope.InviteOffer.self, from: body) else { return }
            // Already a member, or already holding an invite for this room? Ignore.
            guard !rooms.contains(where: { $0.id == offer.roomID }),
                  !invites.contains(where: { $0.roomID == offer.roomID && $0.state == .received }) else { return }
            guard let sender else { return }
            let invite = Invite(id: offer.inviteID,
                                roomID: offer.roomID,
                                roomName: offer.roomName,
                                roomKind: offer.roomKind,
                                access: offer.access,
                                peerRadioKey: sender.publicKey.hexEncoded,
                                peerIdentityKey: offer.inviterIdentityKey,
                                peerName: offer.inviterName,
                                state: .received,
                                isOutgoing: false,
                                isAutomatic: offer.isAutomatic,
                                createdAt: Date())
            invites.append(invite)
            try? store.saveInvite(invite)
            notifications.post(.inviteReceived(roomName: offer.roomName,
                                               inviterName: offer.inviterName,
                                               automatic: offer.isAutomatic),
                               threadID: offer.roomID)

        case .inviteAccept:
            guard let accept = try? FellshipEnvelope.decodeDirectPayload(FellshipEnvelope.InviteAccept.self, from: body),
                  let room = rooms.first(where: { $0.id == accept.roomID }) else { return }
            await deliverRoomKey(room: room, accept: accept, sender: sender)

        case .roomKeyDelivery:
            guard let delivery = try? FellshipEnvelope.decodeDirectPayload(FellshipEnvelope.RoomKeyDelivery.self, from: body) else { return }
            completeJoin(delivery: delivery)

        default:
            break
        }
    }

    /// Sends a chunked direct payload, one LoRa-sized frame at a time.
    private func sendDirectPayload<T: Encodable>(_ payload: T, type: FellshipEnvelope.PayloadType,
                                                 to radioKey: Data) async -> Bool {
        guard let session,
              let chunks = try? FellshipEnvelope.directChunks(payload, type: type) else { return false }
        for chunk in chunks {
            guard (try? await session.sendDirectText(chunk, to: radioKey)) != nil else { return false }
        }
        return true
    }

    // MARK: - Invite flow

    /// Manual invite from the member picker (private and public rooms alike).
    func sendInvite(room: Room, to contact: MeshCore.Contact, automatic: Bool = false) async {
        let invite = Invite(id: UUID().uuidString,
                            roomID: room.id,
                            roomName: room.name,
                            roomKind: room.kind,
                            access: room.access,
                            peerRadioKey: contact.publicKey.hexEncoded,
                            peerIdentityKey: nil,
                            peerName: contact.name,
                            state: .offered,
                            isOutgoing: true,
                            isAutomatic: automatic,
                            createdAt: Date())
        let offer = FellshipEnvelope.InviteOffer(inviteID: invite.id,
                                                 roomID: room.id,
                                                 roomName: room.name,
                                                 roomKind: room.kind,
                                                 access: room.access,
                                                 inviterIdentityKey: myIdentityHex,
                                                 inviterName: myDisplayName,
                                                 isAutomatic: automatic)
        if await sendDirectPayload(offer, type: .inviteOffer, to: contact.publicKey) {
            invites.append(invite)
            try? store.saveInvite(invite)
        }
    }

    func acceptInvite(_ invite: Invite) async {
        guard let peerKey = Data(hexEncoded: invite.peerRadioKey) else { return }
        let accept = FellshipEnvelope.InviteAccept(inviteID: invite.id,
                                                   roomID: invite.roomID,
                                                   inviteeIdentityKey: myIdentityHex,
                                                   inviteeName: myDisplayName)
        if await sendDirectPayload(accept, type: .inviteAccept, to: peerKey) {
            setInviteState(invite.id, to: .accepted)
        }
    }

    func declineInvite(_ invite: Invite) {
        invites.removeAll { $0.id == invite.id }
        try? store.deleteInvite(invite.id)
    }

    private func setInviteState(_ inviteID: String, to state: Invite.State) {
        guard let index = invites.firstIndex(where: { $0.id == inviteID }) else { return }
        invites[index].state = state
        try? store.saveInvite(invites[index])
    }

    /// Inviter side: the invitee accepted — seal the manifest (room, members,
    /// key) to their identity key and send it (spec §6 key distribution).
    private func deliverRoomKey(room: Room, accept: FellshipEnvelope.InviteAccept,
                                sender: MeshCore.Contact?) async {
        guard let session,
              let key = CryptoService.roomKey(for: room.id),
              let inviteeKeyData = Data(hexEncoded: accept.inviteeIdentityKey),
              let inviteeKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: inviteeKeyData)
        else { return }

        var manifestMembers = (try? store.members(roomID: room.id)) ?? []
        let newMember = Member(id: accept.inviteeIdentityKey,
                               displayName: accept.inviteeName,
                               radioPublicKey: sender?.publicKey.hexEncoded,
                               joinedAt: Date())
        if !manifestMembers.contains(where: { $0.id == newMember.id }) {
            manifestMembers.append(newMember)
        }

        let manifest = FellshipEnvelope.RoomManifest(room: room,
                                                     members: manifestMembers,
                                                     roomKeyData: key.dataRepresentation)
        let recipientRadioKey = sender?.publicKey
            ?? invites.first(where: { $0.id == accept.inviteID }).flatMap { Data(hexEncoded: $0.peerRadioKey) }
        guard let manifestData = try? FellshipEnvelope.encodeManifest(manifest),
              let sealed = try? CryptoService.sealBox(manifestData, recipientPublicKey: inviteeKey),
              let recipientRadioKey
        else { return }

        let delivery = FellshipEnvelope.RoomKeyDelivery(inviteID: accept.inviteID,
                                                        roomID: room.id,
                                                        sealedManifest: sealed)
        if await sendDirectPayload(delivery, type: .roomKeyDelivery, to: recipientRadioKey) {
            noteMember(newMember, in: room.id)
            invites.removeAll { $0.id == accept.inviteID }
            try? store.deleteInvite(accept.inviteID)

            // Tell the rest of the room about the newcomer.
            if let slot = channelSlot(for: room.id),
               let announceText = try? FellshipEnvelope.sealRoomPayload(
                    .memberAnnounce(FellshipEnvelope.MemberAnnounce(member: newMember)),
                    roomID: room.id, roomKey: key) {
                _ = try? await session.sendChannelText(announceText, channelIndex: slot)
            }
        }
    }

    /// Invitee side: the sealed manifest arrived — decrypt, store, join.
    private func completeJoin(delivery: FellshipEnvelope.RoomKeyDelivery) {
        guard let manifestData = try? CryptoService.openBox(delivery.sealedManifest,
                                                            identity: CryptoService.identity()),
              let manifest = try? FellshipEnvelope.decodeManifest(manifestData) else { return }
        joinRoom(manifest: manifest)
        invites.removeAll { $0.id == delivery.inviteID }
        try? store.deleteInvite(delivery.inviteID)
    }

    func joinRoom(manifest: FellshipEnvelope.RoomManifest) {
        guard !rooms.contains(where: { $0.id == manifest.room.id }) else { return }
        let roomKey = SymmetricKey(data: manifest.roomKeyData)
        do {
            try CryptoService.storeRoomKey(roomKey, roomID: manifest.room.id)
            try store.saveRoom(manifest.room)
        } catch { return }
        rooms.append(manifest.room)
        var allMembers = manifest.members
        let me = Member(id: myIdentityHex, displayName: myDisplayName,
                        radioPublicKey: nil, joinedAt: Date())
        if !allMembers.contains(where: { $0.id == me.id }) {
            allMembers.append(me)
        }
        for member in allMembers {
            try? store.saveMember(member, roomID: manifest.room.id)
        }
        membersCache[manifest.room.id] = allMembers
        Task {
            await self.ensureChannel(for: manifest.room)
            // Introduce myself on the room channel so other members learn my
            // name and identity (essential after QR joins, where the inviter
            // never announces me).
            await self.announceSelf(in: manifest.room)
        }
    }

    func announceSelf(in room: Room) async {
        guard let session,
              let key = CryptoService.roomKey(for: room.id),
              let slot = channelSlot(for: room.id) else { return }
        let me = Member(id: myIdentityHex, displayName: myDisplayName,
                        radioPublicKey: nil, joinedAt: Date())
        if let text = try? FellshipEnvelope.sealRoomPayload(
                .memberAnnounce(FellshipEnvelope.MemberAnnounce(member: me)),
                roomID: room.id, roomKey: key) {
            _ = try? await session.sendChannelText(text, channelIndex: slot)
        }
    }

    // MARK: - Public-room auto-invite (spec §3.3)

    /// Fired when an advert (someone's "open to invite" beacon) is heard.
    func autoInviteIfEligible(contact: MeshCore.Contact) async {
        for room in rooms where room.access == .publicRoom {
            // The activation rule gates discovery: an empty room has nobody
            // listening, so nobody gets invited (spec §3.1).
            guard isActive(room) else { continue }
            // Skip radios that already belong to a member.
            let members = (try? store.members(roomID: room.id)) ?? []
            let contactHex = contact.publicKey.hexEncoded
            guard !members.contains(where: { $0.radioPublicKey == contactHex }) else { continue }
            // Skip anything we invited recently.
            let rateKey = "\(room.id)|\(contactHex)"
            if let last = recentAutoInvites[rateKey], Date().timeIntervalSince(last) < 1800 { continue }

            let eligible: Bool
            switch room.kind {
            case .geofenced:
                guard let boundary = room.boundary, contact.coordinate.isPlausible else { continue }
                eligible = GeoMath.contains(boundary, point: contact.coordinate)
            case .rangeBased:
                eligible = true // hearing the advert *is* being in range
            }
            guard eligible else { continue }

            recentAutoInvites[rateKey] = Date()
            await sendInvite(room: room, to: contact, automatic: true)
        }
    }

    // MARK: - QR invites (face-to-face joining, no mesh required)

    private static let qrPrefix = "FSQR1:"

    /// The full room credential package as a QR string. Anyone who scans this
    /// joins the room — the QR code itself is the trust boundary, which is
    /// exactly right for handing an invite to someone standing next to you.
    func makeQRPayload(room: Room) -> String? {
        guard let key = CryptoService.roomKey(for: room.id) else { return nil }
        // Cap the embedded member list to keep the QR scannable; the rest of
        // the roster arrives via presence and announces.
        let members = ((try? store.members(roomID: room.id)) ?? [])
            .sorted { $0.joinedAt > $1.joinedAt }
            .prefix(12)
        let manifest = FellshipEnvelope.RoomManifest(room: room,
                                                     members: Array(members),
                                                     roomKeyData: key.dataRepresentation)
        guard let data = try? FellshipEnvelope.encodeManifest(manifest) else { return nil }
        return Self.qrPrefix + data.base64URLEncoded
    }

    /// Returns the joined room name, or nil if the payload wasn't a Fellship QR.
    @discardableResult
    func joinFromQRPayload(_ payload: String) -> String? {
        guard payload.hasPrefix(Self.qrPrefix),
              let data = Data(base64URLEncoded: String(payload.dropFirst(Self.qrPrefix.count))),
              let manifest = try? FellshipEnvelope.decodeManifest(data) else { return nil }
        joinRoom(manifest: manifest)
        return manifest.room.name
    }

    // MARK: - Demo seeding

    /// First run of demo mode: create the demo room locally so the simulated
    /// peers' traffic decrypts.
    func seedDemoRoomIfNeeded() {
        guard !rooms.contains(where: { $0.id == DemoWorld.roomID }) else { return }
        let manifest = FellshipEnvelope.RoomManifest(
            room: DemoWorld.demoRoom(),
            members: SimPeer.all.map(\.member),
            roomKeyData: DemoWorld.roomKey.dataRepresentation)
        joinRoom(manifest: manifest)
    }

    /// Tears down demo artifacts when demo mode is switched off: demo rooms,
    /// demo invites, and direct-message threads with the scripted peers.
    func removeDemoRooms() {
        for room in rooms where room.id == DemoWorld.roomID || room.id == DemoWorld.publicRoomID {
            deleteRoom(room)
        }
        for invite in invites where invite.roomID == DemoWorld.publicRoomID {
            try? store.deleteInvite(invite.id)
        }
        invites.removeAll { $0.roomID == DemoWorld.publicRoomID }
        for peer in SimPeer.all {
            try? store.deleteThread(peer.radioPublicKey.hexEncoded)
        }
        nearbyContacts.removeAll()
        chatRevision += 1
    }
}
