import Foundation
import SQLite3

/// Read-only access to the bundled FTS5 corpus (`corpus.sqlite`).
///
/// One connection per app instance, opened read-only so a corrupted or partially
/// written file can never be "repaired" into a different shape at runtime. All
/// statements are prepared once and reused where it matters.
public final class CorpusStore {

    public struct Passage: Equatable {
        public let chunkID: Int
        public let docID: Int
        public let title: String
        public let url: String
        public let text: String
        /// Higher is better (FTS5 `bm25()` negated: bm25 returns negative numbers).
        public let score: Double
    }

    public struct DocRef: Equatable {
        public let id: Int
        public let title: String
        public let url: String
    }

    private var db: OpaquePointer?
    private let lock = NSLock()
    public let url: URL

    public enum StoreError: LocalizedError {
        case cannotOpen(String)
        case sqlite(String)
        case missingTable(String)

        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let path): return "Could not open corpus at \(path)"
            case .sqlite(let message): return "SQLite error: \(message)"
            case .missingTable(let name): return "Corpus is missing table \(name)"
            }
        }
    }

    public init(url: URL) throws {
        self.url = url
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if handle != nil { sqlite3_close(handle) }
            throw StoreError.cannotOpen("\(url.lastPathComponent): \(message)")
        }
        self.db = handle
        try validate()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func validate() throws {
        let required = ["meta", "docs", "chunks", "chunks_fts"]
        let found = try Set(tableNames())
        for table in required where !found.contains(table) {
            throw StoreError.missingTable(table)
        }
    }

    // MARK: - Queries

    public func search(expression: String, limit: Int = 60) throws -> [Passage] {
        guard !expression.isEmpty else { return [] }
        let sql = """
        SELECT c.id, c.doc_id, d.title, d.url, c.text, bm25(chunks_fts) AS rank
        FROM chunks_fts
        JOIN chunks c ON c.id = chunks_fts.rowid
        JOIN docs d ON d.id = c.doc_id
        WHERE chunks_fts MATCH ?
        ORDER BY rank
        LIMIT ?;
        """
        return try withLock {
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, expression, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var out: [Passage] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    out.append(
                        Passage(
                            chunkID: Int(sqlite3_column_int64(stmt, 0)),
                            docID: Int(sqlite3_column_int64(stmt, 1)),
                            title: text(stmt, 2),
                            url: text(stmt, 3),
                            text: text(stmt, 4),
                            score: -sqlite3_column_double(stmt, 5)
                        )
                    )
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw StoreError.sqlite(lastErrorMessage)
                }
            }
            return out
        }
    }

    /// Fallback lookup used when FTS returns nothing (typo, unknown word, very
    /// short query). Slightly fuzzy: substring match on the title only.
    public func findDocs(titleContaining needle: String, limit: Int = 8) throws -> [DocRef] {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return [] }
        let sql = "SELECT id, title, url FROM docs WHERE title LIKE ? ESCAPE '\\' ORDER BY length(title) LIMIT ?;"
        let pattern = "%" + trimmed.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        return try withLock {
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var out: [DocRef] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(DocRef(id: Int(sqlite3_column_int64(stmt, 0)), title: text(stmt, 1), url: text(stmt, 2)))
            }
            return out
        }
    }

    public func chunks(forDoc docID: Int) throws -> [Passage] {
        let sql = """
        SELECT c.id, c.doc_id, d.title, d.url, c.text
        FROM chunks c JOIN docs d ON d.id = c.doc_id
        WHERE c.doc_id = ? ORDER BY c.ordinal LIMIT 12;
        """
        return try withLock {
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(docID))
            var out: [Passage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(
                    Passage(
                        chunkID: Int(sqlite3_column_int64(stmt, 0)),
                        docID: Int(sqlite3_column_int64(stmt, 1)),
                        title: text(stmt, 2),
                        url: text(stmt, 3),
                        text: text(stmt, 4),
                        score: 0
                    )
                )
            }
            return out
        }
    }

    public func metadata() throws -> [String: String] {
        try withLock {
            let stmt = try prepare("SELECT key, value FROM meta;")
            defer { sqlite3_finalize(stmt) }
            var out: [String: String] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                out[text(stmt, 0)] = text(stmt, 1)
            }
            return out
        }
    }

    public func articleCount() throws -> Int { try scalar("SELECT count(*) FROM docs;") }
    public func chunkCount() throws -> Int { try scalar("SELECT count(*) FROM chunks;") }

    public func integrityCheck() throws -> String {
        try withLock {
            let stmt = try prepare("PRAGMA quick_check;")
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return "unknown" }
            return text(stmt, 0)
        }
    }

    // MARK: - Plumbing

    private func tableNames() throws -> [String] {
        let stmt = try prepare("SELECT name FROM sqlite_master WHERE type IN ('table','view');")
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(text(stmt, 0)) }
        return out
    }

    private func scalar(_ sql: String) throws -> Int {
        try withLock {
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqlite(lastErrorMessage)
        }
        return stmt
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    private var lastErrorMessage: String {
        guard let db else { return "no connection" }
        return String(cString: sqlite3_errmsg(db))
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// `SQLITE_TRANSIENT` is a macro (function pointer sentinel) that Swift cannot import.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
