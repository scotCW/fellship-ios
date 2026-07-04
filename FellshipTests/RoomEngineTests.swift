import XCTest
import CryptoKit
@testable import Fellship

/// Engine-level behavior tests: the activation rule, zone transitions,
/// zone-scoped delivery, dedupe, and QR joining — all against an ephemeral
/// store and no radio (the engine must behave sanely offline).
@MainActor
final class RoomEngineTests: XCTestCase {
    var engine: RoomEngine!

    override func setUp() async throws {
        // Room creation stores keys in the Keychain; without entitlements
        // (e.g. an unsigned test host) that fails. Skip loudly rather than
        // crash on force-unwraps downstream.
        let probe = KeychainStore(service: "app.fellship.tests")
        do {
            try probe.save(Data([1]), for: "probe")
            probe.delete("probe")
        } catch {
            throw XCTSkip("Keychain unavailable in this test host (build must be signed to run locally)")
        }
        engine = RoomEngine(store: LocalStore.ephemeral(),
                            settings: AppSettings(defaults: UserDefaults(suiteName: "test-\(UUID())")!),
                            notifications: NotificationService())
    }

    private let center = Coordinate(latitude: 37.7694, longitude: -122.4862)

    private func makeGeofencedRoom(access: RoomAccess = .inviteOnly,
                                   shares: Bool = true) -> Room {
        engine.createRoom(name: "Test Zone", kind: .geofenced,
                          boundary: .circle(center: center, radiusMeters: 500),
                          access: access, permanence: .permanent,
                          duration: nil, sharesPreciseLocation: shares)!
    }

    override func tearDown() {
        // Scrub Keychain entries created by tests.
        for room in engine.rooms {
            CryptoService.deleteRoomKey(roomID: room.id)
        }
        super.tearDown()
    }

    // MARK: - Activation rule (spec §3.1)

    func testGeofencedRoomInactiveUntilSomeoneIsInside() async {
        let room = makeGeofencedRoom()
        XCTAssertFalse(engine.isActive(room), "empty new room must be inactive")

        // My device lands inside the boundary.
        await engine.handleTick(fix: LocationFix(coordinate: center, source: .phone, timestamp: Date()))
        XCTAssertTrue(engine.isActive(room))
        XCTAssertEqual(engine.myInside[room.id], true)

        // I wander far away → inactive again (nobody else present).
        let far = Coordinate(latitude: 37.9, longitude: -122.1)
        await engine.handleTick(fix: LocationFix(coordinate: far, source: .phone, timestamp: Date()))
        XCTAssertFalse(engine.isActive(room))
        XCTAssertEqual(engine.myInside[room.id], false)
    }

    func testZoneTransitionWritesSystemMessage() async {
        let room = makeGeofencedRoom()
        await engine.handleTick(fix: LocationFix(coordinate: center, source: .phone, timestamp: Date()))
        let far = Coordinate(latitude: 37.9, longitude: -122.1)
        await engine.handleTick(fix: LocationFix(coordinate: far, source: .phone, timestamp: Date()))

        // The first fix sets state silently (no spurious entry event on app
        // start); the exit is the first real transition.
        let systemLines = engine.messages(threadID: room.id).filter(\.isSystemEvent).map(\.text)
        XCTAssertEqual(systemLines, ["You left the zone"])
    }

    func testRemotePresenceActivatesRoom() throws {
        let room = makeGeofencedRoom()
        let key = try XCTUnwrap(CryptoService.roomKey(for: room.id))
        let remoteID = String(repeating: "ab", count: 32)
        let presence = FellshipEnvelope.Presence(memberID: remoteID, isInside: true,
                                                 coordinate: center, sentAt: Date())
        let text = try FellshipEnvelope.sealRoomPayload(.presence(presence),
                                                        roomID: room.id, roomKey: key)
        engine.handleChannelText(text)
        XCTAssertTrue(engine.isActive(room), "fresh remote inside-presence must activate the room")

        // The presence coordinate is honored because this room shares locations.
        let stored = engine.presence[room.id]?.values.first
        XCTAssertNotNil(stored?.coordinate)
    }

    func testPresenceCoordinateIgnoredWhenRoomDoesNotShare() throws {
        let room = makeGeofencedRoom(shares: false)
        let key = try XCTUnwrap(CryptoService.roomKey(for: room.id))
        let presence = FellshipEnvelope.Presence(memberID: String(repeating: "cd", count: 32),
                                                 isInside: true, coordinate: center, sentAt: Date())
        let text = try FellshipEnvelope.sealRoomPayload(.presence(presence),
                                                        roomID: room.id, roomKey: key)
        engine.handleChannelText(text)
        let stored = engine.presence[room.id]?.values.first
        XCTAssertNotNil(stored)
        XCTAssertNil(stored?.coordinate,
                     "receiver must not keep coordinates for a non-sharing room")
    }

    // MARK: - Zone-scoped chat (spec §5.2)

    func testZoneScopedChatDroppedWhenOutside() throws {
        let room = makeGeofencedRoom()
        let key = try XCTUnwrap(CryptoService.roomKey(for: room.id))
        engine.myInside[room.id] = false
        let chat = FellshipEnvelope.Chat(messageID: "1111111111111111",
                                         memberID: String(repeating: "ab", count: 32),
                                         zoneScoped: true, text: "zone only", sentAt: Date())
        engine.handleChannelText(try FellshipEnvelope.sealRoomPayload(.chat(chat),
                                                                      roomID: room.id, roomKey: key))
        XCTAssertTrue(engine.messages(threadID: room.id).filter { !$0.isSystemEvent }.isEmpty)

        engine.myInside[room.id] = true
        let chat2 = FellshipEnvelope.Chat(messageID: "2222222222222222",
                                          memberID: String(repeating: "ab", count: 32),
                                          zoneScoped: true, text: "zone only 2", sentAt: Date())
        engine.handleChannelText(try FellshipEnvelope.sealRoomPayload(.chat(chat2),
                                                                      roomID: room.id, roomKey: key))
        XCTAssertEqual(engine.messages(threadID: room.id).filter { !$0.isSystemEvent }.count, 1)
    }

    func testMultiPartChatReassemblesOutOfOrder() throws {
        let room = makeGeofencedRoom()
        let key = try XCTUnwrap(CryptoService.roomKey(for: room.id))
        let sender = String(repeating: "ab", count: 32)
        let sentAt = Date()
        let parts = ["The quick brown fox ", "jumps over ", "the lazy dog."]
        var texts: [String] = []
        for (index, part) in parts.enumerated() {
            let chat = FellshipEnvelope.Chat(messageID: "aabbccddeeff",
                                             memberID: sender, zoneScoped: false,
                                             text: part, sentAt: sentAt,
                                             part: UInt8(index), partCount: UInt8(parts.count))
            texts.append(try FellshipEnvelope.sealRoomPayload(.chat(chat),
                                                              roomID: room.id, roomKey: key))
        }
        // Mesh frames arrive in any order.
        for text in texts.reversed() {
            engine.handleChannelText(text)
        }
        let received = engine.messages(threadID: room.id).filter { !$0.isSystemEvent }
        XCTAssertEqual(received.count, 1, "parts must merge into one message")
        XCTAssertEqual(received.first?.text, "The quick brown fox jumps over the lazy dog.")

        // Replaying every part again must not duplicate the message.
        for text in texts {
            engine.handleChannelText(text)
        }
        XCTAssertEqual(engine.messages(threadID: room.id).filter { !$0.isSystemEvent }.count, 1)
    }

    func testDuplicateChatDeduped() throws {
        let room = makeGeofencedRoom()
        let key = try XCTUnwrap(CryptoService.roomKey(for: room.id))
        let chat = FellshipEnvelope.Chat(messageID: "3333333333333333",
                                         memberID: String(repeating: "ee", count: 32),
                                         zoneScoped: false, text: "hello", sentAt: Date())
        let text = try FellshipEnvelope.sealRoomPayload(.chat(chat), roomID: room.id, roomKey: key)
        engine.handleChannelText(text)
        engine.handleChannelText(text) // mesh flood duplicates happen
        XCTAssertEqual(engine.messages(threadID: room.id).filter { !$0.isSystemEvent }.count, 1)
    }

    func testForeignRoomTrafficIgnored() throws {
        _ = makeGeofencedRoom()
        // Traffic for a room we don't hold: same format, unknown key/ID.
        let otherKey = CryptoService.generateRoomKey()
        let otherRoomID = String(repeating: "77", count: 16)
        let chat = FellshipEnvelope.Chat(messageID: "4444444444444444",
                                         memberID: String(repeating: "ab", count: 32),
                                         zoneScoped: false, text: "not for you", sentAt: Date())
        let text = try FellshipEnvelope.sealRoomPayload(.chat(chat),
                                                        roomID: otherRoomID, roomKey: otherKey)
        engine.handleChannelText(text) // must be silently ignored
        for room in engine.rooms {
            XCTAssertTrue(engine.messages(threadID: room.id).filter { !$0.isSystemEvent }.isEmpty)
        }
    }

    // MARK: - Member announce upgrades provisional presence

    func testMemberAnnounceMigratesPrefixPresence() throws {
        let room = makeGeofencedRoom()
        let key = try XCTUnwrap(CryptoService.roomKey(for: room.id))
        let fullID = Data((0..<32).map { UInt8($0 &+ 40) }).hexEncoded

        let presence = FellshipEnvelope.Presence(memberID: fullID, isInside: true,
                                                 coordinate: nil, sentAt: Date())
        engine.handleChannelText(try FellshipEnvelope.sealRoomPayload(.presence(presence),
                                                                      roomID: room.id, roomKey: key))
        let prefixKey = String(fullID.prefix(16))
        XCTAssertNotNil(engine.presence[room.id]?[prefixKey], "unknown member keyed by prefix")

        let announce = FellshipEnvelope.MemberAnnounce(
            member: Member(id: fullID, displayName: "Robin", radioPublicKey: nil, joinedAt: Date()))
        engine.handleChannelText(try FellshipEnvelope.sealRoomPayload(.memberAnnounce(announce),
                                                                      roomID: room.id, roomKey: key))
        XCTAssertNil(engine.presence[room.id]?[prefixKey], "prefix entry migrates away")
        XCTAssertNotNil(engine.presence[room.id]?[fullID], "presence re-keyed to full ID")
        XCTAssertEqual(engine.displayName(forMemberID: fullID, roomID: room.id), "Robin")
    }

    // MARK: - QR join

    func testQRPayloadJoinsRoomOnSecondEngine() throws {
        let room = makeGeofencedRoom()
        let payload = try XCTUnwrap(engine.makeQRPayload(room: room))

        let other = RoomEngine(store: LocalStore.ephemeral(),
                               settings: AppSettings(defaults: UserDefaults(suiteName: "test-\(UUID())")!),
                               notifications: NotificationService())
        let joinedName = other.joinFromQRPayload(payload)
        XCTAssertEqual(joinedName, "Test Zone")
        XCTAssertTrue(other.rooms.contains { $0.id == room.id })
        XCTAssertNotNil(CryptoService.roomKey(for: room.id), "room key must be in Keychain after join")
        // Joiner appears in their own member list.
        XCTAssertTrue(other.members(of: room).contains { $0.id == other.myIdentityHex })
    }

    func testQRJoinRejectsGarbage() {
        XCTAssertNil(engine.joinFromQRPayload("FSQR1:!!!!"))
        XCTAssertNil(engine.joinFromQRPayload("https://example.com"))
        XCTAssertNil(engine.joinFromQRPayload(""))
    }

    // MARK: - Temporary room expiry (spec §3.2)

    func testExpiredTemporaryRoomIsSweptAndUnrecoverable() async {
        let room = engine.createRoom(name: "Flash Meet", kind: .rangeBased, boundary: nil,
                                     access: .inviteOnly, permanence: .temporary,
                                     duration: -1, // already expired
                                     sharesPreciseLocation: false)!
        XCTAssertTrue(room.isExpired)
        await engine.handleTick(fix: nil) // any tick sweeps
        XCTAssertFalse(engine.rooms.contains { $0.id == room.id })
        XCTAssertNil(CryptoService.roomKey(for: room.id), "key destroyed with the room")
    }
}
