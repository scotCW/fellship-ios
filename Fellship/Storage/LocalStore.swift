import Foundation

/// The app's single local persistence facade: rooms, members, messages,
/// invites. Everything is on-device; deleting a room really deletes it —
/// there is no backup and no recovery path, by design (spec §1).
final class LocalStore: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(db: SQLiteDatabase) throws {
        self.db = db
        try migrate()
    }

    convenience init() throws {
        try self.init(db: SQLiteDatabase(path: SQLiteDatabase.defaultPath()))
    }

    /// In-memory store for previews and tests.
    static func ephemeral() -> LocalStore {
        // A fresh temporary file behaves like :memory: but allows WAL.
        let path = NSTemporaryDirectory() + "fellship-\(UUID().uuidString).db"
        // Force-try is acceptable here: failing to create a temp-file DB in
        // tests/previews is unrecoverable anyway.
        return try! LocalStore(db: SQLiteDatabase(path: path))
    }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS rooms (
            id TEXT PRIMARY KEY,
            json BLOB NOT NULL
        );
        """)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS members (
            room_id TEXT NOT NULL,
            member_id TEXT NOT NULL,
            json BLOB NOT NULL,
            PRIMARY KEY (room_id, member_id)
        );
        """)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            sent_at REAL NOT NULL,
            json BLOB NOT NULL
        );
        """)
        try db.exec("CREATE INDEX IF NOT EXISTS idx_messages_thread ON messages(thread_id, sent_at);")
        try db.exec("""
        CREATE TABLE IF NOT EXISTS invites (
            id TEXT PRIMARY KEY,
            json BLOB NOT NULL
        );
        """)
    }

    // MARK: - Rooms

    func saveRoom(_ room: Room) throws {
        let data = try encoder.encode(room)
        try db.exec("INSERT INTO rooms(id, json) VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET json=excluded.json;",
                    [.text(room.id), .blob(data)])
    }

    func rooms() throws -> [Room] {
        try db.query("SELECT json FROM rooms;").compactMap {
            guard let data = $0["json"]?.blobValue else { return nil }
            return try? decoder.decode(Room.self, from: data)
        }
    }

    /// Deletes the room and everything that hangs off it, including its key.
    /// Irreversible on purpose.
    func deleteRoom(_ roomID: String) throws {
        try db.exec("DELETE FROM rooms WHERE id=?;", [.text(roomID)])
        try db.exec("DELETE FROM members WHERE room_id=?;", [.text(roomID)])
        try db.exec("DELETE FROM messages WHERE thread_id=?;", [.text(roomID)])
        CryptoService.deleteRoomKey(roomID: roomID)
    }

    // MARK: - Members

    func saveMember(_ member: Member, roomID: String) throws {
        let data = try encoder.encode(member)
        try db.exec("""
        INSERT INTO members(room_id, member_id, json) VALUES(?, ?, ?)
        ON CONFLICT(room_id, member_id) DO UPDATE SET json=excluded.json;
        """, [.text(roomID), .text(member.id), .blob(data)])
    }

    func members(roomID: String) throws -> [Member] {
        try db.query("SELECT json FROM members WHERE room_id=?;", [.text(roomID)]).compactMap {
            guard let data = $0["json"]?.blobValue else { return nil }
            return try? decoder.decode(Member.self, from: data)
        }
    }

    func removeMember(_ memberID: String, roomID: String) throws {
        try db.exec("DELETE FROM members WHERE room_id=? AND member_id=?;",
                    [.text(roomID), .text(memberID)])
    }

    // MARK: - Messages

    func saveMessage(_ message: RoomMessage) throws {
        let data = try encoder.encode(message)
        try db.exec("""
        INSERT INTO messages(id, thread_id, sent_at, json) VALUES(?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET json=excluded.json;
        """, [.text(message.id), .text(message.threadID),
              .real(message.sentAt.timeIntervalSince1970), .blob(data)])
    }

    func messages(threadID: String, limit: Int = 500) throws -> [RoomMessage] {
        try db.query("""
        SELECT json FROM messages WHERE thread_id=? ORDER BY sent_at DESC LIMIT ?;
        """, [.text(threadID), .int(Int64(limit))]).compactMap {
            guard let data = $0["json"]?.blobValue else { return nil }
            return try? decoder.decode(RoomMessage.self, from: data)
        }.reversed()
    }

    /// Removes an entire message thread (used when demo artifacts are
    /// cleaned up; room threads go through deleteRoom instead).
    func deleteThread(_ threadID: String) throws {
        try db.exec("DELETE FROM messages WHERE thread_id=?;", [.text(threadID)])
    }

    /// Thread IDs that have at least one direct message, most recent first.
    func directThreadIDs() throws -> [String] {
        try db.query("""
        SELECT thread_id, MAX(sent_at) AS latest FROM messages
        WHERE json LIKE '%"scope":"direct"%'
        GROUP BY thread_id ORDER BY latest DESC;
        """).compactMap { $0["thread_id"]?.textValue }
    }

    // MARK: - Invites

    func saveInvite(_ invite: Invite) throws {
        let data = try encoder.encode(invite)
        try db.exec("INSERT INTO invites(id, json) VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET json=excluded.json;",
                    [.text(invite.id), .blob(data)])
    }

    func invites() throws -> [Invite] {
        try db.query("SELECT json FROM invites;").compactMap {
            guard let data = $0["json"]?.blobValue else { return nil }
            return try? decoder.decode(Invite.self, from: data)
        }
    }

    func deleteInvite(_ inviteID: String) throws {
        try db.exec("DELETE FROM invites WHERE id=?;", [.text(inviteID)])
    }
}
