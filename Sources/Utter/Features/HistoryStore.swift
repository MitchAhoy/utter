import Foundation
import SQLite3

struct HistoryEntry: Identifiable, Sendable, Equatable {
    let id: String
    let created: Date
    let app: String
    let bundleID: String
    let raw: String
    let cleaned: String
    let path: String
}
enum HistoryError: LocalizedError {
    case database
    var errorDescription: String? { "Dictation history could not be read or saved." }
}
private final class HistoryConnection {
    let handle: OpaquePointer
    init(url: URL) throws {
        var pointer: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw HistoryError.database
        }
        handle = pointer
    }
    deinit { sqlite3_close(handle) }
}
actor HistoryStore {
    private let directory: URL
    private var connection: HistoryConnection?
    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Utter/History", directoryHint: .isDirectory)) {
        self.directory = directory
    }
    private func database() throws -> OpaquePointer {
        if let connection { return connection.handle }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: "history.sqlite")
        let next = try HistoryConnection(url: url)
        guard sqlite3_exec(next.handle, "PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS entries (id TEXT PRIMARY KEY, created REAL NOT NULL, app TEXT NOT NULL, bundle TEXT NOT NULL, raw TEXT NOT NULL, cleaned TEXT NOT NULL, path TEXT NOT NULL); CREATE INDEX IF NOT EXISTS entries_created ON entries(created);", nil, nil, nil) == SQLITE_OK else {
            throw HistoryError.database
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        connection = next
        return next.handle
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(try database(), sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw HistoryError.database }
        return pointer
    }
    private func bind(_ text: String, at index: Int32, to statement: OpaquePointer) throws {
        let result = text.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard result == SQLITE_OK else { throw HistoryError.database }
    }
    func insert(_ entry: HistoryEntry, retentionDays: Int) throws {
        try prune(retentionDays: retentionDays)
        let query = try statement("INSERT INTO entries (id,created,app,bundle,raw,cleaned,path) VALUES (?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(query) }
        try bind(entry.id, at: 1, to: query)
        sqlite3_bind_double(query, 2, entry.created.timeIntervalSince1970)
        for (offset, text) in [entry.app, entry.bundleID, entry.raw, entry.cleaned, entry.path].enumerated() {
            try bind(text, at: Int32(offset + 3), to: query)
        }
        guard sqlite3_step(query) == SQLITE_DONE else { throw HistoryError.database }
    }
    func entries(search: String = "", retentionDays: Int = 7) throws -> [HistoryEntry] {
        try prune(retentionDays: retentionDays)
        let query = try statement("SELECT id,created,app,bundle,raw,cleaned,path FROM entries WHERE ? = '' OR instr(lower(raw || ' ' || cleaned || ' ' || app), lower(?)) > 0 ORDER BY created DESC LIMIT 200")
        defer { sqlite3_finalize(query) }
        try bind(search, at: 1, to: query); try bind(search, at: 2, to: query)
        var result: [HistoryEntry] = []
        func text(_ column: Int32) -> String {
            guard let pointer = sqlite3_column_text(query, column) else { return "" }
            return String(cString: pointer)
        }
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw HistoryError.database }
            result.append(HistoryEntry(id: text(0), created: Date(timeIntervalSince1970: sqlite3_column_double(query, 1)),
                                       app: text(2), bundleID: text(3), raw: text(4), cleaned: text(5), path: text(6)))
        }
        return result
    }
    func prune(retentionDays: Int, now: Date = Date()) throws {
        let query = try statement("DELETE FROM entries WHERE created < ?")
        defer { sqlite3_finalize(query) }
        let cutoff = now.addingTimeInterval(-Double(max(1, min(365, retentionDays))) * 86_400)
        sqlite3_bind_double(query, 1, cutoff.timeIntervalSince1970)
        guard sqlite3_step(query) == SQLITE_DONE else { throw HistoryError.database }
    }
    func clear() throws {
        let db = try database()
        guard sqlite3_exec(db, "DELETE FROM entries; VACUUM;", nil, nil, nil) == SQLITE_OK else { throw HistoryError.database }
    }
    func update(id: String, cleaned: String) throws {
        let query = try statement("UPDATE entries SET cleaned = ? WHERE id = ?")
        defer { sqlite3_finalize(query) }
        try bind(cleaned, at: 1, to: query); try bind(id, at: 2, to: query)
        guard sqlite3_step(query) == SQLITE_DONE else { throw HistoryError.database }
    }
}
