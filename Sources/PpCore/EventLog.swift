import Foundation
import SQLite3

/// Storage for what pp has done. SQLite for querying, with a JSONL export for the
/// "give me my data" and "delete everything" promises.
public protocol EventStoring: AnyObject {
    func append(_ event: InteractionEvent) throws
    func recent(_ limit: Int) throws -> [InteractionEvent]
    func count() throws -> Int
    func deleteAll() throws
    func export() throws -> Data
}

public enum EventLogError: LocalizedError, Equatable {
    case openFailed(String)
    case sqlite(String)
    case schemaTooNew(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path): return "Could not open the pp history database at \(path)."
        case .sqlite(let message): return "History database error: \(message)"
        case .schemaTooNew(let found, let supported):
            return "The history database was written by a newer version of pp (schema \(found), this build understands \(supported))."
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Append-only local history. Never leaves the machine.
public final class EventLog: EventStoring {
    public static let currentSchema = 1

    private var db: OpaquePointer?
    private let lock = NSLock()

    public static var defaultPath: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("pp/history.sqlite")
    }

    public convenience init(path: URL = EventLog.defaultPath) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(storage: .file(path.path))
    }

    /// In-memory log, for tests and for a "do not keep history" mode.
    public static func inMemory() throws -> EventLog {
        try EventLog(storage: .memory)
    }

    private enum Storage {
        case file(String)
        case memory
    }

    private init(storage: Storage) throws {
        let path = { if case .file(let path) = storage { return path } else { return ":memory:" } }()
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw EventLogError.openFailed(path)
        }
        try migrate()
    }

    deinit { sqlite3_close(db) }

    private func migrate() throws {
        let existing = try schemaVersion()
        if existing > Self.currentSchema {
            throw EventLogError.schemaTooNew(found: existing, supported: Self.currentSchema)
        }
        try execute("""
        CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS events (
            id TEXT PRIMARY KEY,
            at REAL NOT NULL,
            clause TEXT NOT NULL,
            app TEXT NOT NULL,
            structure_fingerprint TEXT NOT NULL,
            action_kind TEXT NOT NULL,
            target_label TEXT,
            succeeded INTEGER NOT NULL,
            step_signature TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS events_at ON events (at DESC);
        CREATE INDEX IF NOT EXISTS events_signature ON events (step_signature);
        """)
        if existing == 0 {
            try execute("INSERT INTO schema_version (version) VALUES (\(Self.currentSchema));")
        }
    }

    private func schemaVersion() throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_version';"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }

        var version: Int32 = 0
        var versionStatement: OpaquePointer?
        defer { sqlite3_finalize(versionStatement) }
        guard sqlite3_prepare_v2(db, "SELECT version FROM schema_version ORDER BY rowid DESC LIMIT 1;", -1, &versionStatement, nil) == SQLITE_OK,
              sqlite3_step(versionStatement) == SQLITE_ROW else { return 0 }
        version = sqlite3_column_int(versionStatement, 0)
        return Int(version)
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw EventLogError.sqlite(message)
        }
    }

    public func append(_ event: InteractionEvent) throws {
        guard let cleaned = PrivacyFilter.cleaned(event) else { return }
        lock.lock(); defer { lock.unlock() }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "INSERT OR REPLACE INTO events (id, at, clause, app, structure_fingerprint, action_kind, target_label, succeeded, step_signature) VALUES (?,?,?,?,?,?,?,?,?);"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw EventLogError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(statement, 1, cleaned.id.uuidString, -1, sqliteTransient)
        // Reference-date seconds, matching PpJSON: a 1970-based double would come back
        // one ULP different for many wall-clock times, and the stored history would
        // slowly drift from the values the app compares against.
        sqlite3_bind_double(statement, 2, cleaned.at.timeIntervalSinceReferenceDate)
        sqlite3_bind_text(statement, 3, cleaned.clause, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, cleaned.app, -1, sqliteTransient)
        sqlite3_bind_text(statement, 5, cleaned.structureFingerprint, -1, sqliteTransient)
        sqlite3_bind_text(statement, 6, cleaned.actionKind, -1, sqliteTransient)
        if let label = cleaned.targetLabel {
            sqlite3_bind_text(statement, 7, label, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 7)
        }
        sqlite3_bind_int(statement, 8, cleaned.succeeded ? 1 : 0)
        sqlite3_bind_text(statement, 9, cleaned.stepSignature, -1, sqliteTransient)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw EventLogError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func recent(_ limit: Int) throws -> [InteractionEvent] {
        let limit = max(limit, 0)
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT id, at, clause, app, structure_fingerprint, action_kind, target_label, succeeded, step_signature FROM events ORDER BY at DESC LIMIT ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw EventLogError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        // Int32(clamping:) so "export everything" cannot trap on the way to SQLite.
        sqlite3_bind_int(statement, 1, Int32(clamping: limit))

        var results: [InteractionEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = UUID(uuidString: String(cString: sqlite3_column_text(statement, 0))) ?? UUID()
            let at = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1))
            let clause = String(cString: sqlite3_column_text(statement, 2))
            let app = String(cString: sqlite3_column_text(statement, 3))
            let fingerprint = String(cString: sqlite3_column_text(statement, 4))
            let kind = String(cString: sqlite3_column_text(statement, 5))
            let label = sqlite3_column_text(statement, 6).map { String(cString: $0) }
            let succeeded = sqlite3_column_int(statement, 7) == 1
            let signature = String(cString: sqlite3_column_text(statement, 8))
            results.append(InteractionEvent(id: id, at: at, clause: clause, app: app,
                                            structureFingerprint: fingerprint, actionKind: kind,
                                            targetLabel: label, succeeded: succeeded, stepSignature: signature))
        }
        return results
    }

    public func count() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM events;", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw EventLogError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        try execute("DELETE FROM events;")
    }

    /// Complete, importable export of everything stored.
    public func export() throws -> Data {
        let all = try recent(Int.max)
        return try PpJSON.encoder(pretty: true).encode(all)
    }
}
