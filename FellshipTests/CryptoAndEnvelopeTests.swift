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

    // MARK: - Envelope

    func testRoomTextRoundTrip() throws {
        let key = CryptoService.generateRoomKey()
        let presence = FellshipEnvelope.Presence(memberID: "m1", name: "Robin",
                                                 isInside: true,
                                                 latitude: 37.7, longitude: -122.4,
                                                 sentAt: Date())
        let text = try FellshipEnvelope.sealRoomText(presence, type: .presence,
                                                     roomID: roomID, roomKey: key)
        XCTAssertTrue(text.hasPrefix("~F1~"))
        XCTAssertEqual(FellshipEnvelope.roomIDPrefix(fromText: text), String(roomID.prefix(16)))

        let (type, body) = try FellshipEnvelope.openRoomText(text, roomID: roomID, roomKey: key)
        XCTAssertEqual(type, .presence)
        let decoded = try FellshipEnvelope.decodeBody(FellshipEnvelope.Presence.self, from: body)
        XCTAssertEqual(decoded.memberID, "m1")
        XCTAssertEqual(decoded.latitude ?? 0, 37.7, accuracy: 0.0001)
        XCTAssertTrue(decoded.isInside)
    }

    func testPresenceWithoutCoordinatesOmitsThem() throws {
        let presence = FellshipEnvelope.Presence(memberID: "m1", name: "Robin",
                                                 isInside: true,
                                                 latitude: nil, longitude: nil,
                                                 sentAt: Date())
        XCTAssertNil(presence.coordinate)
        let key = CryptoService.generateRoomKey()
        let text = try FellshipEnvelope.sealRoomText(presence, type: .presence,
                                                     roomID: roomID, roomKey: key)
        let (_, body) = try FellshipEnvelope.openRoomText(text, roomID: roomID, roomKey: key)
        let decoded = try FellshipEnvelope.decodeBody(FellshipEnvelope.Presence.self, from: body)
        XCTAssertNil(decoded.coordinate)
    }

    func testDirectTextRoundTrip() throws {
        let offer = FellshipEnvelope.InviteOffer(inviteID: "i1", roomID: roomID,
                                                 roomName: "Cabin", roomKind: .geofenced,
                                                 access: .inviteOnly,
                                                 inviterIdentityKey: "aa",
                                                 inviterName: "Ash", isAutomatic: false)
        let text = try FellshipEnvelope.sealDirectText(offer, type: .inviteOffer)
        let (type, body) = try FellshipEnvelope.openDirectText(text)
        XCTAssertEqual(type, .inviteOffer)
        let decoded = try FellshipEnvelope.decodeBody(FellshipEnvelope.InviteOffer.self, from: body)
        XCTAssertEqual(decoded.roomName, "Cabin")
    }

    func testNonEnvelopeTextIsRejected() {
        XCTAssertNil(FellshipEnvelope.roomIDPrefix(fromText: "hello there"))
        XCTAssertNil(FellshipEnvelope.roomIDPrefix(fromText: "~F1~%%%not-base64%%%"))
        XCTAssertThrowsError(try FellshipEnvelope.openDirectText("plain message"))
        let key = CryptoService.generateRoomKey()
        XCTAssertThrowsError(try FellshipEnvelope.openRoomText("garbage", roomID: roomID, roomKey: key))
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
        XCTAssertEqual(decoded.room, room)
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
