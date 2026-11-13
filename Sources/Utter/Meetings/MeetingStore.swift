import Foundation
import SQLite3

enum Speaker: String, Sendable, Codable {
    /// Your microphone.
    case me
    /// Everything the Mac played: the other people on the call.
    case them
    var title: String { self == .me ? "Me" : "Them" }
}

struct Meeting: Identifiable, Sendable, Equatable {
    let id: String
    var title: String
    var started: Date
    var ended: Date?
    /// What the user typed during the meeting.
    var notes: String = ""
    /// Notes written from the transcript and the user's notes, as Markdown.
    var enhanced: String = ""
    var template: String = MeetingTemplate.general.id
}

struct TranscriptSegment: Identifiable, Sendable, Equatable {
    var id: Int64 = 0
    let meeting: String
    let speaker: Speaker
    /// Seconds from the start of the meeting.
    let start: TimeInterval
    let text: String
}

struct ChatMessage: Identifiable, Sendable, Equatable {
    var id: Int64 = 0
    /// A meeting ID, or empty for questions asked across all meetings.
    let meeting: String
    let fromUser: Bool
    let text: String
}

enum MeetingStoreError: LocalizedError {
    case database
    var errorDescription: String? { "Meeting notes could not be read or saved." }
}

private final class MeetingConnection {
    let handle: OpaquePointer
    init(url: URL) throws {
        var pointer: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw MeetingStoreError.database
        }
        handle = pointer
    }
    deinit { sqlite3_close(handle) }
}

/// Meetings, their transcripts, notes and questions, kept in a local SQLite file. Audio is never stored.
actor MeetingStore {
    private let directory: URL
    private var connection: MeetingConnection?
    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Utter/Meetings", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    private func database() throws -> OpaquePointer {
        if let connection { return connection.handle }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: "meetings.sqlite")
        let next = try MeetingConnection(url: url)
        let schema = """
        PRAGMA secure_delete=ON;
        CREATE TABLE IF NOT EXISTS meetings (id TEXT PRIMARY KEY, title TEXT NOT NULL, started REAL NOT NULL, ended REAL,
            notes TEXT NOT NULL DEFAULT '', enhanced TEXT NOT NULL DEFAULT '', template TEXT NOT NULL DEFAULT '');
        CREATE TABLE IF NOT EXISTS segments (id INTEGER PRIMARY KEY AUTOINCREMENT, meeting TEXT NOT NULL, speaker TEXT NOT NULL,
            start REAL NOT NULL, text TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS segments_meeting ON segments(meeting, start);
        CREATE TABLE IF NOT EXISTS chat (id INTEGER PRIMARY KEY AUTOINCREMENT, meeting TEXT NOT NULL, user INTEGER NOT NULL, text TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS chat_meeting ON chat(meeting, id);
        """
        guard sqlite3_exec(next.handle, schema, nil, nil, nil) == SQLITE_OK else { throw MeetingStoreError.database }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        connection = next
        return next.handle
    }

    /// Runs one statement. Text and number arguments bind in order; `row` is called for each result row.
    private func run(_ sql: String, _ arguments: [Any?] = [], row: ((OpaquePointer) -> Void)? = nil) throws {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(try database(), sql, -1, &pointer, nil) == SQLITE_OK, let statement = pointer else {
            throw MeetingStoreError.database
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch argument {
            case let text as String: code = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case let number as Double: code = sqlite3_bind_double(statement, index, number)
            case let number as Int64: code = sqlite3_bind_int64(statement, index, number)
            case let flag as Bool: code = sqlite3_bind_int64(statement, index, flag ? 1 : 0)
            case nil: code = sqlite3_bind_null(statement, index)
            default: throw MeetingStoreError.database
            }
            guard code == SQLITE_OK else { throw MeetingStoreError.database }
        }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw MeetingStoreError.database }
            row?(statement)
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    // MARK: Meetings

    func save(_ meeting: Meeting) throws {
        try run("""
        INSERT INTO meetings (id,title,started,ended,notes,enhanced,template) VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET title=excluded.title, started=excluded.started, ended=excluded.ended,
            notes=excluded.notes, enhanced=excluded.enhanced, template=excluded.template
        """, [meeting.id, meeting.title, meeting.started.timeIntervalSince1970, meeting.ended?.timeIntervalSince1970,
              meeting.notes, meeting.enhanced, meeting.template])
    }

    /// Newest first. A search matches titles, both kinds of notes and transcripts, ignoring case.
    func meetings(search: String = "") throws -> [Meeting] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [Meeting] = []
        try run("""
        SELECT id,title,started,ended,notes,enhanced,template FROM meetings
        WHERE ?1 = '' OR instr(lower(title || ' ' || notes || ' ' || enhanced), lower(?1)) > 0
            OR id IN (SELECT meeting FROM segments WHERE instr(lower(text), lower(?1)) > 0)
        ORDER BY started DESC
        """, [query]) { row in
            result.append(Meeting(id: Self.text(row, 0), title: Self.text(row, 1),
                                  started: Date(timeIntervalSince1970: sqlite3_column_double(row, 2)),
                                  ended: sqlite3_column_type(row, 3) == SQLITE_NULL ? nil
                                      : Date(timeIntervalSince1970: sqlite3_column_double(row, 3)),
                                  notes: Self.text(row, 4), enhanced: Self.text(row, 5), template: Self.text(row, 6)))
        }
        return result
    }

    func meeting(id: String) throws -> Meeting? { try meetings().first { $0.id == id } }

    /// Removes the meeting with its transcript and questions.
    func delete(meeting id: String) throws {
        for table in ["segments WHERE meeting", "chat WHERE meeting", "meetings WHERE id"] {
            try run("DELETE FROM \(table) = ?", [id])
        }
    }

    // MARK: Transcript

    @discardableResult
    func add(_ segment: TranscriptSegment) throws -> TranscriptSegment {
        try run("INSERT INTO segments (meeting,speaker,start,text) VALUES (?,?,?,?)",
                [segment.meeting, segment.speaker.rawValue, segment.start, segment.text])
        var saved = segment
        saved.id = sqlite3_last_insert_rowid(try database())
        return saved
    }

    /// In spoken order, whatever order the pieces were transcribed in.
    func segments(meeting: String) throws -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        try run("SELECT id,speaker,start,text FROM segments WHERE meeting = ? ORDER BY start, id", [meeting]) { row in
            result.append(TranscriptSegment(id: sqlite3_column_int64(row, 0), meeting: meeting,
                                            speaker: Speaker(rawValue: Self.text(row, 1)) ?? .them,
                                            start: sqlite3_column_double(row, 2), text: Self.text(row, 3)))
        }
        return result
    }

    func delete(segment id: Int64) throws { try run("DELETE FROM segments WHERE id = ?", [id]) }

    /// Transcript lines containing any of `words`, best matches first, for questions asked across meetings.
    func matchingSegments(words: [String], limit: Int = 40) throws -> [TranscriptSegment] {
        let terms = Array(Set(words.map { $0.lowercased() }.filter { $0.count > 2 })).sorted().prefix(12)
        guard !terms.isEmpty else { return [] }
        let score = terms.map { _ in "(instr(lower(text), ?) > 0)" }.joined(separator: " + ")
        var result: [TranscriptSegment] = []
        try run("SELECT id,meeting,speaker,start,text, (\(score)) AS hits FROM segments WHERE hits > 0 ORDER BY hits DESC, id DESC LIMIT \(max(1, limit))",
                terms.map { $0 as Any? }) { row in
            result.append(TranscriptSegment(id: sqlite3_column_int64(row, 0), meeting: Self.text(row, 1),
                                            speaker: Speaker(rawValue: Self.text(row, 2)) ?? .them,
                                            start: sqlite3_column_double(row, 3), text: Self.text(row, 4)))
        }
        return result
    }

    // MARK: Questions

    func add(_ message: ChatMessage) throws {
        try run("INSERT INTO chat (meeting,user,text) VALUES (?,?,?)", [message.meeting, message.fromUser, message.text])
    }

    func chat(meeting: String) throws -> [ChatMessage] {
        var result: [ChatMessage] = []
        try run("SELECT id,user,text FROM chat WHERE meeting = ? ORDER BY id", [meeting]) { row in
            result.append(ChatMessage(id: sqlite3_column_int64(row, 0), meeting: meeting,
                                      fromUser: sqlite3_column_int64(row, 1) != 0, text: Self.text(row, 2)))
        }
        return result
    }

    func clearChat(meeting: String) throws { try run("DELETE FROM chat WHERE meeting = ?", [meeting]) }
}
