import AppKit
import Combine
import XCTest
@testable import Backtrace
@testable import BacktraceCore

extension StoreTests {
    @MainActor func testYOLOIsOptInAndPersistsBothOnAndOff() {
        let preferences = isolatedPreferences()
        let first = Store(refreshOnStart: false, preferences: preferences)
        XCTAssertFalse(first.reopenInYOLOMode)
        XCTAssertNil(preferences.object(forKey: Store.yoloModeKey))
        first.toggleFavourite("codex:keep")
        first.reopenInYOLOMode = true
        let second = Store(refreshOnStart: false, preferences: preferences)
        XCTAssertTrue(second.reopenInYOLOMode)
        XCTAssertTrue(second.isFavourite("codex:keep"))
        second.reopenInYOLOMode = false
        let third = Store(refreshOnStart: false, preferences: preferences)
        XCTAssertFalse(third.reopenInYOLOMode)
        XCTAssertTrue(third.isFavourite("codex:keep"))
    }

    @MainActor func testPreviewNeverInheritsOrChangesRealLaunchPermissions() {
        let preferences = isolatedPreferences()
        preferences.set(true, forKey: Store.yoloModeKey)
        let preview = Store(preview: true, preferences: preferences)
        XCTAssertFalse(preview.reopenInYOLOMode)
        preview.reopenInYOLOMode = true
        preview.reopenInYOLOMode = false
        XCTAssertTrue(preferences.bool(forKey: Store.yoloModeKey))
    }

    @MainActor func testChangingLaunchModeDoesNotSearchReorderOrOpenSessions() async throws {
        let (cache,path,_) = try fixture()
        let store = Store(refreshOnStart: false, cache: cache, searchPath: path, preferences: nil)
        store.related = false
        await store.loadCache()
        try await settled(store)
        let original = store.hits.map(\.id)
        let selection = store.selected
        var changes = 0
        let subscription = store.$hits.dropFirst().sink { _ in changes += 1 }
        store.reopenInYOLOMode = true
        store.reopenInYOLOMode = false
        XCTAssertFalse(store.searching)
        XCTAssertFalse(store.opening)
        XCTAssertEqual(store.hits.map(\.id), original)
        XCTAssertEqual(store.selected, selection)
        XCTAssertEqual(changes, 0)
        withExtendedLifetime(subscription) {}
    }

    @MainActor func testCopyAndLaunchCommandAgreeForBothProvidersAndModes() {
        let store = Store(refreshOnStart: false, preferences: nil)
        // A private pasteboard keeps tests from touching the user's clipboard.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for provider in ["codex", "claude"] {
            let session = Session(id: "test", provider: provider, title: "Test", updated: 0)
            store.hits = [SearchHit(session: session, score: 1, related: false)]
            store.selected = session.id
            for yolo in [false, true, false] {
                store.reopenInYOLOMode = yolo
                let launchCommand = store.resumeCommand(for: session)
                store.copyCommand(to: pasteboard)
                XCTAssertEqual(pasteboard.string(forType: .string), launchCommand)
                XCTAssertEqual(launchCommand, session.resumeCommand(yolo: yolo))
                XCTAssertEqual(launchCommand.contains("dangerously"), yolo)
            }
        }
    }
}
