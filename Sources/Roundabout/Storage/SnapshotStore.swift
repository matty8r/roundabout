import Foundation
import SQLite3

final class SnapshotStore {
    private var db: OpaquePointer?
    private let path: String

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Roundabout", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("roundabout.sqlite3").path

        if sqlite3_open(path, &db) != SQLITE_OK {
            Log.write("Failed to open db at \(path)\n")
        }
        createTableIfNeeded()
    }

    deinit {
        sqlite3_close(db)
    }

    private func createTableIfNeeded() {
        let sql = """
        CREATE TABLE IF NOT EXISTS snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source TEXT NOT NULL,
            app TEXT,
            title TEXT,
            cwd TEXT,
            tty TEXT,
            timestamp REAL NOT NULL,
            is_frontmost_tab INTEGER NOT NULL DEFAULT 0,
            process_name TEXT,
            url TEXT,
            is_active_now INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_snapshots_timestamp ON snapshots(timestamp);
        """
        var errMsg: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown error"
            Log.write("Failed to create table: \(msg)\n")
            sqlite3_free(errMsg)
        }
    }

    func insert(_ snapshot: Snapshot) {
        let sql = """
        INSERT INTO snapshots (source, app, title, cwd, tty, timestamp, is_frontmost_tab, process_name, url, is_active_now)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, snapshot.source, -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, 2, snapshot.app)
        bindOptionalText(stmt, 3, snapshot.title)
        bindOptionalText(stmt, 4, snapshot.cwd)
        bindOptionalText(stmt, 5, snapshot.tty)
        sqlite3_bind_double(stmt, 6, snapshot.timestamp.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 7, snapshot.isFrontmostTab ? 1 : 0)
        bindOptionalText(stmt, 8, snapshot.processName)
        bindOptionalText(stmt, 9, snapshot.url)
        sqlite3_bind_int(stmt, 10, snapshot.isActiveNow ? 1 : 0)

        if sqlite3_step(stmt) != SQLITE_DONE {
            Log.write("Insert failed: \(String(cString: sqlite3_errmsg(db)))\n")
        }
    }

    func recentSnapshots(since: Date) -> [Snapshot] {
        let sql = """
        SELECT source, app, title, cwd, tty, timestamp, is_frontmost_tab, process_name, url, is_active_now
        FROM snapshots WHERE timestamp >= ? ORDER BY timestamp ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)

        var results: [Snapshot] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let source = String(cString: sqlite3_column_text(stmt, 0))
            let app = columnText(stmt, 1)
            let title = columnText(stmt, 2)
            let cwd = columnText(stmt, 3)
            let tty = columnText(stmt, 4)
            let ts = sqlite3_column_double(stmt, 5)
            let isFrontmostTab = sqlite3_column_int(stmt, 6) != 0
            let processName = columnText(stmt, 7)
            let url = columnText(stmt, 8)
            let isActiveNow = sqlite3_column_int(stmt, 9) != 0
            results.append(Snapshot(
                source: source, app: app, title: title, cwd: cwd, tty: tty,
                timestamp: Date(timeIntervalSince1970: ts),
                isFrontmostTab: isFrontmostTab, processName: processName, url: url,
                isActiveNow: isActiveNow
            ))
        }
        return results
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
