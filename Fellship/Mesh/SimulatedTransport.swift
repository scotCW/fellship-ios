import Foundation
import CryptoKit

/// Demo-mode constants shared between the simulated radio and the app-side
/// demo seeder. Deterministic so a demo session always looks the same.
enum DemoWorld {
    static let center = Coordinate(latitude: 37.7694, longitude: -122.4862) // Golden Gate Park

    static var roomID: String {
        Data(SHA256.hash(data: Data("fellship.demo.room1.id".utf8))).prefix(16).hexEncoded
    }

    static var roomKey: SymmetricKey {
        SymmetricKey(data: Data(SHA256.hash(data: Data("fellship.demo.room1.key".utf8))))
    }

    static var publicRoomID: String {
        Data(SHA256.hash(data: Data("fellship.demo.room2.id".utf8))).prefix(16).hexEncoded
    }

    static var publicRoomKey: SymmetricKey {
        SymmetricKey(data: Data(SHA256.hash(data: Data("fellship.demo.room2.key".utf8))))
    }

    static func demoRoom() -> Room {
        Room(id: roomID,
             name: "Golden Gate Meetup",
             kind: .geofenced,
             boundary: .circle(center: center, radiusMeters: 700),
             access: .inviteOnly,
             permanence: .temporary,
             expiresAt: Date().addingTimeInterval(60 * 60 * 24),
             sharesPreciseLocation: true,
             isMuted: false,
             createdAt: Date(),
             creatorID: SimPeer.all[0].identityKeyHex)
    }

    static func publicDemoRoom() -> Room {
        Room(id: publicRoomID,
             name: "Ridge Ramble",
             kind: .rangeBased,
             boundary: nil,
             access: .publicRoom,
             permanence: .temporary,
             expiresAt: Date().addingTimeInterval(60 * 60 * 24),
             sharesPreciseLocation: false,
             isMuted: false,
             createdAt: Date(),
             creatorID: SimPeer.all[2].identityKeyHex)
    }
}

/// A scripted virtual member of the demo mesh.
struct SimPeer {
    var name: String
    var radioKeySeed: String
    var identitySeed: String
    /// Orbit parameters around the demo center.
    var orbitRadiusMeters: Double
    var orbitPeriodSeconds: Double
    var phase: Double

    var radioPublicKey: Data {
        Data(SHA256.hash(data: Data(radioKeySeed.utf8)))
    }

    var identityKey: Curve25519.KeyAgreement.PrivateKey {
        // Deterministic private key from a seed — demo only, obviously.
        try! Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(SHA256.hash(data: Data(identitySeed.utf8))))
    }

    var identityKeyHex: String { identityKey.publicKey.rawRepresentation.hexEncoded }

    func position(at time: TimeInterval) -> Coordinate {
        let angle = 2 * .pi * (time / orbitPeriodSeconds) + phase
        let dLat = orbitRadiusMeters / GeoMath.earthRadiusMeters * 180 / .pi
        let dLon = dLat / cos(DemoWorld.center.latitude * .pi / 180)
        return Coordinate(latitude: DemoWorld.center.latitude + dLat * sin(angle),
                          longitude: DemoWorld.center.longitude + dLon * cos(angle))
    }

    var member: Member {
        Member(id: identityKeyHex, displayName: name,
               radioPublicKey: radioPublicKey.hexEncoded, joinedAt: Date())
    }

    static let all: [SimPeer] = [
        // Robin's orbit strays outside the 700 m zone — she generates
        // entry/exit events roughly every four minutes.
        SimPeer(name: "Robin", radioKeySeed: "fellship.demo.peer.robin.radio",
                identitySeed: "fellship.demo.peer.robin.id",
                orbitRadiusMeters: 800, orbitPeriodSeconds: 480, phase: 0),
        SimPeer(name: "Ash", radioKeySeed: "fellship.demo.peer.ash.radio",
                identitySeed: "fellship.demo.peer.ash.id",
                orbitRadiusMeters: 350, orbitPeriodSeconds: 600, phase: 2.1),
        SimPeer(name: "Kai", radioKeySeed: "fellship.demo.peer.kai.radio",
                identitySeed: "fellship.demo.peer.kai.id",
                orbitRadiusMeters: 500, orbitPeriodSeconds: 540, phase: 4.2),
    ]
}

/// A fully simulated MeshCore radio + tiny mesh of scripted peers. Implements
/// the same companion protocol as real firmware, so the entire app stack —
/// session, envelopes, room engine, UI — runs unchanged in demo mode.
final class SimulatedTransport: MeshTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.fellship.sim")
    private let frameCaster = StreamMulticaster<Data>()
    private let stateCaster = StreamMulticaster<TransportState>(replayLast: true)
    private let radiosCaster = StreamMulticaster<[DiscoveredRadio]>(replayLast: true)

    func frames() -> AsyncStream<Data> { frameCaster.stream(bufferingNewest: 256) }
    func states() -> AsyncStream<TransportState> { stateCaster.stream(bufferingNewest: 8) }
    func discovered() -> AsyncStream<[DiscoveredRadio]> { radiosCaster.stream(bufferingNewest: 8) }

    private let dmAssembler = FellshipEnvelope.DirectAssembler()
    private var connected = false
    private var tickTimer: DispatchSourceTimer?
    private var startTime = Date()
    private var lastChatAt = Date()
    private var chatCursor = 0
    private var inviteSent = false
    private var peerInsideFlags: [String: Bool] = [:]
    private var queuedMessages: [Data] = [] // frames waiting behind msgWaiting
    private let selfRadioKey = Data(SHA256.hash(data: Data("fellship.demo.self.radio".utf8)))

    private let chatLines: [(Int, String)] = [
        (1, "Anyone near the meadow? Kettle's on."),
        (2, "Heading up the east path now."),
        (0, "Just passed the windmill, be there in 10."),
        (1, "Found a great lookout spot by the lake."),
        (2, "Radio check — loud and clear out here."),
    ]

    init() {
        stateCaster.yield(.disconnected)
    }

    // MARK: - MeshTransport

    func startScanning() {
        queue.async { [self] in
            stateCaster.yield(.scanning)
            queue.asyncAfter(deadline: .now() + 0.6) { [self] in
                radiosCaster.yield([DiscoveredRadio(id: "demo-radio", name: "Demo Radio (T-Beam)", rssi: -48)])
            }
        }
    }

    func stopScanning() {
        queue.async { [self] in
            if !connected { stateCaster.yield(.disconnected) }
        }
    }

    func connect(to radioID: String) async throws {
        try await Task.sleep(nanoseconds: 400_000_000)
        queue.sync { [self] in
            connected = true
            startTime = Date()
            stateCaster.yield(.connected(deviceName: "Demo Radio (T-Beam)"))
            startTicking()
        }
    }

    func disconnect() {
        queue.async { [self] in
            connected = false
            tickTimer?.cancel()
            tickTimer = nil
            stateCaster.yield(.disconnected)
        }
    }

    func send(_ frame: Data) async throws {
        guard queue.sync(execute: { connected }) else { throw TransportError.notConnected }
        // Simulated radio latency.
        try await Task.sleep(nanoseconds: 60_000_000)
        queue.async { [self] in
            handleCommand(frame)
        }
    }

    // MARK: - Companion protocol (radio side)

    private func respond(_ frame: Data, after delay: TimeInterval = 0.02) {
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard connected else { return }
            frameCaster.yield(frame)
        }
    }

    private func handleCommand(_ frame: Data) {
        guard let code = frame.first, let command = MeshCore.Command(rawValue: code) else {
            respond(Data([MeshCore.Response.err.rawValue]))
            return
        }
        switch command {
        case .appStart, .deviceQuery:
            if command == .appStart {
                respond(selfInfoFrame())
            } else {
                var w = BinaryWriter()
                w.writeUInt8(MeshCore.Response.deviceInfo.rawValue)
                w.writeInt8(3)
                w.writeBytes(Data(repeating: 0, count: 6))
                w.writeCString("1 Apr 2026", fieldLength: 12)
                w.writeString("Fellship Demo T-Beam")
                respond(w.data)
            }
        case .getContacts:
            respond(Data([MeshCore.Response.contactsStart.rawValue]))
            for peer in SimPeer.all {
                respond(contactFrame(for: peer))
            }
            respond(Data([MeshCore.Response.endOfContacts.rawValue]))
        case .sendTxtMsg:
            handleDirectMessage(frame)
        case .sendChannelTxtMsg:
            respond(sentFrame())
        case .syncNextMessage:
            if queuedMessages.isEmpty {
                respond(Data([MeshCore.Response.noMoreMessages.rawValue]))
            } else {
                respond(queuedMessages.removeFirst())
            }
        case .getBatteryVoltage:
            var w = BinaryWriter()
            w.writeUInt8(MeshCore.Response.batteryVoltage.rawValue)
            w.writeUInt16(4020)
            respond(w.data)
        case .getChannel:
            var r = BinaryReader(frame.dropFirst())
            let index = (try? r.readUInt8()) ?? 0
            var w = BinaryWriter()
            w.writeUInt8(MeshCore.Response.channelInfo.rawValue)
            w.writeUInt8(index)
            w.writeCString(index == 0 ? "Public" : "", fieldLength: 32)
            w.writeBytes(Data(repeating: 0, count: 16))
            respond(w.data)
        case .setChannel, .setAdvertLatLon, .setAdvertName, .sendSelfAdvert, .setDeviceTime:
            respond(Data([MeshCore.Response.ok.rawValue]))
        case .getDeviceTime:
            var w = BinaryWriter()
            w.writeUInt8(MeshCore.Response.currTime.rawValue)
            w.writeUInt32(UInt32(clamping: Int(Date().timeIntervalSince1970)))
            respond(w.data)
        }
    }

    private func selfInfoFrame() -> Data {
        // The demo phone-holder ambles gently inside the zone.
        let t = Date().timeIntervalSince(startTime)
        let wobble = 120.0
        let dLat = wobble / GeoMath.earthRadiusMeters * 180 / .pi
        let position = Coordinate(
            latitude: DemoWorld.center.latitude + dLat * sin(t / 90),
            longitude: DemoWorld.center.longitude + dLat * cos(t / 130))
        var w = BinaryWriter()
        w.writeUInt8(MeshCore.Response.selfInfo.rawValue)
        w.writeUInt8(1)   // advert type: chat
        w.writeUInt8(22)  // tx power
        w.writeUInt8(30)  // max tx power
        w.writeBytes(selfRadioKey)
        w.writeInt32(position.microdegreesLat)
        w.writeInt32(position.microdegreesLon)
        w.writeBytes(Data(repeating: 0, count: 3))
        w.writeUInt8(0)   // manual add contacts
        w.writeUInt32(910_525) // kHz
        w.writeUInt32(250_000) // Hz bandwidth
        w.writeUInt8(10)  // SF
        w.writeUInt8(5)   // CR
        w.writeString("Demo Radio")
        return w.data
    }

    private func contactFrame(for peer: SimPeer) -> Data {
        let position = peer.position(at: Date().timeIntervalSince(startTime))
        var w = BinaryWriter()
        w.writeUInt8(MeshCore.Response.contact.rawValue)
        w.writeBytes(peer.radioPublicKey)
        w.writeUInt8(1) // chat node
        w.writeUInt8(0) // flags
        w.writeInt8(0)  // out path len
        w.writeBytes(Data(repeating: 0, count: 64))
        w.writeCString(peer.name, fieldLength: 32)
        w.writeUInt32(UInt32(clamping: Int(Date().timeIntervalSince1970)))
        w.writeInt32(position.microdegreesLat)
        w.writeInt32(position.microdegreesLon)
        w.writeUInt32(UInt32(clamping: Int(Date().timeIntervalSince1970)))
        return w.data
    }

    private func sentFrame() -> Data {
        var w = BinaryWriter()
        w.writeUInt8(MeshCore.Response.sent.rawValue)
        w.writeInt8(0)
        w.writeUInt32(UInt32.random(in: 1..<UInt32.max))
        w.writeUInt32(4000)
        return w.data
    }

    private func handleDirectMessage(_ frame: Data) {
        var r = BinaryReader(frame.dropFirst())
        guard let _ = try? r.skip(2),               // txtType, attempt
              let _ = try? r.readUInt32(),          // timestamp
              let prefix = try? r.readBytes(6) else {
            respond(Data([MeshCore.Response.err.rawValue]))
            return
        }
        let text = r.readStringToEnd()
        var w = BinaryWriter()
        w.writeUInt8(MeshCore.Response.sent.rawValue)
        w.writeInt8(0)
        let ack = UInt32.random(in: 1..<UInt32.max)
        w.writeUInt32(ack)
        w.writeUInt32(3000)
        respond(w.data)

        // Ack lands a moment later.
        var confirm = BinaryWriter()
        confirm.writeUInt8(MeshCore.Push.sendConfirmed.rawValue)
        confirm.writeUInt32(ack)
        confirm.writeUInt32(1800)
        respond(confirm.data, after: 1.5)

        guard let peer = SimPeer.all.first(where: { $0.radioPublicKey.prefix(6) == prefix }) else { return }

        // Fellship envelope chunk? Then it's invite plumbing; otherwise chat back.
        if FellshipEnvelope.isDirectEnvelope(text) {
            if let (type, body) = dmAssembler.ingest(senderHex: "app-user", text: text) {
                handleEnvelopeDM(type: type, body: body, from: peer)
            }
        } else {
            let reply = "Copy that! (\(peer.name), demo)"
            queueIncomingDM(from: peer, text: reply, after: 3.5)
        }
    }

    private func handleEnvelopeDM(type: FellshipEnvelope.PayloadType, body: Data, from peer: SimPeer) {
        guard type == .inviteAccept,
              let accept = try? FellshipEnvelope.decodeDirectPayload(FellshipEnvelope.InviteAccept.self, from: body),
              accept.roomID == DemoWorld.publicRoomID,
              let inviteeKeyData = Data(hexEncoded: accept.inviteeIdentityKey),
              let inviteeKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: inviteeKeyData) else { return }

        let room = DemoWorld.publicDemoRoom()
        let manifest = FellshipEnvelope.RoomManifest(
            room: room,
            members: SimPeer.all.map(\.member),
            roomKeyData: DemoWorld.publicRoomKey.dataRepresentation)
        guard let manifestData = try? FellshipEnvelope.encodeManifest(manifest),
              let sealed = try? CryptoService.sealBox(manifestData, recipientPublicKey: inviteeKey),
              let chunks = try? FellshipEnvelope.directChunks(
                FellshipEnvelope.RoomKeyDelivery(inviteID: accept.inviteID, roomID: room.id, sealedManifest: sealed),
                type: .roomKeyDelivery) else { return }
        for (index, chunk) in chunks.enumerated() {
            queueIncomingDM(from: SimPeer.all[2], text: chunk, after: 2.0 + Double(index) * 0.4)
        }
        _ = peer // the accept sender; delivery always comes from Kai, the room's creator
    }

    private func queueIncomingDM(from peer: SimPeer, text: String, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard connected else { return }
            var w = BinaryWriter()
            w.writeUInt8(MeshCore.Response.contactMsgRecv.rawValue)
            w.writeBytes(peer.radioPublicKey.prefix(6))
            w.writeUInt8(0) // path len
            w.writeUInt8(MeshCore.TextType.plain.rawValue)
            w.writeUInt32(UInt32(clamping: Int(Date().timeIntervalSince1970)))
            w.writeString(text)
            queuedMessages.append(w.data)
            frameCaster.yield(Data([MeshCore.Push.msgWaiting.rawValue]))
        }
    }

    private func queueChannelMessage(text: String, after delay: TimeInterval = 0) {
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard connected else { return }
            var w = BinaryWriter()
            w.writeUInt8(MeshCore.Response.channelMsgRecv.rawValue)
            w.writeInt8(1)
            w.writeUInt8(0)
            w.writeUInt8(MeshCore.TextType.plain.rawValue)
            w.writeUInt32(UInt32(clamping: Int(Date().timeIntervalSince1970)))
            w.writeString(text)
            queuedMessages.append(w.data)
            frameCaster.yield(Data([MeshCore.Push.msgWaiting.rawValue]))
        }
    }

    // MARK: - Scripted world

    private func startTicking() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 6)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        tickTimer = timer
    }

    private func tick() {
        guard connected else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let boundary = Boundary.circle(center: DemoWorld.center, radiusMeters: 700)

        for peer in SimPeer.all {
            let position = peer.position(at: elapsed)
            let inside = GeoMath.contains(boundary, point: position)
            let wasInside = peerInsideFlags[peer.name] ?? true

            let presence = FellshipEnvelope.Presence(
                memberID: peer.identityKeyHex,
                isInside: inside,
                coordinate: position,
                sentAt: Date())
            if let text = try? FellshipEnvelope.sealRoomPayload(.presence(presence),
                                                                roomID: DemoWorld.roomID,
                                                                roomKey: DemoWorld.roomKey) {
                queueChannelMessage(text: text)
            }

            if inside != wasInside {
                peerInsideFlags[peer.name] = inside
                let event = FellshipEnvelope.ZoneEvent(memberID: peer.identityKeyHex,
                                                       didEnter: inside,
                                                       sentAt: Date())
                if let text = try? FellshipEnvelope.sealRoomPayload(.zoneEvent(event),
                                                                    roomID: DemoWorld.roomID,
                                                                    roomKey: DemoWorld.roomKey) {
                    queueChannelMessage(text: text, after: 0.5)
                }
            }
        }

        // A friendly chat message every ~45 seconds.
        if Date().timeIntervalSince(lastChatAt) > 45 {
            lastChatAt = Date()
            let (peerIndex, line) = chatLines[chatCursor % chatLines.count]
            chatCursor += 1
            let peer = SimPeer.all[peerIndex]
            let chat = FellshipEnvelope.Chat(messageID: Data((0..<6).map { _ in UInt8.random(in: 0...255) }).hexEncoded,
                                             memberID: peer.identityKeyHex,
                                             zoneScoped: false,
                                             text: line,
                                             sentAt: Date())
            if let text = try? FellshipEnvelope.sealRoomPayload(.chat(chat),
                                                                roomID: DemoWorld.roomID,
                                                                roomKey: DemoWorld.roomKey) {
                queueChannelMessage(text: text, after: 1.0)
            }
        }

        // Once, a couple of minutes in: Kai invites the user to a public
        // range-based room, exercising the full invite pipeline.
        if !inviteSent, elapsed > 120 {
            inviteSent = true
            let offer = FellshipEnvelope.InviteOffer(
                inviteID: UUID().uuidString,
                roomID: DemoWorld.publicRoomID,
                roomName: "Ridge Ramble",
                roomKind: .rangeBased,
                access: .publicRoom,
                inviterIdentityKey: SimPeer.all[2].identityKeyHex,
                inviterName: "Kai",
                isAutomatic: true)
            if let chunks = try? FellshipEnvelope.directChunks(offer, type: .inviteOffer) {
                for (index, chunk) in chunks.enumerated() {
                    queueIncomingDM(from: SimPeer.all[2], text: chunk, after: Double(index) * 0.4)
                }
            }
        }
    }
}
