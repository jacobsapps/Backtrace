import XCTest
import Combine
@testable import Backtrack
@testable import BacktrackCore

private actor RefreshCounter {
    var calls = 0
    func refresh() async throws -> Data {
        calls += 1
        try await Task.sleep(for: .milliseconds(100))
        return Data(#"{"changed":false,"warnings":[]}"#.utf8)
    }
}
final class StoreTests: XCTestCase {
    func fixture() throws -> (URL, String, SessionIndex) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("search.sqlite").path
        FileManager.default.createFile(atPath: path, contents: nil)
        let db = try SearchDatabase(path, writable: true)
        try db.execute("CREATE VIRTUAL TABLE search USING fts5(id UNINDEXED,title,location,context,user,assistant)")
        try db.execute("CREATE VIRTUAL TABLE vocabulary USING fts5vocab(search,'row')")
        try db.execute("CREATE TABLE files(id TEXT)")
        try db.execute("CREATE TABLE passages(id INTEGER,embedding BLOB,model TEXT)")
        let sessions = (0..<32).map { Session(id: String($0), title: "Session \($0)", updated: 100) }
        for session in sessions {
            try db.execute("INSERT INTO files VALUES(?)", [session.id])
            try db.execute("INSERT INTO search VALUES(?,?,?,?,?,?)", [session.id,session.title,"/tmp","","","We named it Backtrack."])
        }
        let index = SessionIndex(version: 1, indexedAt: 100, duration: 0, warnings: [], sessions: sessions)
        let cache = folder.appendingPathComponent("sessions.json")
        try JSONEncoder().encode(index).write(to: cache)
        return (cache,path,index)
    }
    @MainActor func settled(_ store: Store) async throws {
        let deadline = Date().addingTimeInterval(3)
        while store.searching && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.searching)
    }
    @MainActor func testNoChangeRefreshDoesNotPublishNewResultsAndCoalescesRequests() async throws {
        let (cache,path,_) = try fixture()
        let counter = RefreshCounter()
        let store = Store(refreshOnStart: false, cache: cache, searchPath: path, refreshRunner: { try await counter.refresh() })
        store.related = false
        await store.loadCache()
        try await settled(store)
        var changes = 0
        let subscription = store.$hits.dropFirst().sink { _ in changes += 1 }
        let first = Task { await store.refresh() }
        let second = Task { await store.refresh() }
        await first.value; await second.value
        try await settled(store)
        let calls = await counter.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(changes, 0)
        XCTAssertGreaterThan(try XCTUnwrap(store.indexedAt).timeIntervalSince1970, 100)
        XCTAssertNil(store.error)
        withExtendedLifetime(subscription) {}
    }
    @MainActor func testChangedRefreshReloadsMetadata() async throws {
        let (cache,path,old) = try fixture()
        var replacement = old
        replacement.sessions[0].title = "Changed title"
        let replacementData = try JSONEncoder().encode(replacement)
        let store = Store(refreshOnStart: false, cache: cache, searchPath: path, refreshRunner: {
            try replacementData.write(to: cache, options: .atomic)
            return Data(#"{"changed":true,"warnings":[]}"#.utf8)
        })
        store.related = false
        await store.loadCache()
        await store.refresh()
        try await settled(store)
        XCTAssertEqual(store.sessions.first?.title, "Changed title")
        XCTAssertNil(store.error)
    }
    @MainActor func testRapidReplacementAndLazyExcerptsUseLatestGeneration() async throws {
        let (cache,path,_) = try fixture()
        let store = Store(refreshOnStart: false, cache: cache, searchPath: path)
        store.related = false
        await store.loadCache()
        store.query = "backtrack"
        try await settled(store)
        XCTAssertEqual(store.hits.count, 32)
        let deferred = store.hits[20]
        XCTAssertTrue(deferred.snippet.isEmpty)
        store.ensureSnippet(for: deferred.id)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(store.hits.first(where: { $0.id == deferred.id })?.snippet.contains("⟦Backtrack⟧") == true)
        store.ensureSnippet(for: store.hits[31].id)
        store.query = "unfindablezzzzzzzz"
        try await settled(store)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(store.hits.isEmpty)
        XCTAssertFalse(store.semanticSearching)
    }
}
