import XCTest
import Combine
@testable import Backtrace
@testable import BacktraceCore

@MainActor private final class DelayedMeaningSearch {
    var requests: [[String]] = []
    func search(_ sessions: [Session]) async -> [SearchHit] {
        requests.append(sessions.map(\.id))
        // Simulate a model process that finishes after its caller cancels.
        await Task.detached { try? await Task.sleep(for: .milliseconds(220)) }.value
        return sessions.prefix(12).map {
            SearchHit(session: $0, score: 1, related: false, snippet: "Meaning-only evidence", semantic: true)
        }
    }
}

extension StoreTests {
    func isolatedPreferences() -> UserDefaults {
        let suite = "BacktraceFavouritesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    @MainActor func testFavouritesPersistByProviderPrefixedIDAndCanBeRemoved() {
        let preferences = isolatedPreferences()
        let codex = "codex:00000000-0000-0000-0000-000000000001"
        let claude = "claude:00000000-0000-0000-0000-000000000001"
        let first = Store(refreshOnStart: false, favouritesDefaults: preferences)
        first.toggleFavourite(codex)
        let second = Store(refreshOnStart: false, favouritesDefaults: preferences)
        XCTAssertTrue(second.isFavourite(codex))
        XCTAssertFalse(second.isFavourite(claude))
        second.toggleFavourite(codex)
        let third = Store(refreshOnStart: false, favouritesDefaults: preferences)
        XCTAssertTrue(third.favouriteIDs.isEmpty)
        XCTAssertEqual(preferences.stringArray(forKey: Store.favouritesKey), [])
    }

    @MainActor func testPreviewFavouritesNeverReadOrWriteRealPreferences() {
        let preferences = isolatedPreferences()
        preferences.set(["codex:real-session"], forKey: Store.favouritesKey)
        let preview = Store(preview: true, favouritesDefaults: preferences)
        XCTAssertTrue(preview.favouriteIDs.isEmpty)
        preview.toggleFavourite("1")
        XCTAssertTrue(preview.isFavourite("1"))
        XCTAssertEqual(preferences.stringArray(forKey: Store.favouritesKey), ["codex:real-session"])
    }

    @MainActor func testStarringInAllDoesNotSearchOrReorderResults() async throws {
        let (cache,path,_) = try fixture()
        let store = Store(refreshOnStart: false, cache: cache, searchPath: path, favouritesDefaults: nil)
        store.related = false
        await store.loadCache()
        try await settled(store)
        let original = store.hits.map(\.id)
        let selected = store.selected
        var changes = 0
        let subscription = store.$hits.dropFirst().sink { _ in changes += 1 }
        store.toggleFavourite("20")
        XCTAssertFalse(store.searching)
        XCTAssertEqual(store.hits.map(\.id), original)
        XCTAssertEqual(store.selected, selected)
        XCTAssertEqual(changes, 0)
        XCTAssertFalse(store.opening)
        withExtendedLifetime(subscription) {}
    }

    @MainActor func testFavouritesFilterBeforeVisibleLimitAndKeepTranscriptSnippets() async throws {
        let (cache,path,_) = try fixture(count: 140)
        let store = Store(refreshOnStart: false, cache: cache, searchPath: path, favouritesDefaults: nil)
        store.related = false
        await store.loadCache()
        store.query = "backtrace"
        try await settled(store)
        XCTAssertFalse(store.visible.contains { $0.id == "99" })
        store.toggleFavourite("99")
        store.favouritesOnly = true
        XCTAssertEqual(store.hits.map(\.id), ["99"])
        try await settled(store)
        XCTAssertEqual(store.visible.map(\.id), ["99"])
        XCTAssertTrue(store.hits[0].snippet.contains("⟦Backtrace⟧"))
        XCTAssertEqual(store.query, "backtrace")
        store.favouritesOnly = false
        try await settled(store)
        XCTAssertEqual(store.hits.count, 140)
        XCTAssertEqual(store.query, "backtrace")
    }

    @MainActor func testFavouritesCombineWithProviderAndUnstarUpdatesSelectionImmediately() async throws {
        let (cache,path,original) = try fixture()
        var index = original
        index.sessions[1].provider = "claude"
        index.sessions[1].available = false // Missing folders may still be bookmarked.
        try JSONEncoder().encode(index).write(to: cache)
        let store = Store(refreshOnStart: false, cache: cache, searchPath: path, favouritesDefaults: nil)
        store.related = false
        await store.loadCache()
        store.toggleFavourite("0"); store.toggleFavourite("1")
        store.favouritesOnly = true
        store.provider = "claude"
        store.query = "backtrace"
        try await settled(store)
        XCTAssertEqual(store.hits.map(\.id), ["1"])
        store.provider = "all"
        try await settled(store)
        XCTAssertEqual(Set(store.hits.map(\.id)), ["0", "1"])
        store.selected = "1"
        store.toggleFavourite("1")
        XCTAssertEqual(store.hits.map(\.id), ["0"])
        XCTAssertEqual(store.selected, "0")
        store.toggleFavourite("0")
        XCTAssertTrue(store.hits.isEmpty)
        XCTAssertNil(store.selected)
        XCTAssertFalse(store.searching)
        XCTAssertFalse(store.semanticSearching)
        XCTAssertFalse(store.opening)
    }

    @MainActor func testFavouritesSurviveRefreshTitleChangeAndTemporaryDisappearance() async throws {
        let (cache,path,original) = try fixture()
        let store = Store(refreshOnStart: false, cache: cache, searchPath: path, favouritesDefaults: isolatedPreferences())
        store.related = false
        await store.loadCache()
        store.toggleFavourite("0")
        store.favouritesOnly = true
        var missing = original
        missing.sessions.removeAll { $0.id == "0" }
        try JSONEncoder().encode(missing).write(to: cache)
        await store.loadCache()
        try await settled(store)
        XCTAssertTrue(store.hits.isEmpty)
        XCTAssertTrue(store.isFavourite("0"))
        var returned = original
        returned.sessions[0].title = "New title"
        returned.sessions[0].cwd = "/tmp/new-location"
        try JSONEncoder().encode(returned).write(to: cache)
        await store.loadCache()
        try await settled(store)
        XCTAssertEqual(store.hits.map(\.id), ["0"])
        XCTAssertEqual(store.hits.first?.session.title, "New title")
        XCTAssertEqual(store.hits.first?.session.cwd, "/tmp/new-location")
    }

    @MainActor func testEmptyFavouritesDoNotInvokeSemanticSearch() async throws {
        let (cache,path,_) = try fixture()
        let probe = DelayedMeaningSearch()
        let store = Store(refreshOnStart: false, cache: cache, searchPath: path, favouritesDefaults: nil,
                          semanticSearch: { _, sessions, _, _, _ in await probe.search(sessions) })
        await store.loadCache()
        store.favouritesOnly = true
        store.query = "meaning only"
        XCTAssertTrue(store.hits.isEmpty)
        XCTAssertFalse(store.searching)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(probe.requests.isEmpty)
        XCTAssertFalse(store.semanticSearching)
    }

    @MainActor func testSemanticCandidatesAreScopedBeforeTheTopTwelveLimit() async throws {
        let (cache,path,_) = try fixture()
        let probe = DelayedMeaningSearch()
        let store = Store(refreshOnStart: false, cache: cache, searchPath: path, favouritesDefaults: nil,
                          semanticSearch: { _, sessions, _, _, _ in await probe.search(sessions) })
        await store.loadCache()
        store.toggleFavourite("31")
        store.favouritesOnly = true
        store.query = "meaning only"
        try await waitUntil { !store.semanticSearching && store.hits.contains { $0.semantic } }
        XCTAssertEqual(probe.requests, [["31"]])
        XCTAssertEqual(store.hits.map(\.id), ["31"])
        XCTAssertEqual(store.hits[0].snippet, "Meaning-only evidence")
    }

    @MainActor func testUnstarRejectsAnInFlightSemanticReply() async throws {
        let (cache,path,_) = try fixture()
        let probe = DelayedMeaningSearch()
        let store = Store(refreshOnStart: false, cache: cache, searchPath: path, favouritesDefaults: nil,
                          semanticSearch: { _, sessions, _, _, _ in await probe.search(sessions) })
        await store.loadCache()
        store.toggleFavourite("0"); store.toggleFavourite("1")
        store.favouritesOnly = true
        store.query = "meaning only"
        try await waitUntil { probe.requests.count == 1 }
        store.toggleFavourite("0")
        try await waitUntil { probe.requests.count == 2 && !store.semanticSearching && !store.hits.isEmpty }
        XCTAssertEqual(probe.requests, [["0", "1"], ["1"]])
        XCTAssertEqual(store.hits.map(\.id), ["1"])
    }

    @MainActor func testTabSwitchRejectsAnInFlightAllSessionsSemanticReply() async throws {
        let (cache,path,_) = try fixture()
        let probe = DelayedMeaningSearch()
        let store = Store(refreshOnStart: false, cache: cache, searchPath: path, favouritesDefaults: nil,
                          semanticSearch: { _, sessions, _, _, _ in await probe.search(sessions) })
        await store.loadCache()
        store.toggleFavourite("31")
        store.query = "meaning only"
        try await waitUntil { probe.requests.count == 1 }
        store.favouritesOnly = true
        try await waitUntil { probe.requests.count == 2 && !store.semanticSearching && !store.hits.isEmpty }
        XCTAssertEqual(probe.requests.last, ["31"])
        XCTAssertEqual(store.hits.map(\.id), ["31"])
    }
}
