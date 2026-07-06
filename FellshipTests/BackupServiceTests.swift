import XCTest
import CryptoKit
@testable import Fellship

final class BackupServiceTests: XCTestCase {
    private func makePayload() -> BackupService.Payload {
        let room = Room(id: String(repeating: "ab", count: 16), name: "Cabin",
                        kind: .geofenced,
                        boundary: .circle(center: Coordinate(latitude: 37, longitude: -122),
                                          radiusMeters: 500),
                        access: .inviteOnly, permanence: .permanent, expiresAt: nil,
                        sharesPreciseLocation: true, isMuted: false,
                        createdAt: Date(), creatorID: "me")
        return BackupService.Payload(
            displayName: "Alex",
            identityKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
            rooms: [room],
            membersByRoom: [room.id: [Member(id: "m1", displayName: "Robin",
                                             radioPublicKey: nil, joinedAt: Date())]],
            messages: [RoomMessage(id: "msg1", threadID: room.id, scope: .room,
                                   senderID: "m1", senderName: "Robin", text: "hi",
                                   sentAt: Date(), delivery: .received, isFromMe: false)],
            roomKeys: [room.id: CryptoService.generateRoomKey().dataRepresentation])
    }

    func testRoundTrip() throws {
        let payload = makePayload()
        let file = try BackupService.encrypt(payload, passphrase: "correct horse battery")
        XCTAssertTrue(file.prefix(5) == BackupService.magic)
        let restored = try BackupService.decrypt(file, passphrase: "correct horse battery")
        XCTAssertEqual(restored.rooms.first?.id, payload.rooms.first?.id)
        XCTAssertEqual(restored.roomKeys, payload.roomKeys)
        XCTAssertEqual(restored.identityKey, payload.identityKey)
        XCTAssertEqual(restored.messages.count, 1)
        XCTAssertEqual(restored.displayName, "Alex")
    }

    func testWrongPassphraseRejected() throws {
        let file = try BackupService.encrypt(makePayload(), passphrase: "right")
        XCTAssertThrowsError(try BackupService.decrypt(file, passphrase: "wrong")) { error in
            XCTAssertEqual(error as? BackupService.BackupError, .wrongPassphrase)
        }
    }

    func testTamperedFileRejected() throws {
        var file = try BackupService.encrypt(makePayload(), passphrase: "pass")
        file[file.count - 1] ^= 0xFF
        XCTAssertThrowsError(try BackupService.decrypt(file, passphrase: "pass"))
    }

    func testGarbageAndEmptyPassphraseRejected() {
        XCTAssertThrowsError(try BackupService.decrypt(Data("not a backup".utf8), passphrase: "x")) { error in
            XCTAssertEqual(error as? BackupService.BackupError, .malformedFile)
        }
        XCTAssertThrowsError(try BackupService.encrypt(makePayload(), passphrase: "")) { error in
            XCTAssertEqual(error as? BackupService.BackupError, .emptyPassphrase)
        }
    }

    func testKeyDerivationDeterministicPerSalt() {
        let salt1 = Data(repeating: 1, count: 16)
        let salt2 = Data(repeating: 2, count: 16)
        let a = BackupService.deriveKey(passphrase: "p", salt: salt1)
        let b = BackupService.deriveKey(passphrase: "p", salt: salt1)
        let c = BackupService.deriveKey(passphrase: "p", salt: salt2)
        XCTAssertEqual(a.dataRepresentation, b.dataRepresentation)
        XCTAssertNotEqual(a.dataRepresentation, c.dataRepresentation)
    }

    @MainActor
    func testRestoreMergesIntoEngine() throws {
        // Keychain needed — same skip logic as the engine tests.
        let probe = KeychainStore(service: "app.fellship.tests")
        do {
            try probe.save(Data([1]), for: "probe")
            probe.delete("probe")
        } catch {
            throw XCTSkip("Keychain unavailable in this test host")
        }

        let engine = RoomEngine(store: LocalStore.ephemeral(),
                                settings: AppSettings(defaults: UserDefaults(suiteName: "bk-\(UUID())")!),
                                notifications: NotificationService())
        let payload = makePayload()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "bk2-\(UUID())")!)
        let summary = BackupService.restore(payload, engine: engine, settings: settings)
        XCTAssertTrue(summary.contains("1 room"), summary)
        XCTAssertTrue(engine.rooms.contains { $0.id == payload.rooms[0].id })
        XCTAssertNotNil(CryptoService.roomKey(for: payload.rooms[0].id))
        XCTAssertEqual(engine.messages(threadID: payload.rooms[0].id).count, 1)

        // Restoring the same backup again must not duplicate anything.
        _ = BackupService.restore(payload, engine: engine, settings: settings)
        XCTAssertEqual(engine.rooms.filter { $0.id == payload.rooms[0].id }.count, 1)
        XCTAssertEqual(engine.messages(threadID: payload.rooms[0].id).count, 1)

        CryptoService.deleteRoomKey(roomID: payload.rooms[0].id)
    }
}
