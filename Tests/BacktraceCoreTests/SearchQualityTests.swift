import XCTest
@testable import BacktraceCore

extension LocalSearchTests {
    func testLongSemanticQueryIncludesTextAfterTheFirstModelWindow() throws {
        guard SemanticIndexer.available else { throw XCTSkip("Install the optional local model") }
        let worker = try EmbeddingWorker()
        let prefix = String(repeating: "Please help me locate a previous conversation. ", count: 42)
        let start = try worker.vector(prefix)
        let full = try worker.vector(prefix + String(repeating: "Operating system architecture of iOS. ", count: 42))
        // The old truncated encoder returned exactly the same first-window vector.
        XCTAssertGreaterThan(zip(start,full).reduce(Float(0)) { $0 + abs($1.0 - $1.1) }, 0.5)
        XCTAssertEqual(full.reduce(Float(0)) { $0 + $1 * $1 }, 1, accuracy: 0.001)
    }
    func testOldOriginalArticleBeatsRecentIncidentalMentions() throws {
        var original = try add("article", title: "Explore iOS architecture trade-offs",
                               text: "Write about the operating system architecture of iOS and how Apple adapted OS X.", days: 26)
        original.first = "Write about the operating system architecture of iOS and how Apple adapted OS X."
        let invoice = try add("invoice", title: "Create an invoice",
                              text: "Invoice. The next article might be about iOS operating system architecture.", days: 2)
        let generic = try add("other", title: "Unrelated mobile app work",
                              text: "iOS architecture. " + String(repeating: "Unrelated conversation. ", count: 300) + "operating system", days: 0)
        XCTAssertEqual(try search("ios operating system architecture", [generic,invoice,original]).first?.id, "article")
    }

    func testBM25DifferencesSurviveInsteadOfCollapsingToDateOrder() throws {
        let focused = try add("focused", text: "Operating system architecture research.", days: 120)
        let incidental = try add("incidental", text: String(repeating: "Unrelated content. ", count: 600) + "operating system architecture")
        let results = try search("operating system architecture", [incidental,focused])
        XCTAssertEqual(results.first?.id, "focused")
        XCTAssertGreaterThan(results[0].score, results[1].score)
    }

    func testHybridReranksExistingKeywordHitsAndPreservesTheirEvidence() {
        let a = Session(id: "weak", title: "Incidental mention", updated: now)
        let b = Session(id: "right", title: "Original article", updated: now - 200 * 86400)
        let keyword = [SearchHit(session: a, score: 1, related: false),
                       SearchHit(session: b, score: 0.9, related: false, snippet: "An ⟦actual⟧ match", matchSource: "Your message")]
        let meaning = [SearchHit(session: b, score: 0.8, related: false, snippet: "Meaning evidence", semantic: true)]
        let combined = LocalSearch.merging(lexical: keyword, semantic: meaning)
        XCTAssertEqual(combined.map(\.id), ["right", "weak"])
        XCTAssertEqual(combined[0].snippet, "An ⟦actual⟧ match")
        XCTAssertFalse(combined[0].semantic)
        XCTAssertEqual(Set(combined.map(\.id)).count, 2)
    }

    func testStrongMeaningOnlyMatchCanBeatIncidentalKeywords() {
        let weak = Session(id: "weak", title: "Recent incidental words", updated: now)
        let right = Session(id: "right", title: "Old original", updated: now - 200 * 86400)
        let combined = LocalSearch.merging(
            lexical: [SearchHit(session: weak, score: 1, related: false)],
            semantic: [SearchHit(session: right, score: 0.75, related: false, snippet: "Matching intent", semantic: true)])
        XCTAssertEqual(combined.first?.id, "right")
        XCTAssertTrue(combined[0].semantic)
    }

    func testStrongTitleKeywordMatchRetainsARelevanceFloor() {
        let title = Session(id: "title", title: "Operating system architecture", updated: now)
        let nearby = Session(id: "nearby", title: "Related mobile app", updated: now)
        let combined = LocalSearch.merging(
            lexical: [SearchHit(session: title, score: 1.9, related: false)],
            semantic: [SearchHit(session: nearby, score: 0.55, related: false, semantic: true)])
        XCTAssertEqual(combined.first?.id, "title")
    }

    func testSemanticTitleVectorsFindIntentWithoutTranscriptKeywords() async throws {
        guard SemanticIndexer.available else { throw XCTSkip("Install the optional local model") }
        let relevant = try add("article", title: "Performance analytics", text: "Draft and edit the article.", days: 245)
        let unrelated = try add("dinner", text: "Choose a restaurant for dinner tonight.")
        let db = try SearchDatabase(path, writable: true)
        try db.execute("INSERT INTO passages(session_id,role,text) VALUES(?,?,?)", [relevant.id,"title",relevant.title])
        try await SemanticIndexer.build(path: path) { }
        let engine = SemanticSearch()
        let results = try await engine.search("automatically measure app performance using analytics events", sessions: [relevant,unrelated], path: path, now: now)
        XCTAssertEqual(results.first?.id, "article")
        XCTAssertEqual(results.first?.matchSource, "Session title")
        XCTAssertFalse(try LocalSearch.preview(relevant, path: path).contains { $0.0 == "title" })
    }

    func testSemanticIntentCorroborationBeatsAGenericRecentConversation() async throws {
        guard SemanticIndexer.available else { throw XCTSkip("Install the optional local model") }
        let relevant = try add("article", title: "Original operating system article", text: "Matching passage", days: 120)
        let generic = try add("generic", title: "Unrelated general work", text: "Matching passage")
        let worker = try EmbeddingWorker()
        let vector = try worker.vector("operating system architecture")
        let bytes = vector.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        let zero = String(repeating: "00", count: 1536)
        let db = try SearchDatabase(path, writable: true)
        try db.execute("UPDATE passages SET embedding=x'\(bytes)',model=?", [SemanticIndexer.modelID])
        for (session,hex) in [(relevant,bytes),(generic,zero)] {
            try db.execute("INSERT INTO passages(session_id,role,text,embedding,model) VALUES(?,?,?,x'\(hex)',?)", [session.id,"title",session.title,SemanticIndexer.modelID])
        }
        let engine = SemanticSearch()
        let hits = try await engine.search("operating system architecture", sessions: [generic,relevant], path: path, now: now)
        XCTAssertEqual(hits.first?.id, "article")
    }
}
