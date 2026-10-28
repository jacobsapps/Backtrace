import XCTest
@testable import Backtrace
@testable import BacktraceCore

@MainActor private final class MeaningProbe {
    var calls = 0
    func search(_ sessions: [Session]) async -> [SearchHit] {
        calls += 1
        try? await Task.sleep(for: .milliseconds(120))
        guard let target = sessions.first(where: { $0.id == "31" }) else { return [] }
        return [SearchHit(session: target, score: 0.9, related: false, snippet: "Real intent", semantic: true)]
    }
}

extension StoreTests {
    @MainActor func testSemanticReranksEvenWithMoreThanTwentyKeywordResults() async throws {
        let (cache,path,_) = try fixture()
        let probe = MeaningProbe()
        let store = Store(refreshOnStart: false, cache: cache, searchPath: path, preferences: nil,
                          semanticSearch: { _, sessions, _, _, _ in await probe.search(sessions) })
        await store.loadCache()
        store.query = "named Backtrace"
        try await settled(store)
        XCTAssertEqual(store.hits.count, 32)
        XCTAssertTrue(store.hits.allSatisfy { $0.snippet.isEmpty }) // ranking didn't wait for excerpts
        try await waitUntil { probe.calls == 1 && !store.semanticSearching }
        XCTAssertEqual(store.hits.first?.id, "31")
        XCTAssertEqual(store.selected, "31")
        XCTAssertEqual(store.hits.count, 32) // duplicate retrieval is reranked, not duplicated
    }

    @MainActor func testQueryChangeSelectsBestResultInsteadOfKeepingAnOldSelection() async throws {
        let (cache,path,_) = try fixture()
        let store = Store(refreshOnStart: false, cache: cache, searchPath: path, preferences: nil)
        store.related = false
        await store.loadCache()
        try await settled(store)
        store.selected = "31"
        store.query = "Backtrace"
        try await settled(store)
        XCTAssertEqual(store.selected, store.hits.first?.id)
        XCTAssertNotEqual(store.selected, "31")
    }

    @MainActor func testSemanticArrivalPreservesDeliberateKeyboardSelection() async throws {
        let (cache,path,_) = try fixture()
        let probe = MeaningProbe()
        let store = Store(refreshOnStart: false, cache: cache, searchPath: path, preferences: nil,
                          semanticSearch: { _, sessions, _, _, _ in await probe.search(sessions) })
        await store.loadCache()
        store.query = "named Backtrace"
        try await settled(store)
        store.move(1)
        let selected = store.selected
        try await waitUntil { probe.calls == 1 && !store.semanticSearching }
        XCTAssertEqual(store.hits.first?.id, "31")
        XCTAssertEqual(store.selected, selected)
    }
}
