import XCTest
@testable import Fellship

final class StoreAndDomainTests: XCTestCase {
    var store: LocalStore!

    override func setUp() {
        super.setUp()
        store = LocalStore.ephemeral()
    }

    func makeRoom(id: String = "aabbccddeeff00112233445566778899",
                  permanence: Permanence = .permanent,
                  expiresAt: Date? = nil) -> Room {
        Room(id: id, name: "Test", kind: .geofenced,
             boundary: .circle(center: Coordinate(latitude: 37, longitude: -122), radiusMeters: 100),
             access: .inviteOnly, permanence: permanence, expiresAt: expiresAt,
             sharesPreciseLocation: true, isMuted: false, createdAt: Date(), creatorID: "me")
    }

    func testRoomCRUD() throws {
        let room = makeRoom()
        try store.saveRoom(room)
        XCTAssertEqual(try store.rooms(), [room])

        var updated = room
        updated.isMuted = true
        try store.saveRoom(updated)
        XCTAssertEqual(try store.rooms().first?.isMuted, true)
        XCTAssertEqual(try store.rooms().count, 1)

        try store.deleteRoom(room.id)
        XCTAssertTrue(try store.rooms().isEmpty)
    }

    func testDeleteRoomCascades() throws {
        let room = makeRoom()
        try store.saveRoom(room)
        try store.saveMember(Member(id: "m1", displayName: "Robin",
                                    radioPublicKey: nil, joinedAt: Date()), roomID: room.id)
        try store.saveMessage(RoomMessage(id: "msg1", threadID: room.id, scope: .room,
                                          senderID: "m1", senderName: "Robin", text: "hi",
                                          sentAt: Date(), delivery: .received, isFromMe: false))
        try store.deleteRoom(room.id)
        XCTAssertTrue(try store.members(roomID: room.id).isEmpty)
        XCTAssertTrue(try store.messages(threadID: room.id).isEmpty)
    }

    func testMemberUpsert() throws {
        let room = makeRoom()
        try store.saveRoom(room)
        let member = Member(id: "m1", displayName: "Robin", radioPublicKey: nil, joinedAt: Date())
        try store.saveMember(member, roomID: room.id)
        var renamed = member
        renamed.displayName = "Robin H."
        try store.saveMember(renamed, roomID: room.id)
        let members = try store.members(roomID: room.id)
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members.first?.displayName, "Robin H.")
    }

    func testMessagesOrderedBySentAt() throws {
        let thread = "thread1"
        for (index, offset) in [30.0, 10.0, 20.0].enumerated() {
            try store.saveMessage(RoomMessage(id: "m\(index)", threadID: thread, scope: .room,
                                              senderID: "s", senderName: "S", text: "\(index)",
                                              sentAt: Date(timeIntervalSince1970: offset),
                                              delivery: .received, isFromMe: false))
        }
        let messages = try store.messages(threadID: thread)
        XCTAssertEqual(messages.map(\.text), ["1", "2", "0"])
    }

    func testDirectThreadDiscovery() throws {
        try store.saveMessage(RoomMessage(id: "d1", threadID: "peerA", scope: .direct,
                                          senderID: "peerA", senderName: "A", text: "hey",
                                          sentAt: Date(), delivery: .received, isFromMe: false))
        try store.saveMessage(RoomMessage(id: "r1", threadID: "roomX", scope: .room,
                                          senderID: "s", senderName: "S", text: "room msg",
                                          sentAt: Date(), delivery: .received, isFromMe: false))
        let threads = try store.directThreadIDs()
        XCTAssertEqual(threads, ["peerA"])
    }

    func testInvitePersistence() throws {
        let invite = Invite(id: "i1", roomID: "r1", roomName: "Cabin", roomKind: .geofenced,
                            access: .inviteOnly, peerRadioKey: "aa", peerIdentityKey: nil,
                            peerName: "Ash", state: .received, isOutgoing: false,
                            isAutomatic: false, createdAt: Date())
        try store.saveInvite(invite)
        XCTAssertEqual(try store.invites(), [invite])
        try store.deleteInvite("i1")
        XCTAssertTrue(try store.invites().isEmpty)
    }

    // MARK: - Domain rules

    func testRoomExpiry() {
        XCTAssertFalse(makeRoom().isExpired)
        XCTAssertTrue(makeRoom(permanence: .temporary,
                               expiresAt: Date(timeIntervalSinceNow: -1)).isExpired)
        XCTAssertFalse(makeRoom(permanence: .temporary,
                                expiresAt: Date(timeIntervalSinceNow: 60)).isExpired)
    }

    func testPresenceFreshnessWindow() {
        let now = Date()
        let presence = MemberPresence(memberID: "m", isInside: true,
                                      coordinate: nil,
                                      lastHeard: now.addingTimeInterval(-100))
        // 60s interval → window is max(180, 90) = 180s → still fresh at 100s.
        XCTAssertTrue(presence.isFresh(interval: 60, now: now))
        // 20s interval → window is max(60, 90) = 90s → stale at 100s.
        XCTAssertFalse(presence.isFresh(interval: 20, now: now))
    }

    func testOfflineEstimateSanity() {
        // One small area at a single zoom: at least 1 tile, sane byte figure.
        let estimate = OfflineMapManager.estimate(
            southWest: Coordinate(latitude: 37.76, longitude: -122.49),
            northEast: Coordinate(latitude: 37.78, longitude: -122.47),
            fromZoom: 12, toZoom: 12)
        XCTAssertGreaterThanOrEqual(estimate.tiles, 1)
        XCTAssertLessThan(estimate.tiles, 50)

        // Adding zoom levels strictly grows the count.
        let deeper = OfflineMapManager.estimate(
            southWest: Coordinate(latitude: 37.76, longitude: -122.49),
            northEast: Coordinate(latitude: 37.78, longitude: -122.47),
            fromZoom: 12, toZoom: 15)
        XCTAssertGreaterThan(deeper.tiles, estimate.tiles)
    }

    func testTileTemplateValidation() {
        XCTAssertTrue(TileSourceResolver.isValidTemplate("https://tiles.example.com/{z}/{x}/{y}.png?key=abc"))
        XCTAssertFalse(TileSourceResolver.isValidTemplate("https://tiles.example.com/tiles.png"))
        XCTAssertFalse(TileSourceResolver.isValidTemplate("ftp://bad/{z}/{x}/{y}"))
        XCTAssertFalse(TileSourceResolver.isValidTemplate(""))
    }

    func testNasaTemplateUsesYesterdayUTC() {
        let template = TileSourceResolver.nasaTileTemplate(date: Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertTrue(template.contains("gibs.earthdata.nasa.gov"))
        XCTAssertTrue(template.contains("{z}/{y}/{x}"))
        // 1_750_000_000 = 2025-06-15 UTC → yesterday = 2025-06-14.
        XCTAssertTrue(template.contains("2025-06-14"))
    }
}
