import AppKit
import BacktraceCore
import SwiftUI

enum Diagnostics {
    static var fixture: URL? {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--fixture"), flag + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[flag + 1])
    }
    static var indexPath: URL { fixture?.appendingPathComponent("sessions.json") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Backtrack/sessions.json") }
    static var databasePath: String { fixture?.appendingPathComponent("corpus.sqlite").path ?? LocalSearch.defaultPath }

    @MainActor static func verifySearch() {
        // This is a Store integration check, not a UI launch. Avoid registering
        // NSApplication so it also runs in headless/restricted build environments.
        Task {
            let store = Store(refreshOnStart: false, cache: indexPath, searchPath: databasePath)
            await store.loadCache()
            store.query = "background ios"
            try? await Task.sleep(for: .milliseconds(90))
            store.query = "backtrack"
            try? await Task.sleep(for: .seconds(3))
            guard store.query == "backtrack", store.hits.contains(where: { $0.session.title.contains("Free Parking UI") && $0.snippet.localizedCaseInsensitiveContains("backtrack") }) else {
                fputs("Latest query did not return transcript evidence\n", stderr); exit(1)
            }
            print("Rapid query replacement: latest query retained with transcript evidence")
            store.query = "background ios"
            try? await Task.sleep(for: .seconds(1))
            guard let deferred = store.hits.dropFirst(16).first, deferred.snippet.isEmpty else {
                fputs("Expected an excerpt deferred beyond the first page\n", stderr); exit(1)
            }
            store.ensureSnippet(for: deferred.id)
            try? await Task.sleep(for: .seconds(1))
            guard store.hits.first(where: { $0.id == deferred.id })?.snippet.isEmpty == false else {
                fputs("On-demand excerpt did not arrive\n", stderr); exit(1)
            }
            print("On-demand excerpts: loaded beyond the first page")
            // Replace both pending excerpt work and an in-flight meaning query.
            if let pending = store.hits.dropFirst(40).first { store.ensureSnippet(for: pending.id) }
            store.query = "search previous coding conversations"
            try? await Task.sleep(for: .milliseconds(200))
            store.provider = "claude"
            store.query = "unfindablezzuniquezzzzzz"
            try? await Task.sleep(for: .seconds(3))
            guard !store.searching, !store.semanticSearching, store.hits.isEmpty else {
                fputs("Stale results survived replacement query\n", stderr); exit(1)
            }
            print("Stale-result protection and provider change: passed")
            exit(0)
        }
        RunLoop.main.run()
    }
    static func semanticBenchmark() {
        Task.detached {
            do {
                let path = indexPath
                let index = try JSONDecoder().decode(SessionIndex.self, from: Data(contentsOf: path))
                let engine = SemanticSearch()
                let coverage = LocalSearch.coverage(path: databasePath)
                print("Semantic coverage: \(coverage.embedded)/\(coverage.passages) passages")
                for query in ["search previous coding conversations", "make the app start faster", "free up disk space", "search previous coding conversations"] {
                    let start = CFAbsoluteTimeGetCurrent()
                    let hits = try await engine.search(query, sessions: index.sessions, path: databasePath)
                    print(String(format: "%@: %.1f ms, %d matches", query, (CFAbsoluteTimeGetCurrent() - start) * 1000, hits.count))
                    for h in hits.prefix(3) { print("  \(h.session.title): \(h.snippet.prefix(180))") }
                }
                exit(0)
            } catch { fputs("\(error)\n", stderr); exit(1) }
        }
        RunLoop.main.run()
    }

    static func embedIndex() {
        Task.detached(priority: .utility) {
            do {
                try await SemanticIndexer.build(path: databasePath) { }
                let coverage = LocalSearch.coverage(path: databasePath)
                print("Semantic passages: \(coverage.embedded)/\(coverage.passages)")
                exit(0)
            } catch { fputs("\(error)\n", stderr); exit(1) }
        }
        RunLoop.main.run()
    }

    @MainActor static func snapshot() {
        // Offscreen rendering only. Fictional data; no index, terminals, or focus changes.
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--snapshot"), flag + 1 < args.count else { exit(2) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = Store(preview: true, searchPath: databasePath)
        let host = NSHostingView(rootView: ContentView(store: store))
        let compact = args.contains("--compact")
        if args.contains("--search-preview") { store.query = "backtrace" }
        if args.contains("--empty-preview") { store.query = "nothing-matches-this" }
        if args.contains("--live-data") {
            let path = indexPath
            if let data = try? Data(contentsOf: path), let index = try? JSONDecoder().decode(SessionIndex.self, from: data) {
                store.snapshot(index.sessions, query: "backtrack")
            }
        }
        let size = NSSize(width: compact ? 460 : 620, height: compact ? 440 : 640)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(3) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(4) }
        do { try data.write(to: URL(fileURLWithPath: args[flag + 1])) }
        catch { fputs("\(error)\n", stderr); exit(5) }
    }
    static func benchmark() {
        do {
            let path = indexPath
            let start = CFAbsoluteTimeGetCurrent()
            let index = try JSONDecoder().decode(SessionIndex.self, from: Data(contentsOf: path))
            print(String(format: "Cache load + search preparation: %.1f ms (%d sessions)", (CFAbsoluteTimeGetCurrent() - start) * 1000, index.sessions.count))
            let coverage = LocalSearch.coverage(path: databasePath)
            print("Full-text conversations: \(coverage.conversations); semantic passages: \(coverage.embedded)/\(coverage.passages)")
            for query in ["", "backtrack", "background ios", "backgroudn", "storage", "notification", "multi 7", "blog", "zznonexistent"] {
                var times: [Double] = []
                var count = 0
                for _ in 0..<8 {
                    let start = CFAbsoluteTimeGetCurrent()
                    let hits = try LocalSearch.search(query, sessions: index.sessions, path: databasePath)
                    times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                    count = hits.count
                }
                if query == "backtrack" {
                    for hit in try LocalSearch.search(query, sessions: index.sessions, path: databasePath).prefix(6) {
                        print("\(hit.session.title) | \(hit.matchSource) | \(hit.snippet)")
                    }
                }
                print(String(format: "%@: %d matches, median %.1f ms, max %.1f ms", query.isEmpty ? "(recent)" : query, count, times.sorted()[4], times.max()!))
            }
        } catch { fputs("\(error)\n", stderr); exit(1) }
    }
}
