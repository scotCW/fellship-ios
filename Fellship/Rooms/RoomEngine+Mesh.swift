import Foundation
import CryptoKit

// MARK: - Incoming mesh traffic, invites, QR joining, demo seeding.

extension RoomEngine {
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
            break // owned by AppState / RadioViewModel
        }
    }

    private func upsertNearby(_ contact: MeshCore.Contact) {
        var list = nearbyContacts.filter { $0.publicKey != contact.publicKey }
        list.insert(contact, at: 0)
        nearbyContacts = list.sorted { $0.lastAdvert > $1.lastAdvert }
    }

    // MARK: - Room channel traffic

    func handleChannelText(_ text: String) {
        guard let prefix = FellshipEnvelope.roomIDPrefix(fromText: text),
              let room = rooms.first(where: { $0.id.hasPrefix(prefix) }),
              let key = CryptoService.roomKey(for: room.id),
              let (type, body) = try? FellshipEnvelope.openRoomText(text, roomID: room.id, roomKey: key)
        else { return } // not ours / not decryptable — ignore silently

        switch type {
        case .presence:
            guard let p = try? FellshipEnvelope.decodeBody(FellshipEnvelope.Presence.self, from: body),
                  p.memberID != myIdentityHex else { return }
            applyPresence(p, in: room)
        case .chat, .zoneChat:
            guard let chat = try? FellshipEnvelope.decodeBody(FellshipEnvelope.Chat.self, from: body),
                  chat.memberID != myIdentityHex else { return }
            applyChat(chat, zoneScoped: type == .zoneChat, in: room)
        case .zoneEvent:
            guard let event = try? FellshipEnvelope.decodeBody(FellshipEnvelope.ZoneEvent.self, from: body),
                  event.memberID != myIdentityHex else { return }
            applyZoneEvent(event, in: room)
        case .memberAnnounce:
            guard let announce = try? FellshipEnvelope.decodeBody(FellshipEnvelope.MemberAnnounce.self, from: body) else { return }
            noteMember(announce.member, in: room.id)
        case .inviteOffer, .inviteAccept, .roomKeyDelivery:
            break // invite payloads only travel over direct messages
        }
    }

    private func applyPresence(_ p: FellshipEnvelope.Presence, in room: Room) {
        // A presence packet's coordinates are honored only if this room
        // shares locations — a belt-and-braces check on top of the sender's
        // own broadcast-level enforcement.
        let coordinate = room.sharesPreciseLocation ? p.coordinate : nil
        let previous = presence[room.id]?[p.memberID]
        presence[room.id, default: [:]][p.memberID] = MemberPresence(
            memberID: p.memberID,
            isInside: p.isInside,
            coordinate: coordinate,
            lastHeard: Date())

        noteMember(Member(id: p.memberID, displayName: p.name,
                          radioPublicKey: nil, joinedAt: Date()),
                   in: room.id, keepExistingName: true)

        // Range-based rooms: fresh presence from someone previously silent
        // means they came into range (spec §3.1B).
        if room.kind == .rangeBased, !room.isMuted {
            let wasFresh = previous?.isFresh(interval: settings.updateIntervalSeconds) ?? false
            if !wasFresh {
                notifications.post(.presenceJoined(memberName: p.name, roomName: room.name), threadID: room.id)
            }
        }
    }

    private func applyChat(_ chat: FellshipEnvelope.Chat, zoneScoped: Bool, in room: Room) {
        // Zone-scoped delivery (spec §5.2): if I'm not currently in the zone,
        // the message is not for me right now — drop it entirely.
        if zoneScoped {
            let amPresent: Bool
            switch room.kind {
            case .geofenced: amPresent = myInside[room.id] ?? false
            case .rangeBased: amPresent = true // I received it ⇒ I'm in range
            }
            guard amPresent else { return }
        }
        guard !seenMessageIDs.contains(chat.messageID) else { return }
        seenMessageIDs.insert(chat.messageID)
        let message = RoomMessage(id: chat.messageID,
                                  threadID: room.id,
                                  scope: zoneScoped ? .zone : .room,
                                  senderID: chat.memberID,
                                  senderName: chat.name,
                                  text: chat.text,
                                  sentAt: chat.sentAt,
                                  delivery: .received,
                                  isFromMe: false)
        try? store.saveMessage(message)
        chatRevision += 1
        if !room.isMuted {
            notifications.post(.message(senderName: chat.name, roomName: room.name,
                                        preview: chat.text), threadID: room.id)
        }
    }

    private func applyZoneEvent(_ event: FellshipEnvelope.ZoneEvent, in room: Room) {
        let line = RoomMessage(id: UUID().uuidString,
                               threadID: room.id,
                               scope: .room,
                               senderID: event.memberID,
                               senderName: event.name,
                               text: event.didEnter ? "\(event.name) entered the zone" : "\(event.name) left the zone",
                               sentAt: event.sentAt,
                               delivery: .received,
                               isFromMe: false,
                               isSystemEvent: true)
        try? store.saveMessage(line)
        chatRevision += 1
        if !room.isMuted {
            notifications.post(event.didEnter
                ? .zoneEntry(memberName: event.name, roomName: room.name)
                : .zoneExit(memberName: event.name, roomName: room.name),
                threadID: room.id)
        }
    }

    private func noteMember(_ member: Member, in roomID: String, keepExistingName: Bool = false) {
        var list = (try? store.members(roomID: roomID)) ?? []
        if let index = list.firstIndex(where: { $0.id == member.id }) {
            if !keepExistingName || list[index].displayName.isEmpty {
                var updated = list[index]
                updated.displayName = member.displayName
                if updated.radioPublicKey == nil { updated.radioPublicKey = member.radioPublicKey }
                list[index] = updated
                try? store.saveMember(updated, roomID: roomID)
            }
        } else {
            list.append(member)
            try? store.saveMember(member, roomID: roomID)
        }
        membersCache[roomID] = list
        objectWillChange.send()
    }

    // MARK: - Direct messages (invites + plain 1:1 chat, spec §5.3)

    func handleDirectText(_ text: String, sender: MeshCore.Contact?) async {
        if let (type, body) = try? FellshipEnvelope.openDirectText(text) {
            await handleInvitePayload(type: type, body: body, sender: sender)
            return
        }
        // Plain 1:1 proximity chat.
        guard let sender else { return }
        let peerHex = sender.publicKey.hexEncoded
        let message = RoomMessage(id: UUID().uuidString,
                                  threadID: peerHex,
                                  scope: .direct,
                                  senderID: peerHex,
                                  senderName: sender.name,
                                  text: text,
                                  sentAt: Date(),
                                  delivery: .received,
                                  isFromMe: false)
        try? store.saveMessage(message)
        chatRevision += 1
        notifications.post(.message(senderName: sender.name, roomName: nil, preview: text),
                           threadID: peerHex)
    }

    private func handleInvitePayload(type: FellshipEnvelope.PayloadType, body: Data,
                                     sender: MeshCore.Contact?) async {
        switch type {
        case .inviteOffer:
            guard let offer = try? FellshipEnvelope.decodeBody(FellshipEnvelope.InviteOffer.self, from: body) else { return }
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
            guard let accept = try? FellshipEnvelope.decodeBody(FellshipEnvelope.InviteAccept.self, from: body),
                  let room = rooms.first(where: { $0.id == accept.roomID }) else { return }
            await deliverRoomKey(room: room, accept: accept, sender: sender)

        case .roomKeyDelivery:
            guard let delivery = try? FellshipEnvelope.decodeBody(FellshipEnvelope.RoomKeyDelivery.self, from: body) else { return }
            completeJoin(delivery: delivery)

        default:
            break
        }
    }

    // MARK: - Invite flow

    /// Manual invite from the member picker (private and public rooms alike).
    func sendInvite(room: Room, to contact: MeshCore.Contact, automatic: Bool = false) async {
        guard let session else { return }
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
        guard let text = try? FellshipEnvelope.sealDirectText(offer, type: .inviteOffer) else { return }
        if (try? await session.sendDirectText(text, to: contact.publicKey)) != nil {
            invites.append(invite)
            try? store.saveInvite(invite)
        }
    }

    func acceptInvite(_ invite: Invite) async {
        guard let session, let peerKey = Data(hexEncoded: invite.peerRadioKey) else { return }
        let accept = FellshipEnvelope.InviteAccept(inviteID: invite.id,
                                                   roomID: invite.roomID,
                                                   inviteeIdentityKey: myIdentityHex,
                                                   inviteeName: myDisplayName)
        guard let text = try? FellshipEnvelope.sealDirectText(accept, type: .inviteAccept) else { return }
        if (try? await session.sendDirectText(text, to: peerKey)) != nil {
            setInviteState(invite.id, to: .accepted)
        }
    }

    func declineInvite(_ invite: Invite) {
        setInviteState(invite.id, to: .declined)
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
        guard let manifestData = try? FellshipEnvelope.encodeManifest(manifest),
              let sealed = try? CryptoService.sealBox(manifestData, recipientPublicKey: inviteeKey),
              let text = try? FellshipEnvelope.sealDirectText(
                FellshipEnvelope.RoomKeyDelivery(inviteID: accept.inviteID,
                                                 roomID: room.id,
                                                 sealedManifest: sealed),
                type: .roomKeyDelivery),
              let recipientRadioKey = sender?.publicKey ?? Data(hexEncoded: invites.first(where: { $0.id == accept.inviteID })?.peerRadioKey ?? "")
        else { return }

        if (try? await session.sendDirectText(text, to: recipientRadioKey)) != nil {
            noteMember(newMember, in: room.id)
            setInviteState(accept.inviteID, to: .completed)
            invites.removeAll { $0.id == accept.inviteID }
            try? store.deleteInvite(accept.inviteID)

            // Tell the rest of the room about the newcomer.
            if let slot = channelSlot(for: room.id),
               let announceText = try? FellshipEnvelope.sealRoomText(
                    FellshipEnvelope.MemberAnnounce(member: newMember),
                    type: .memberAnnounce, roomID: room.id, roomKey: key) {
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
        if !allMembers.contains(where: { $0.id == myIdentityHex }) {
            allMembers.append(Member(id: myIdentityHex, displayName: myDisplayName,
                                     radioPublicKey: nil, joinedAt: Date()))
        }
        for member in allMembers {
            try? store.saveMember(member, roomID: manifest.room.id)
        }
        membersCache[manifest.room.id] = allMembers
        Task { await ensureChannel(for: manifest.room) }
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
        let manifest = FellshipEnvelope.RoomManifest(room: room,
                                                     members: (try? store.members(roomID: room.id)) ?? [],
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

    /// Tears down demo artifacts when demo mode is switched off.
    func removeDemoRooms() {
        for room in rooms where room.id == DemoWorld.roomID || room.id == DemoWorld.publicRoomID {
            deleteRoom(room)
        }
        invites.removeAll { $0.roomID == DemoWorld.publicRoomID }
    }
}

