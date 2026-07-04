import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal, dependency-free SQLite wrapper. All access is funneled through a
/// serial queue, which is the whole concurrency story — simple and sufficient
/// for this app's write volume.
final class SQLiteDatabase: @unchecked Sendable {
    enum DBError: Error {
        case openFailed(String)
        case prepareFailed(String)
        case stepFailed(String)
    }

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "app.fellship.db")

    init(path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw DBError.openFailed(message)
        }
        handle = db
        try execRaw("PRAGMA journal_mode=WAL;")
        try execRaw("PRAGMA foreign_keys=ON;")
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Default on-device database location (Application Support, backed up
    /// exclusion left to iOS defaults; room *keys* are never in this file).
    static func defaultPath() throws -> String {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask,
                                              appropriateFor: nil,
                                              create: true)
        return dir.appendingPathComponent("fellship.db").path
    }

    // MARK: - API

    func exec(_ sql: String, _ params: [SQLValue] = []) throws {
        try queue.sync {
            try run(sql, params) { _ in }
        }
    }

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [[String: SQLValue]] {
        var rows: [[String: SQLValue]] = []
        try queue.sync {
            try run(sql, params) { stmt in
                var row: [String: SQLValue] = [:]
                let count = sqlite3_column_count(stmt)
                for i in 0..<count {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, i))
                    case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(stmt, i))
                    case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                    case SQLITE_BLOB:
                        if let bytes = sqlite3_column_blob(stmt, i) {
                            row[name] = .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, i))))
                        } else {
                            row[name] = .blob(Data())
                        }
                    default: row[name] = .null
                    }
                }
                rows.append(row)
            }
        }
        return rows
    }

    // MARK: - Internals (always called on `queue`)

    private func execRaw(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let message = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw DBError.stepFailed(message)
        }
    }

    private func run(_ sql: String, _ params: [SQLValue], onRow: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }

        for (index, param) in params.enumerated() {
            let i = Int32(index + 1)
            switch param {
            case .null: sqlite3_bind_null(stmt, i)
            case .int(let v): sqlite3_bind_int64(stmt, i, v)
            case .real(let v): sqlite3_bind_double(stmt, i, v)
            case .text(let v): sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                v.withUnsafeBytes { bytes in
                    _ = sqlite3_bind_blob(stmt, i, bytes.baseAddress, Int32(v.count), SQLITE_TRANSIENT)
                }
            }
        }

        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                onRow(stmt!)
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw DBError.stepFailed(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }
}

enum SQLValue {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var intValue: Int64? { if case .int(let v) = self { return v }; return nil }
    var realValue: Double? { if case .real(let v) = self { return v }; return nil }
    var textValue: String? { if case .text(let v) = self { return v }; return nil }
    var blobValue: Data? { if case .blob(let v) = self { return v }; return nil }
}
