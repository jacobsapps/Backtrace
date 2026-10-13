import XCTest
@testable import BacktraceCore

final class SearchTests: XCTestCase {
    let now = 1_800_000_000.0
    func session(_ id: String, _ title: String, days: Double = 0, provider: String = "codex", cwd: String = "/tmp/test", text: String = "") -> Session {
        Session(id: id, provider: provider, cwd: cwd, title: title, searchText: text, updated: now - days * 86400)
    }
    func testEmptyIsMostRecent() {
        let engine = SearchEngine([session("old", "Old", days: 50), session("new", "New")])
        XCTAssertEqual(engine.search("", now: now).map(\.id), ["new", "old"])
    }
    func testStrongRecencyAndOptOut() {
        let engine = SearchEngine([session("old", "Background processing", days: 90), session("new", "iOS investigation", text: "background processing")])
        XCTAssertEqual(engine.search("background", now: now).first?.id, "new")
        XCTAssertEqual(engine.search("background", recentFirst: false, now: now).first?.id, "old")
    }
    func testOldUniqueMatchNeverSuppressed() {
        let engine = SearchEngine([session("old", "Metal fractal renderer", days: 200), session("new", "Notifications")])
        XCTAssertEqual(engine.search("fractal", now: now).first?.id, "old")
    }
    func testAllTermsMustMatch() {
        let engine = SearchEngine([session("a", "Background processing"), session("b", "Background notifications")])
        XCTAssertEqual(engine.search("background notifications", related: false, now: now).map(\.id), ["b"])
    }
    func testTyposPrefixesAndDiacritics() {
        let engine = SearchEngine([session("a", "Background café")])
        XCTAssertEqual(engine.search("backgroudn cafe", now: now).first?.id, "a")
        XCTAssertEqual(engine.search("backgr", now: now).first?.id, "a")
    }
    func testRelatedWordsAreExplicitAndOptional() {
        let engine = SearchEngine([session("a", "Disk cleanup")])
        XCTAssertEqual(engine.search("storage", now: now).first?.related, true)
        XCTAssertTrue(engine.search("storage", related: false, now: now).isEmpty)
    }
    func testProviderAndPath() {
        let engine = SearchEngine([session("a", "Build", cwd: "/Users/test/multi/7/app"), session("b", "Build", provider: "claude")])
        XCTAssertEqual(engine.search("multi 7", now: now).first?.id, "a")
        XCTAssertEqual(engine.search("build", provider: "claude", now: now).map(\.id), ["b"])
    }
    func testCommandUsesExactIDAndQuotesShellInput() {
        let s = session("a", "Don't execute $(anything)", cwd: "/tmp/it's $(touch nope)")
        XCTAssertEqual(s.command, "cd -- '/tmp/it'\\''s $(touch nope)' && codex resume '00000000-0000-0000-0000-000000000001'")
        XCTAssertFalse(s.command.contains("dangerously"))
    }
    func testDeterministicTieBreaking() {
        let engine = SearchEngine([session("b", "Build"), session("a", "Build")])
        XCTAssertEqual(engine.search("build", now: now).map(\.id), ["a", "b"])
    }
}
