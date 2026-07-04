import XCTest
import CryptoKit
@testable import Fellship

final class CryptoAndEnvelopeTests: XCTestCase {
    let roomID = "00112233445566778899aabbccddeeff"

    func testRoomSealOpenRoundTrip() throws {
        let key = CryptoService.generateRoomKey()
        let plaintext = Data("presence packet".utf8)
        let sealed = try CryptoService.seal(plaintext, roomKey: key, roomID: roomID)
        XCTAssertNotEqual(sealed, plaintext)
        let opened = try CryptoService.open(sealed, roomKey: key, roomID: roomID)
        XCTAssertEqual(opened, plaintext)
    }

    func testWrongKeyFailsToOpen() throws {
        let sealed = try CryptoService.seal(Data("secret".utf8),
                                            roomKey: CryptoService.generateRoomKey(),
                                            roomID: roomID)
        XCTAssertThrowsError(try CryptoService.open(sealed,
                                                    roomKey: CryptoService.generateRoomKey(),
                                                    roomID: roomID))
    }

    func testWrongRoomIDFailsAuthentication() throws {
        let key = CryptoService.generateRoomKey()
        let sealed = try CryptoService.seal(Data("secret".utf8), roomKey: key, roomID: roomID)
        XCTAssertThrowsError(try CryptoService.open(sealed, roomKey: key,
                                                    roomID: "ffffffffffffffffffffffffffffffff"))
    }

    func testTamperedCiphertextFails() throws {
        let key = CryptoService.generateRoomKey()
        var sealed = try CryptoService.seal(Data("secret".utf8), roomKey: key, roomID: roomID)
        sealed[sealed.count - 1] ^= 0xFF
        XCTAssertThrowsError(try CryptoService.open(sealed, roomKey: key, roomID: roomID))
    }

    func testSealedBoxRoundTrip() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let payload = Data("the room key itself".utf8)
        let boxed = try CryptoService.sealBox(payload, recipientPublicKey: recipient.publicKey)
        let opened = try CryptoService.openBox(boxed, identity: recipient)
        XCTAssertEqual(opened, payload)
    }

    func testSealedBoxWrongRecipientFails() throws {
        let boxed = try CryptoService.sealBox(Data("x".utf8),
                                              recipientPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey)
        XCTAssertThrowsError(try CryptoService.openBox(boxed,
                                                       identity: Curve25519.KeyAgreement.PrivateKey()))
    }

    func testChannelPSKDeterministicAnd16Bytes() {
        let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
        let psk1 = CryptoService.channelPSK(roomKey: key)
        let psk2 = CryptoService.channelPSK(roomKey: key)
        XCTAssertEqual(psk1, psk2)
        XCTAssertEqual(psk1.count, 16)
        let other = CryptoService.channelPSK(roomKey: CryptoService.generateRoomKey())
        XCTAssertNotEqual(psk1, other)
    }

    func testHexRoundTrip() {
        let data = Data((0..<32).map { UInt8($0 * 7 & 0xFF) })
        XCTAssertEqual(Data(hexEncoded: data.hexEncoded), data)
        XCTAssertNil(Data(hexEncoded: "abc"))   // odd length
        XCTAssertNil(Data(hexEncoded: "zz"))    // bad digits
    }

    func testBase64URLRoundTrip() {
        for length in [0, 1, 2, 3, 31, 32, 33, 100] {
            let data = Data((0..<length).map { _ in UInt8.random(in: 0...255) })
            let encoded = data.base64URLEncoded
            XCTAssertFalse(encoded.contains("+"))
            XCTAssertFalse(encoded.contains("/"))
            XCTAssertFalse(encoded.contains("="))
            XCTAssertEqual(Data(base64URLEncoded: encoded), data)
        }
    }

    // MARK: - Envelope (compact binary, spec §6 + LoRa payload budget)

    /// A full member ID (identity key hex) and its expected 16-hex wire prefix.
    let memberID = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"

    func testPresenceRoundTrip() throws {
        let key = CryptoService.generateRoomKey()
        let presence = FellshipEnvelope.Presence(memberID: memberID,
                                                 isInside: true,
                                                 coordinate: Coordinate(latitude: 37.7, longitude: -122.4),
                                                 sentAt: Date())
        let text = try FellshipEnvelope.sealRoomPayload(.presence(presence),
                                                        roomID: roomID, roomKey: key)
        XCTAssertTrue(text.hasPrefix("~F1~"))
        XCTAssertEqual(FellshipEnvelope.roomIDPrefix(fromText: text), String(roomID.prefix(16)))

        guard case .presence(let decoded) = try FellshipEnvelope.openRoomPayload(text, roomID: roomID, roomKey: key) else {
            return XCTFail("expected presence")
        }
        XCTAssertEqual(decoded.memberID, String(memberID.prefix(16)))
        XCTAssertTrue(memberID.hasPrefix(decoded.memberID), "wire prefix must resolve to the full ID")
        XCTAssertEqual(decoded.coordinate?.latitude ?? 0, 37.7, accuracy: 0.00001)
        XCTAssertTrue(decoded.isInside)
    }

    func testPresenceWithoutCoordinatesOmitsThem() throws {
        let key = CryptoService.generateRoomKey()
        let presence = FellshipEnvelope.Presence(memberID: memberID, isInside: false,
                                                 coordinate: nil, sentAt: Date())
        let text = try FellshipEnvelope.sealRoomPayload(.presence(presence),
                                                        roomID: roomID, roomKey: key)
        guard case .presence(let decoded) = try FellshipEnvelope.openRoomPayload(text, roomID: roomID, roomKey: key) else {
            return XCTFail("expected presence")
        }
        XCTAssertNil(decoded.coordinate)
        XCTAssertFalse(decoded.isInside)
    }

    func testChatAndZoneEventRoundTrip() throws {
        let key = CryptoService.generateRoomKey()
        let chat = FellshipEnvelope.Chat(messageID: "010203040506",
                                         memberID: memberID,
                                         zoneScoped: true,
                                         text: "Meet at the col",
                                         sentAt: Date(),
                                         part: 1, partCount: 3)
        let chatText = try FellshipEnvelope.sealRoomPayload(.chat(chat), roomID: roomID, roomKey: key)
        guard case .chat(let decodedChat) = try FellshipEnvelope.openRoomPayload(chatText, roomID: roomID, roomKey: key) else {
            return XCTFail("expected chat")
        }
        XCTAssertEqual(decodedChat.messageID, "010203040506")
        XCTAssertTrue(decodedChat.zoneScoped)
        XCTAssertEqual(decodedChat.text, "Meet at the col")
        XCTAssertEqual(decodedChat.part, 1)
        XCTAssertEqual(decodedChat.partCount, 3)

        let event = FellshipEnvelope.ZoneEvent(memberID: memberID, didEnter: true, sentAt: Date())
        let eventText = try FellshipEnvelope.sealRoomPayload(.zoneEvent(event), roomID: roomID, roomKey: key)
        guard case .zoneEvent(let decodedEvent) = try FellshipEnvelope.openRoomPayload(eventText, roomID: roomID, roomKey: key) else {
            return XCTFail("expected zoneEvent")
        }
        XCTAssertTrue(decodedEvent.didEnter)
    }

    func testMemberAnnounceRoundTrip() throws {
        let key = CryptoService.generateRoomKey()
        let member = Member(id: memberID, displayName: "Robin",
                            radioPublicKey: String(repeating: "ab", count: 32),
                            joinedAt: Date())
        let text = try FellshipEnvelope.sealRoomPayload(
            .memberAnnounce(FellshipEnvelope.MemberAnnounce(member: member)),
            roomID: roomID, roomKey: key)
        guard case .memberAnnounce(let decoded) = try FellshipEnvelope.openRoomPayload(text, roomID: roomID, roomKey: key) else {
            return XCTFail("expected announce")
        }
        XCTAssertEqual(decoded.member.id, memberID)
        XCTAssertEqual(decoded.member.displayName, "Robin")
        XCTAssertEqual(decoded.member.radioPublicKey, String(repeating: "ab", count: 32))
    }

    /// The hard constraint that shaped the wire format: room traffic must fit
    /// a single stock MeshCore text frame (~160 bytes usable).
    func testRoomPayloadsFitLoRaTextBudget() throws {
        let key = CryptoService.generateRoomKey()
        let presence = FellshipEnvelope.Presence(memberID: memberID, isInside: true,
                                                 coordinate: Coordinate(latitude: -37.5, longitude: 145.2),
                                                 sentAt: Date())
        let presenceText = try FellshipEnvelope.sealRoomPayload(.presence(presence),
                                                                roomID: roomID, roomKey: key)
        XCTAssertLessThanOrEqual(presenceText.utf8.count, 110,
                                 "presence must leave generous headroom")

        let zoneText = try FellshipEnvelope.sealRoomPayload(
            .zoneEvent(FellshipEnvelope.ZoneEvent(memberID: memberID, didEnter: false, sentAt: Date())),
            roomID: roomID, roomKey: key)
        XCTAssertLessThanOrEqual(zoneText.utf8.count, 100)

        let chat60 = FellshipEnvelope.Chat(messageID: "010203040506", memberID: memberID,
                                           zoneScoped: false,
                                           text: String(repeating: "x", count: 60),
                                           sentAt: Date())
        let chatText = try FellshipEnvelope.sealRoomPayload(.chat(chat60), roomID: roomID, roomKey: key)
        XCTAssertLessThanOrEqual(chatText.utf8.count, 160,
                                 "a 60-char chat message must fit one LoRa text frame")

        // The engine splits at 48 chars/part — every part must fit with room
        // to spare.
        let part48 = FellshipEnvelope.Chat(messageID: "010203040506", memberID: memberID,
                                           zoneScoped: true,
                                           text: String(repeating: "w", count: 48),
                                           sentAt: Date(), part: 2, partCount: 3)
        let partText = try FellshipEnvelope.sealRoomPayload(.chat(part48), roomID: roomID, roomKey: key)
        XCTAssertLessThanOrEqual(partText.utf8.count, 150)

        // Every direct chunk must fit too.
        let delivery = FellshipEnvelope.RoomKeyDelivery(inviteID: UUID().uuidString,
                                                        roomID: roomID,
                                                        sealedManifest: Data(repeating: 7, count: 900))
        let chunks = try FellshipEnvelope.directChunks(delivery, type: .roomKeyDelivery)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.utf8.count, 150, "chunk exceeds LoRa text budget")
        }
    }

    func testDirectChunkReassemblyInOrder() throws {
        let offer = FellshipEnvelope.InviteOffer(inviteID: "i1", roomID: roomID,
                                                 roomName: "Cabin Weekend Crew",
                                                 roomKind: .geofenced,
                                                 access: .inviteOnly,
                                                 inviterIdentityKey: memberID,
                                                 inviterName: "Ash", isAutomatic: false)
        let chunks = try FellshipEnvelope.directChunks(offer, type: .inviteOffer)
        let assembler = FellshipEnvelope.DirectAssembler()
        var result: (type: FellshipEnvelope.PayloadType, body: Data)?
        for chunk in chunks {
            result = assembler.ingest(senderHex: "peer1", text: chunk)
        }
        let (type, body) = try XCTUnwrap(result)
        XCTAssertEqual(type, .inviteOffer)
        let decoded = try FellshipEnvelope.decodeDirectPayload(FellshipEnvelope.InviteOffer.self, from: body)
        XCTAssertEqual(decoded, offer)
    }

    func testDirectChunkReassemblyOutOfOrderAndInterleaved() throws {
        let accept = FellshipEnvelope.InviteAccept(inviteID: "i2", roomID: roomID,
                                                   inviteeIdentityKey: memberID,
                                                   inviteeName: "A fairly long display name")
        let chunksA = try FellshipEnvelope.directChunks(accept, type: .inviteAccept, chunkDataSize: 24)
        XCTAssertGreaterThan(chunksA.count, 2)

        let other = FellshipEnvelope.InviteAccept(inviteID: "i3", roomID: roomID,
                                                  inviteeIdentityKey: memberID,
                                                  inviteeName: "Someone else")
        let chunksB = try FellshipEnvelope.directChunks(other, type: .inviteAccept, chunkDataSize: 24)

        let assembler = FellshipEnvelope.DirectAssembler()
        // Interleave two senders and shuffle order within each.
        var result1: (type: FellshipEnvelope.PayloadType, body: Data)?
        var result2: (type: FellshipEnvelope.PayloadType, body: Data)?
        for chunk in chunksA.reversed() {
            result1 = assembler.ingest(senderHex: "peer1", text: chunk) ?? result1
        }
        for chunk in chunksB.shuffled() {
            result2 = assembler.ingest(senderHex: "peer2", text: chunk) ?? result2
        }
        let decoded1 = try FellshipEnvelope.decodeDirectPayload(
            FellshipEnvelope.InviteAccept.self, from: try XCTUnwrap(result1).body)
        XCTAssertEqual(decoded1, accept)
        let decoded2 = try FellshipEnvelope.decodeDirectPayload(
            FellshipEnvelope.InviteAccept.self, from: try XCTUnwrap(result2).body)
        XCTAssertEqual(decoded2, other)
    }

    func testAssemblerIgnoresGarbageAndPlainText() {
        let assembler = FellshipEnvelope.DirectAssembler()
        XCTAssertNil(assembler.ingest(senderHex: "p", text: "just a normal message"))
        XCTAssertNil(assembler.ingest(senderHex: "p", text: "~F2~notbase64!!!"))
        XCTAssertNil(assembler.ingest(senderHex: "p", text: "~F2~AAAA")) // too short
    }

    func testNonEnvelopeTextIsRejected() {
        XCTAssertNil(FellshipEnvelope.roomIDPrefix(fromText: "hello there"))
        XCTAssertNil(FellshipEnvelope.roomIDPrefix(fromText: "~F1~%%%not-base64%%%"))
        let key = CryptoService.generateRoomKey()
        XCTAssertThrowsError(try FellshipEnvelope.openRoomPayload("garbage", roomID: roomID, roomKey: key))
        XCTAssertThrowsError(try FellshipEnvelope.openRoomPayload("~F1~AAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                                                                  roomID: roomID, roomKey: key))
    }

    func testManifestRoundTripPreservesRoomAndKey() throws {
        let room = Room(id: roomID, name: "Cabin", kind: .geofenced,
                        boundary: .circle(center: Coordinate(latitude: 37, longitude: -122),
                                          radiusMeters: 250),
                        access: .inviteOnly, permanence: .permanent, expiresAt: nil,
                        sharesPreciseLocation: true, isMuted: false,
                        createdAt: Date(), creatorID: "creator")
        let keyData = CryptoService.generateRoomKey().dataRepresentation
        let manifest = FellshipEnvelope.RoomManifest(
            room: room,
            members: [Member(id: "m1", displayName: "Robin", radioPublicKey: nil, joinedAt: Date())],
            roomKeyData: keyData)
        let encoded = try FellshipEnvelope.encodeManifest(manifest)
        let decoded = try FellshipEnvelope.decodeManifest(encoded)
        // Field-wise comparison: Date sub-second precision doesn't survive
        // JSON, and nothing in the app relies on it.
        XCTAssertEqual(decoded.room.id, room.id)
        XCTAssertEqual(decoded.room.name, room.name)
        XCTAssertEqual(decoded.room.boundary, room.boundary)
        XCTAssertEqual(decoded.room.access, room.access)
        XCTAssertEqual(decoded.room.sharesPreciseLocation, room.sharesPreciseLocation)
        XCTAssertEqual(decoded.roomKeyData, keyData)
        XCTAssertEqual(decoded.members.count, 1)
    }

    func testBoundaryCodableAllShapes() throws {
        let shapes: [Boundary] = [
            .circle(center: Coordinate(latitude: 1, longitude: 2), radiusMeters: 300),
            .box(cornerA: Coordinate(latitude: 1, longitude: 2),
                 cornerB: Coordinate(latitude: 3, longitude: 4)),
            .polygon(vertices: [Coordinate(latitude: 0, longitude: 0),
                                Coordinate(latitude: 1, longitude: 0),
                                Coordinate(latitude: 0, longitude: 1)]),
        ]
        for shape in shapes {
            let data = try JSONEncoder().encode(shape)
            let decoded = try JSONDecoder().decode(Boundary.self, from: data)
            XCTAssertEqual(decoded, shape)
        }
    }
}
