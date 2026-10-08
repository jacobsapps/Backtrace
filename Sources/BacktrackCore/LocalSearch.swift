import Foundation
import CSQLite
import Accelerate

// Private Backtrack cache only; native agent databases never use this wrapper.
// Every connection is owned by one operation. No shared SQLite or model handles.
final class SearchDatabase {
    var handle: OpaquePointer?
    init(_ path: String, writable: Bool = false) throws {
        // macOS SQLite needs write access to recreate WAL sidecars after the last
        // writer exits. query_only keeps search logically read-only, without
        // making a quiescent WAL cache unreadable. Never create a missing cache.
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let error = message; sqlite3_close(handle); handle = nil
            throw SearchFailure(error)
        }
        sqlite3_busy_timeout(handle, writable ? 3000 : 100)
        if !writable { try execute("PRAGMA query_only=ON") }
    }
    deinit { sqlite3_close(handle) }
    var message: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Search index unavailable" }
    func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw SearchFailure(message) }
        for (i, value) in values.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        return stmt
    }
    func step(_ statement: OpaquePointer) throws -> Bool {
        let code = sqlite3_step(statement)
        if code == SQLITE_ROW { return true }
        if code == SQLITE_DONE { return false }
        throw SearchFailure(message)
    }
    func execute(_ sql: String, _ values: [String] = []) throws {
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw SearchFailure(message) }
    }
    static func text(_ s: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(s, column).map { String(cString: $0) } ?? ""
    }
}
public struct SearchFailure: LocalizedError {
    public let message: String
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct IndexCoverage: Sendable {
    public var conversations = 0
    public var passages = 0
    public var embedded = 0
    public init(conversations: Int = 0, passages: Int = 0, embedded: Int = 0) {
        self.conversations = conversations; self.passages = passages; self.embedded = embedded
    }
}

public enum LocalSearch {
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Backtrack/search.sqlite").path
    }
    public static func coverage(path: String = defaultPath) -> IndexCoverage {
        guard let db = try? SearchDatabase(path) else { return IndexCoverage() }
        let key = "embedded:" + SemanticIndexer.modelID + ":" + String(SemanticIndexer.dimension * 4)
        // Maintained transactionally by triggers, so polling never reads transcript blobs.
        let fast = "SELECT (SELECT count(*) FROM files), (SELECT value FROM search_stats WHERE key='passages'), (SELECT value FROM search_stats WHERE key=?)"
        let legacy = "SELECT (SELECT count(*) FROM files),count(*),sum(CASE WHEN model='" + SemanticIndexer.modelID + "' AND length(embedding)=1536 THEN 1 ELSE 0 END) FROM passages"
        guard let s = (try? db.statement(fast, [key])) ?? (try? db.statement(legacy)) else { return IndexCoverage() }
        defer { sqlite3_finalize(s) }
        guard (try? db.step(s)) == true else { return IndexCoverage() }
        return IndexCoverage(conversations: Int(sqlite3_column_int(s, 0)), passages: Int(sqlite3_column_int(s, 1)), embedded: Int(sqlite3_column_int(s, 2)))
    }
    public static func recency(_ updated: Double, now: Double) -> Double {
        // Two-week decay, ~33x preference for equally relevant recent conversations.
        0.03 + 0.97 * exp(-max(0, now - updated) / (14 * 86400))
    }
    static func expression(_ query: String, db: SearchDatabase, fuzzy: Bool = false) throws -> String {
        let terms = Array(Set(SearchEngine.tokens(SearchEngine.normalize(query)))).sorted()
        return try terms.map { term in
            var alternatives = ["\"\(term)\"" + (term.count >= 2 ? "*" : "")]
            if fuzzy && term.count >= 5 {
                // Vocabulary is on disk. Restrict candidates before edit-distance work.
                let s = try db.statement("SELECT term FROM vocabulary WHERE term GLOB ? AND length(term) BETWEEN CAST(? AS INTEGER) AND CAST(? AS INTEGER) ORDER BY doc DESC LIMIT 1500", [String(term.prefix(2)) + "*", String(term.count - 1), String(term.count + 1)])
                defer { sqlite3_finalize(s) }
                while try db.step(s) {
                    let word = SearchDatabase.text(s, 0)
                    if word != term && SearchEngine.oneEdit(term, word) { alternatives.append("\"\(word)\"") }
                }
            }
            return "(" + alternatives.joined(separator: " OR ") + ")"
        }.joined(separator: " AND ")
    }
    private static func lexicalExpression(_ query: String, db: SearchDatabase) throws -> String {
        let literal = try expression(query, db: db)
        let tolerant = try expression(query, db: db, fuzzy: true)
        // Keep typo tolerance in session metadata even if a transcript happens to
        // contain the misspelling literally. Do not fuzzy-expand all tool-like prose.
        if tolerant != literal { return "(" + literal + ") OR ({title location context}: (" + tolerant + "))" }
        return literal
    }
    public static func search(_ query: String, sessions: [Session], provider: String = "all", recentFirst: Bool = true, path: String = defaultPath, snippetLimit: Int = 16, now: Double = Date().timeIntervalSince1970) throws -> [SearchHit] {
        let terms = SearchEngine.tokens(SearchEngine.normalize(query))
        if terms.isEmpty {
            return sessions.filter { provider == "all" || $0.provider == provider }
                .sorted { $0.updated == $1.updated ? $0.id < $1.id : $0.updated > $1.updated }
                .map { SearchHit(session: $0, score: $0.updated, related: false) }
        }
        let db = try SearchDatabase(path)
        // Keep matching row IDs and their excerpts in one WAL read snapshot while
        // background indexing replaces rows. A refresh must not erase the evidence.
        try db.execute("BEGIN")
        defer { try? db.execute("COMMIT") }
        let byID = Dictionary(uniqueKeysWithValues: sessions.filter { provider == "all" || $0.provider == provider }.map { ($0.id, $0) })
        // Only build the legacy metadata matcher for sessions not yet in FTS.
        // The normal, fully indexed path has no vocabulary construction or scan.
        let indexed = try db.statement("SELECT id FROM files")
        defer { sqlite3_finalize(indexed) }
        var indexedIDs = Set<String>()
        while try db.step(indexed) { indexedIDs.insert(SearchDatabase.text(indexed, 0)) }
        let pending = sessions.filter { !indexedIDs.contains($0.id) }
        var hits: [String: SearchHit] = [:]
        if !pending.isEmpty {
            for var hit in SearchEngine(pending).search(query, provider: provider, related: false, recentFirst: false, now: now) {
                hit.score = min(12, hit.score / 3) * (recentFirst ? recency(hit.session.updated, now: now) : 1)
                hit.snippet = hit.session.latest
                hit.matchSource = "Session details"
                hits[hit.id] = hit
            }
        }
        var match = try lexicalExpression(query, db: db)
        var rows: [(Int64, Session, Double)] = []
        for fuzzy in [false, true] {
            if fuzzy { match = try expression(query, db: db, fuzzy: true) }
            let s = try db.statement("SELECT rowid,id,bm25(search,0,12,6,3,2,1) FROM search WHERE search MATCH ?", [match])
            defer { sqlite3_finalize(s) }
            while try db.step(s) {
                try Task.checkCancellation()
                guard let session = byID[SearchDatabase.text(s, 1)] else { continue }
                rows.append((sqlite3_column_int64(s, 0), session, -sqlite3_column_double(s, 2)))
            }
            if !rows.isEmpty { break }
        }
        for (_, session, rank) in rows {
            let title = SearchEngine.normalize(session.title)
            let titleMatch = terms.allSatisfy { title.contains($0) }
            let base = titleMatch ? 12.0 : 3 + min(2, log1p(rank))
            let score = base * (recentFirst ? recency(session.updated, now: now) : 1)
            let prior = hits[session.id]
            hits[session.id] = SearchHit(session: session, score: max(score, prior?.score ?? 0), related: false, matchSource: titleMatch ? "Title" : "Transcript")
        }
        var sorted = sort(Array(hits.values))
        let rowIDs = Dictionary(uniqueKeysWithValues: rows.map { ($0.1.id, $0.0) })
        // Generate excerpts only for the visible page, not every matching transcript.
        for i in 0..<min(max(0, snippetLimit), sorted.count) {
            try Task.checkCancellation()
            guard let rowID = rowIDs[sorted[i].id] else { continue }
            if let excerpt = try excerpt(db, rowID: rowID, expression: match) {
                sorted[i].snippet = excerpt.0.isEmpty ? sorted[i].session.latest : excerpt.0
                if !excerpt.1.isEmpty { sorted[i].matchSource = excerpt.1 }
            }
        }
        return sorted
    }
    private static func excerpt(_ db: SearchDatabase, rowID: Int64, expression: String) throws -> (String, String)? {
        let s = try db.statement("SELECT snippet(search,4,'⟦','⟧','…',42),snippet(search,5,'⟦','⟧','…',42),snippet(search,3,'⟦','⟧','…',42),snippet(search,2,'⟦','⟧','…',32) FROM search WHERE rowid=? AND search MATCH ?", [String(rowID), expression])
        defer { sqlite3_finalize(s) }
        guard try db.step(s) else { return nil }
        for (col, label) in [(Int32(0), "Your message"), (1, "Assistant reply"), (2, "Prompt history"), (3, "Folder / branch")] {
            let text = SearchDatabase.text(s, col)
            if text.contains("⟦") { return (text, label) }
        }
        return ("", "")
    }
    public static func snippets(_ query: String, sessions: [Session], path: String = defaultPath) throws -> [String: (String, String)] {
        guard !sessions.isEmpty else { return [:] }
        let db = try SearchDatabase(path)
        try db.execute("BEGIN"); defer { try? db.execute("COMMIT") }
        let wanted = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var result: [String: (String, String)] = [:]
        for fuzzy in [false, true] {
            let match = try (fuzzy ? expression(query, db: db, fuzzy: true) : lexicalExpression(query, db: db))
            guard !match.isEmpty else { return [:] }
            let s = try db.statement("SELECT rowid,id FROM search WHERE search MATCH ?", [match])
            defer { sqlite3_finalize(s) }
            while try db.step(s) {
                try Task.checkCancellation()
                let id = SearchDatabase.text(s, 1)
                guard let session = wanted[id], result[id] == nil else { continue }
                if let value = try excerpt(db, rowID: sqlite3_column_int64(s, 0), expression: match) {
                    result[id] = (value.0.isEmpty ? session.latest : value.0, value.1)
                }
            }
            if !result.isEmpty { break }
        }
        return result
    }
    public static func sort(_ hits: [SearchHit]) -> [SearchHit] {
        hits.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.session.updated != $1.session.updated { return $0.session.updated > $1.session.updated }
            return $0.id < $1.id
        }
    }
    public static func preview(_ session: Session, path: String = defaultPath) throws -> [(String, String)] {
        let db = try SearchDatabase(path)
        let s = try db.statement("SELECT role,text FROM passages WHERE session_id=? ORDER BY id DESC LIMIT 8", [session.id])
        defer { sqlite3_finalize(s) }
        var rows: [(String, String)] = []
        while try db.step(s) { rows.append((SearchDatabase.text(s, 0), SearchDatabase.text(s, 1))) }
        return rows.reversed()
    }
}

public enum SemanticIndexer {
    public static let modelID = "minilm-l6-v2-qint8-arm64-1110a243-mean-256-v1"
    public static let dimension = 384
    public static var python: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Backtrack/semantic-runtime/bin/python").path
    }
    public static var script: String {
        Bundle.main.url(forResource: "semantic_search", withExtension: "py")?.path
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/semantic_search.py").path
    }
    public static var available: Bool { FileManager.default.isExecutableFile(atPath: python) }
    public static func build(path: String = LocalSearch.defaultPath, progress: @Sendable () async -> Void) async throws {
        guard available else { throw SearchFailure("Semantic model not installed. Run scripts/setup-semantic.sh. Full-text search still works.") }
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script, "--index", path]
        process.standardOutput = output; process.standardError = error
        try process.run()
        do {
            while process.isRunning {
                try Task.checkCancellation()
                await progress()
                try await Task.sleep(for: .seconds(2))
            }
        } catch { if process.isRunning { process.terminate() }; throw error }
        let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw SearchFailure("Semantic indexing unavailable. " + message) }
        await progress()
    }
}

/// A single local process held by the semantic actor; no network or main-thread work.
private final class EmbeddingWorker {
    let process = Process(), input = Pipe(), output = Pipe()
    private var cached: [String: [Float]] = [:]
    private var order: [String] = []
    init() throws {
        guard SemanticIndexer.available else { throw SearchFailure("Local semantic runtime is not installed.") }
        process.executableURL = URL(fileURLWithPath: SemanticIndexer.python)
        process.arguments = [SemanticIndexer.script, "--serve"]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
    deinit {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
    func vector(_ query: String) throws -> [Float] {
        let key = SearchEngine.normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
        if let vector = cached[key] { return vector }
        guard process.isRunning else { throw SearchFailure("Local semantic worker stopped.") }
        var request = try JSONSerialization.data(withJSONObject: ["query": query]); request.append(10)
        try input.fileHandleForWriting.write(contentsOf: request)
        var data = Data()
        while !data.contains(10) {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw SearchFailure("Local semantic worker could not load the model.") }
            data.append(chunk)
            guard data.count < 100_000 else { throw SearchFailure("Invalid semantic worker response.") }
        }
        let vector = try JSONDecoder().decode([Float].self, from: data)
        guard vector.count == SemanticIndexer.dimension, vector.allSatisfy({ $0.isFinite }) else { throw SearchFailure("Invalid embedding dimensions.") }
        cached[key] = vector; order.append(key)
        if order.count > 24 { cached.removeValue(forKey: order.removeFirst()) }
        return vector
    }
}

public actor SemanticSearch {
    private var worker: EmbeddingWorker?
    private var matrix: [Float] = []
    private var rows: [(Int64, String)] = []
    private var positions: [Int64: Int] = [:]
    private var loadedRevision: Int64 = -1
    private var loadedPath = ""
    public init() {}
    public func search(_ query: String, sessions: [Session], provider: String = "all", recentFirst: Bool = true, path: String = LocalSearch.defaultPath, now: Double = Date().timeIntervalSince1970) throws -> [SearchHit] {
        let started = Date()
        try Task.checkCancellation()
        // Sentence embeddings need an intent, not a product name or opaque ID.
        // Single-word/name queries stay lexical instead of returning spurious neighbours.
        guard SearchEngine.tokens(query).count >= 2 else { return [] }
        if worker == nil { worker = try EmbeddingWorker() }
        let q: [Float]
        do { q = try worker!.vector(query) }
        catch { worker = nil; throw error }
        let encoded = Date()
        try Task.checkCancellation()
        let dimension = SemanticIndexer.dimension
        let db = try SearchDatabase(path)
        try db.execute("BEGIN")
        defer { try? db.execute("COMMIT") }
        try loadChanges(db, path: path)
        if ProcessInfo.processInfo.environment["BACKTRACK_SEARCH_TIMINGS"] != nil {
            fputs(String(format: "Semantic encode: %.1f ms; vector refresh: %.1f ms\n", encoded.timeIntervalSince(started) * 1000, Date().timeIntervalSince(encoded) * 1000), stderr)
        }
        guard !rows.isEmpty else { return [] }
        var similarities = [Float](repeating: 0, count: rows.count)
        vDSP_mmul(matrix, 1, q, 1, &similarities, 1, vDSP_Length(rows.count), 1, vDSP_Length(dimension))
        let sessions = Dictionary(uniqueKeysWithValues: sessions.filter { provider == "all" || $0.provider == provider }.map { ($0.id, $0) })
        var winners: [String: (Int64, Double)] = [:]
        for i in rows.indices {
            if i % 1024 == 0 { try Task.checkCancellation() }
            // Conservative floor: semantic suggestions must be meaningfully close.
            guard similarities[i] >= 0.42, let session = sessions[rows[i].1] else { continue }
            let quality = Double(similarities[i])
            let score = quality * 2.5 * (recentFirst ? LocalSearch.recency(session.updated, now: now) : 1)
            if score > (winners[session.id]?.1 ?? 0) { winners[session.id] = (rows[i].0, score) }
        }
        var hits: [SearchHit] = []
        for (id, winner) in winners.sorted(by: { $0.value.1 > $1.value.1 }).prefix(12) {
            guard let session = sessions[id] else { continue }
            let s = try db.statement("SELECT role,text FROM passages WHERE id=?", [String(winner.0)])
            defer { sqlite3_finalize(s) }
            if try db.step(s) {
                hits.append(SearchHit(session: session, score: winner.1, related: false, snippet: SearchDatabase.text(s, 1), matchSource: SearchDatabase.text(s, 0) == "user" ? "Your message" : "Assistant reply", semantic: true))
            }
        }
        return LocalSearch.sort(hits)
    }
    private func loadChanges(_ db: SearchDatabase, path: String) throws {
        let revisionStatement = try? db.statement("SELECT coalesce(max(seq),0) FROM semantic_changes")
        let revision: Int64
        if let statement = revisionStatement {
            defer { sqlite3_finalize(statement) }
            _ = try db.step(statement)
            revision = sqlite3_column_int64(statement, 0)
        } else { revision = -1 } // Compatibility until the cache-only migration runs.
        if path == loadedPath && loadedRevision >= 0 && loadedRevision == revision { return }
        let full = path != loadedPath || loadedRevision < 0 || revision < loadedRevision || revision - loadedRevision > 4096
        let sql: String
        let values: [String]
        if full {
            matrix.removeAll(keepingCapacity: true); rows.removeAll(keepingCapacity: true); positions.removeAll(keepingCapacity: true)
            matrix.reserveCapacity(LocalSearch.coverage(path: path).embedded * SemanticIndexer.dimension)
            sql = "SELECT id,session_id,embedding,model FROM passages WHERE model=? AND length(embedding)=1536 ORDER BY id"
            values = [SemanticIndexer.modelID]
        } else {
            sql = "SELECT c.passage_id,p.session_id,p.embedding,p.model FROM (SELECT DISTINCT passage_id FROM semantic_changes WHERE seq>CAST(? AS INTEGER)) c LEFT JOIN passages p ON p.id=c.passage_id"
            values = [String(loadedRevision)]
        }
        let s = try db.statement(sql, values)
        defer { sqlite3_finalize(s) }
        do {
            var count = 0
            while try db.step(s) {
                if count % 512 == 0 { try Task.checkCancellation() }; count += 1
                let id = sqlite3_column_int64(s, 0)
                let valid = SearchDatabase.text(s, 3) == SemanticIndexer.modelID && sqlite3_column_bytes(s, 2) == SemanticIndexer.dimension * 4
                if valid, let bytes = sqlite3_column_blob(s, 2) {
                    let index: Int
                    if let existing = positions[id] { index = existing }
                    else {
                        index = rows.count; positions[id] = index
                        rows.append((id, ""))
                        matrix.append(contentsOf: repeatElement(0, count: SemanticIndexer.dimension))
                    }
                    rows[index] = (id, SearchDatabase.text(s, 1))
                    matrix.withUnsafeMutableBytes { buffer in
                        buffer.baseAddress!.advanced(by: index * SemanticIndexer.dimension * 4)
                            .copyMemory(from: bytes, byteCount: SemanticIndexer.dimension * 4)
                    }
                } else if let index = positions.removeValue(forKey: id) {
                    rows[index] = (0, "")
                    for offset in 0..<SemanticIndexer.dimension { matrix[index * SemanticIndexer.dimension + offset] = 0 }
                }
            }
            loadedRevision = revision; loadedPath = path
        } catch {
            // A cancelled initial load is not a complete cache. Updates are idempotent.
            if full { loadedRevision = -1; loadedPath = "" }
            throw error
        }
    }

}
