import XCTest
import CSQLite
@testable import BacktrackCore

final class LocalSearchTests: XCTestCase {
    let now = 1_800_000_000.0
    var folder: URL!
    var path: String { folder.appendingPathComponent("search.sqlite").path }
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)
        let db = try SearchDatabase(path, writable: true)
        try db.execute("CREATE VIRTUAL TABLE search USING fts5(id UNINDEXED,title,location,context,user,assistant,tokenize='unicode61 remove_diacritics 2')")
        try db.execute("CREATE VIRTUAL TABLE vocabulary USING fts5vocab(search,'row')")
        try db.execute("CREATE TABLE files(id TEXT)")
        try db.execute("CREATE TABLE session_recency(id TEXT PRIMARY KEY,updated REAL)")
        try db.execute("CREATE TABLE passages(id INTEGER PRIMARY KEY,session_id TEXT,role TEXT,text TEXT,embedding BLOB,model TEXT)")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    func add(_ id: String, title: String = "A generic session", text: String, days: Double = 0, provider: String = "codex") throws -> Session {
        let s = Session(id: id, provider: provider, title: title, updated: now - days * 86400)
        let db = try SearchDatabase(path, writable: true)
        try db.execute("INSERT INTO search VALUES(?,?,?,?,?,?)", [id, title, "/tmp", "", "", text])
        try db.execute("INSERT INTO files VALUES(?)", [id])
        try db.execute("INSERT INTO session_recency VALUES(?,?)", [id, String(s.updated)])
        try db.execute("INSERT INTO passages(session_id,role,text) VALUES(?,?,?)", [id, "assistant", text])
        return s
    }
    func search(_ query: String, _ sessions: [Session], recent: Bool = true, provider: String = "all") throws -> [SearchHit] {
        try LocalSearch.search(query, sessions: sessions, provider: provider, recentFirst: recent, path: path, now: now)
    }
    func testAssistantOnlyMatchHasHighlightedEvidence() throws {
        let s = try add("a", text: "A long conversation about an app. We should name it Backtrack and give it a library interface.")
        let hit = try XCTUnwrap(search("backtrack", [s]).first)
        XCTAssertEqual(hit.id, "a")
        XCTAssertTrue(hit.snippet.contains("⟦Backtrack⟧"))
        XCTAssertEqual(hit.matchSource, "Assistant reply")
        XCTAssertFalse(hit.semantic)
    }
    func testQuiescentWALCacheCanBeReadWithoutAllowingDataWrites() throws {
        let session = try add("wal", text: "Find Backtrack after the background writer finishes.")
        do {
            let writer = try SearchDatabase(path, writable: true)
            let statement = try writer.statement("PRAGMA journal_mode=WAL")
            defer { sqlite3_finalize(statement) }
            _ = try writer.step(statement)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-wal"))
        XCTAssertEqual(try search("backtrack", [session]).first?.id, session.id)
        let reader = try SearchDatabase(path)
        XCTAssertThrowsError(try reader.execute("DELETE FROM passages"))
    }
    func testAllTermsPrefixesTyposUnicodeAndPunctuationAreSafe() throws {
        let s = try add("a", text: "Background café research")
        XCTAssertEqual(try search("backgroudn cafe", [s]).count, 1)
        XCTAssertEqual(try search("backgr", [s]).count, 1)
        XCTAssertTrue(try search("background unicorn", [s]).isEmpty)
        XCTAssertEqual(try search("\"cafe\" OR: 'background'", [s]).count, 0) // syntax is literal words
        XCTAssertEqual(try search("---", [s]).count, 1)
    }
    func testLiteralMisspellingDoesNotHideCorrectlySpelledTitles() throws {
        let correct = try add("correct", title: "Background processing", text: "Review the implementation.")
        let typo = try add("typo", text: "Someone typed backgroudn here.")
        XCTAssertEqual(Set(try search("backgroudn", [correct,typo]).map(\.id)), Set(["correct","typo"]))
    }
    func testRecencyStronglyWeightsFullTextAndCanBeDisabled() throws {
        let old = try add("old", text: "backtrack", days: 120)
        let new = try add("new", text: "backtrack")
        let hits = try search("backtrack", [old,new])
        XCTAssertEqual(hits.first?.id, "new")
        XCTAssertGreaterThan(hits[0].score / hits[1].score, 30)
        let best = try search("backtrack", [old,new], recent: false)
        XCTAssertEqual(best[0].score, best[1].score, accuracy: 0.001)
    }
    func testProviderFilterAndDeletedSessionSnapshot() throws {
        let a = try add("a", text: "backtrack")
        let b = try add("b", text: "backtrack", provider: "claude")
        XCTAssertEqual(try search("backtrack", [a,b], provider: "claude").map(\.id), ["b"])
        XCTAssertEqual(try search("backtrack", [a]).map(\.id), ["a"])
    }
    func testMetadataWorksWhileBackfillIsIncomplete() throws {
        let s = Session(id: "pending", title: "Backtrack", updated: now)
        XCTAssertEqual(try search("backtrack", [s]).first?.id, s.id)
    }
    func testExcerptsLoadOnDemandWithoutDroppingResults() throws {
        let sessions = try (0..<24).map { try add(String($0), text: "A backtrack passage for result \($0)") }
        let hits = try LocalSearch.search("backtrack", sessions: sessions, path: path, snippetLimit: 2, now: now)
        XCTAssertEqual(hits.count, 24)
        XCTAssertTrue(hits.prefix(2).allSatisfy { $0.snippet.contains("⟦backtrack⟧") })
        XCTAssertTrue(hits.dropFirst(2).allSatisfy { $0.snippet.isEmpty })
        let wanted = hits.dropFirst(2).prefix(3).map(\.session)
        let snippets = try LocalSearch.snippets("backtrack", sessions: wanted, path: path)
        XCTAssertEqual(Set(snippets.keys), Set(wanted.map(\.id)))
        XCTAssertTrue(snippets.values.allSatisfy { $0.0.contains("⟦backtrack⟧") && $0.1 == "Assistant reply" })
    }
    func testFreshTerminalTabNeverWritesIntoExistingSession() {
        let script = TerminalScript.iTerm(command: "echo \"a\\b\"")
        XCTAssertTrue(script.contains("tell current window"))
        XCTAssertTrue(script.contains("create tab with default profile command"))
        XCTAssertTrue(script.contains("else\n        create window"))
        XCTAssertFalse(script.contains("write text"))
        XCTAssertFalse(script.contains("keystroke"))
        XCTAssertTrue(script.contains("echo \\\"a\\\\b\\\""))
    }
    func testSingleNamesDoNotReturnSpuriousSemanticMatches() async throws {
        let engine = SemanticSearch()
        let hits = try await engine.search("backtrack", sessions: [], path: path)
        XCTAssertTrue(hits.isEmpty)
    }
    func testSemanticParaphraseWithoutSharedTerms() async throws {
        guard SemanticIndexer.available else { throw XCTSkip("Install the optional local model to run semantic integration tests") }
        let relevant = try add("startup", text: "Improve application launch performance and reduce loading delays.")
        let unrelated = try add("dinner", text: "Choose a restaurant for dinner tonight.")
        try await SemanticIndexer.build(path: path) { }
        XCTAssertEqual(LocalSearch.coverage(path: path).embedded, 2)
        let engine = SemanticSearch()
        let results = try await engine.search("make the app start faster", sessions: [relevant,unrelated], path: path, now: now)
        XCTAssertEqual(results.first?.id, "startup")
        XCTAssertEqual(results.first?.semantic, true)
        XCTAssertTrue(results.first?.snippet.contains("launch performance") == true)
        XCTAssertFalse(results.contains { $0.id == "dinner" })
    }
    func testSemanticCacheSeesReplacementsAndDeletesImmediately() async throws {
        guard SemanticIndexer.available else { throw XCTSkip("Install local model") }
        let a = try add("a", text: "Improve application launch performance and reduce loading delays.")
        let b = try add("b", text: "Choose a restaurant for dinner tonight.")
        try await SemanticIndexer.build(path: path) { }
        let engine = SemanticSearch()
        let first = try await engine.search("make the app start faster", sessions: [a,b], path: path, now: now)
        XCTAssertEqual(first.first?.id, "a")
        let initialCount = await engine.cachedPassageCount
        XCTAssertEqual(initialCount, 2)
        let db = try SearchDatabase(path, writable: true)
        try db.execute("UPDATE passages SET text=?,embedding=NULL,model=NULL WHERE session_id='a'", ["Choose a restaurant for dinner tonight."])
        try db.execute("UPDATE passages SET text=?,embedding=NULL,model=NULL WHERE session_id='b'", ["Improve application launch performance and reduce loading delays."])
        try await SemanticIndexer.build(path: path) { }
        // Same total vector count, changed contents: no five-second stale window.
        let second = try await engine.search("make the app start faster", sessions: [a,b], path: path, now: now)
        XCTAssertEqual(second.first?.id, "b")
        XCTAssertFalse(second.contains { $0.id == "a" })
        try db.execute("DELETE FROM passages WHERE session_id='b'")
        let removed = try await engine.search("make the app start faster", sessions: [a,b], path: path, now: now)
        XCTAssertTrue(removed.isEmpty)
        let remainingCount = await engine.cachedPassageCount
        XCTAssertEqual(remainingCount, 1)
    }

    func testSemanticCacheSwapRemovesNonfinalRowsAndSurvivesIDReuse() async throws {
        guard SemanticIndexer.available else { throw XCTSkip("Install local model") }
        let a = try add("a", text: "Improve application launch performance and reduce loading delays.")
        let b = try add("b", text: "Choose a restaurant for dinner tonight.")
        let c = try add("c", text: "Choose a restaurant for dinner tonight.")
        try await SemanticIndexer.build(path: path) { }
        let engine = SemanticSearch()
        _ = try await engine.search("make the app start faster", sessions: [a,b,c], path: path, now: now)
        let db = try SearchDatabase(path, writable: true)
        try db.execute("DELETE FROM passages WHERE session_id='a'")
        let deleted = try await engine.search("make the app start faster", sessions: [a,b,c], path: path, now: now)
        XCTAssertTrue(deleted.isEmpty)
        var count = await engine.cachedPassageCount
        XCTAssertEqual(count, 2)
        // c moved into a's slot; deleting it must use its updated position.
        try db.execute("DELETE FROM passages WHERE session_id='c'")
        _ = try await engine.search("make the app start faster", sessions: [a,b,c], path: path, now: now)
        let d = try add("d", text: "Improve application launch performance and reduce loading delays.")
        try await SemanticIndexer.build(path: path) { }
        let reused = try await engine.search("make the app start faster", sessions: [a,b,c,d], path: path, now: now)
        XCTAssertEqual(reused.map(\.id), ["d"])
        count = await engine.cachedPassageCount
        XCTAssertEqual(count, 2)
    }

}
