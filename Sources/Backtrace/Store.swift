import AppKit
import BacktraceCore
import SwiftUI

@MainActor final class Store: ObservableObject {
    typealias SemanticRunner = @Sendable (String, [Session], String, Bool, String) async throws -> [SearchHit]
    static let favouritesKey = "favouriteSessionIDs"
    @Published var sessions: [Session] = []
    @Published var hits: [SearchHit] = []
    @Published private(set) var favouriteIDs: Set<String>
    @Published var favouritesOnly = false { didSet { if favouritesOnly != oldValue { search() } } }
    @Published var query = "" { didSet { if query != oldValue { search() } } }
    @Published var provider = "all" { didSet { if provider != oldValue { search() } } }
    @Published var related = true {
        didSet {
            guard related != oldValue else { return }
            if related { buildSemantics() } else { semanticTask?.cancel() }
            search()
        }
    }
    @Published var recentFirst = true { didSet { if recentFirst != oldValue { search() } } }
    @Published var selected: String?
    @Published var refreshing = false
    @Published var opening = false
    @Published var searching = false
    @Published var error: String?
    @Published var notice = ""
    @Published var indexedAt: Date?
    @Published var searchMS = 0.0
    @Published var coverage = IndexCoverage()
    @Published var semanticIndexing = false
    @Published var semanticSearching = false
    @Published var semanticNotice = ""
    private let semanticSearch: SemanticRunner
    private let favouritesDefaults: UserDefaults?
    private var semanticTask: Task<Void, Never>?
    private var lexicalTask: Task<([SearchHit], String?), Never>?
    private var snippetTask: Task<Void, Never>?
    private var snippetWorker: Task<[String: (String, String)], Never>?
    private var pendingSnippets = Set<String>()
    private var requestedSnippets = Set<String>()
    private var preview = false
    private var snapshotFrozen = false
    private var engine = SearchEngine([])
    private var generation = 0
    private var searchTask: Task<Void, Never>?
    private let cache: URL
    private let searchPath: String
    private let refreshRunner: @Sendable () async throws -> Data
    var currentHit: SearchHit? { hits.first { $0.id == selected } }
    var current: Session? { hits.first { $0.id == selected }?.session }
    var visible: [SearchHit] { Array(hits.prefix(100)) }

    init(preview: Bool = false, refreshOnStart: Bool = true, cache: URL? = nil,
         searchPath: String = LocalSearch.defaultPath,
         favouritesDefaults: UserDefaults? = .standard, semanticSearch: SemanticRunner? = nil,
         refreshRunner: @escaping @Sendable () async throws -> Data = { try await Store.helper([]) }) {
        self.cache = cache ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Backtrack/sessions.json")
        self.searchPath = searchPath
        self.refreshRunner = refreshRunner
        self.preview = preview
        // Provider-prefixed native IDs survive title/folder changes and index rebuilds.
        // Previews never read or write the user's real favourites.
        self.favouritesDefaults = preview ? nil : favouritesDefaults
        favouriteIDs = Set(self.favouritesDefaults?.stringArray(forKey: Self.favouritesKey) ?? [])
        let semanticEngine = SemanticSearch()
        self.semanticSearch = semanticSearch ?? { query, sessions, provider, recent, path in
            try await semanticEngine.search(query, sessions: sessions, provider: provider, recentFirst: recent, path: path)
        }
        if preview {
            let now = Date().timeIntervalSince1970
            sessions = [
                Session(id: "1", cwd: "/Users/demo/Projects/Backtrace", title: "A library for past conversations", branch: "main", first: "Build a small Mac app to find and resume saved coding conversations.", latest: "Let’s call it Backtrace. Search the actual conversation, not just its title, and show the matching passage.", searchText: "Backtrace local conversation search", updated: now - 86400),
                Session(id: "2", provider: "claude", cwd: "/Users/demo/Projects/ExampleApp", title: "Fix notification delivery", branch: "fix/push-registration", latest: "Check the registration path when the app returns to the foreground.", updated: now - 4200),
                Session(id: "3", cwd: "/Users/demo/Projects/PersonalSite", title: "Turn blog snippets into tweets", latest: "Keep the code examples intact.", updated: now - 7000),
                Session(id: "4", cwd: "/Users/demo/Projects/ExampleApp", title: "Audit feature flags", updated: now - 12000),
                Session(id: "5", provider: "claude", cwd: "/Users/demo/Projects/ExampleApp", title: "Make clean builds faster", updated: now - 86400),
                Session(id: "6", cwd: "/Users/demo/Projects/FreeParking", title: "Restore saved terminal titles", updated: now - 120000)
            ]
            engine = SearchEngine(sessions)
            hits = engine.search("")
            selected = hits.first?.id
            indexedAt = Date()
            return
        }
        guard refreshOnStart else { return }
        if let flag = CommandLine.arguments.firstIndex(of: "--search"), flag + 1 < CommandLine.arguments.count {
            query = CommandLine.arguments[flag + 1]
        }
        Task {
            await loadCache()
            await refresh()
        }
    }
    func isFavourite(_ id: String) -> Bool { favouriteIDs.contains(id) }
    func toggleFavourite(_ id: String) {
        if !favouriteIDs.insert(id).inserted { favouriteIDs.remove(id) }
        favouritesDefaults?.set(favouriteIDs.sorted(), forKey: Self.favouritesKey)
        // Starring in All is just a preference write, not a new search/index pass.
        if favouritesOnly { search() }
    }
    func snapshot(_ sessions: [Session], query: String) {
        self.sessions = sessions
        engine = SearchEngine(sessions)
        self.query = query
        snapshotFrozen = true
        searchTask?.cancel()
        searching = false
        let scopedSessions = favouritesOnly ? sessions.filter { favouriteIDs.contains($0.id) } : sessions
        hits = (try? LocalSearch.search(query, sessions: scopedSessions, path: searchPath)) ?? []
        selected = hits.first(where: { $0.session.title.contains("Free Parking UI") })?.id ?? hits.first?.id
    }
    func loadCache() async {
        let url = cache
        let result = await Task.detached(priority: .userInitiated) { () -> SessionIndex? in
            guard let data = try? Data(contentsOf: url), let index = try? JSONDecoder().decode(SessionIndex.self, from: data), index.version == 1 else { return nil }
            return index
        }.value
        if let index = result {
            sessions = index.sessions
            indexedAt = Date(timeIntervalSince1970: index.indexedAt)
            notice = index.warnings.joined(separator: "\n")
            search()
        }
    }
    func search() {
        guard !snapshotFrozen else { return }
        searching = true
        semanticSearching = false
        generation += 1
        let version = generation
        let favouritesOnly = favouritesOnly, favouriteIDs = favouriteIDs
        let engine = engine, query = query, provider = provider, related = related, recent = recentFirst, preview = preview, path = searchPath
        let sessions = favouritesOnly || provider != "all" ? self.sessions.filter {
            (!favouritesOnly || favouriteIDs.contains($0.id)) && (provider == "all" || $0.provider == provider)
        } : self.sessions
        searchTask?.cancel()
        lexicalTask?.cancel()
        snippetTask?.cancel(); snippetWorker?.cancel(); snippetTask = nil
        pendingSnippets.removeAll(); requestedSnippets.removeAll()
        // Never flash non-favourites while a tab change or unstar is settling.
        if favouritesOnly {
            hits.removeAll { !favouriteIDs.contains($0.id) }
            if !visible.contains(where: { $0.id == selected }) { selected = hits.first?.id }
        }
        guard !sessions.isEmpty else {
            hits = []; selected = nil; searching = false; searchMS = 0
            return
        }
        searchTask = Task {
            do { try await Task.sleep(for: .milliseconds(35)) } catch { return }
            guard !Task.isCancelled else { return }
            let start = CFAbsoluteTimeGetCurrent()
            let worker = Task.detached(priority: .userInitiated) { () -> ([SearchHit], String?) in
                if preview {
                    var hits = engine.search(query, provider: provider, related: false, recentFirst: recent)
                        .filter { !favouritesOnly || favouriteIDs.contains($0.id) }
                    for i in hits.indices {
                        hits[i].snippet = hits[i].session.latest.replacingOccurrences(of: "Backtrace", with: "⟦Backtrace⟧")
                        hits[i].matchSource = "Assistant reply"
                    }
                    return (hits, nil)
                }
                do {
                    return (try LocalSearch.search(query, sessions: sessions, provider: provider, recentFirst: recent, path: path), nil)
                } catch is CancellationError {
                    return ([], nil)
                } catch {
                    return (SearchEngine(sessions).search(query, provider: provider, related: false, recentFirst: recent), "Transcript index is not ready. Showing session details for now.")
                }
            }
            lexicalTask = worker
            let result = await worker.value
            guard version == generation, !Task.isCancelled else { return }
            searching = false
            hits = result.0
            searchMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
            if let warning = result.1 { notice = warning }
            else if notice.hasPrefix("Transcript index is not ready") { notice = "" }
            if !visible.contains(where: { $0.id == selected }) { selected = hits.first?.id }
            guard related, !preview, hits.count < 20, SearchEngine.tokens(query).count >= 2 else { return }
            do {
                // Let typing settle before asking the model. Keyword results are already visible.
                try await Task.sleep(for: .milliseconds(140))
                guard version == generation, !Task.isCancelled else { return }
                semanticSearching = true
                let semantic = try await semanticSearch(query, sessions, provider, recent, path)
                guard version == generation, !Task.isCancelled else { return }
                semanticNotice = ""
                // Exact/prefix results retain their excerpts. Meaning-only hits are labelled.
                let exactIDs = Set(hits.map(\.id))
                hits = LocalSearch.sort(hits + semantic.filter { !exactIDs.contains($0.id) })
                if selected == nil { selected = hits.first?.id }
            } catch is CancellationError { return }
            catch {
                guard version == generation, !Task.isCancelled else { return }
                semanticNotice = "Semantic search unavailable; full-text results are still shown."
            }
            guard version == generation else { return }
            semanticSearching = false
        }
    }
    func ensureSnippet(for id: String) {
        guard !searching, !query.isEmpty, !snapshotFrozen,
              let index = hits.firstIndex(where: { $0.id == id }), hits[index].snippet.isEmpty else { return }
        for hit in hits[index..<min(hits.count, index + 12)] where !hit.semantic && hit.snippet.isEmpty {
            if requestedSnippets.insert(hit.id).inserted { pendingSnippets.insert(hit.id) }
        }
        guard snippetTask == nil, !pendingSnippets.isEmpty else { return }
        let version = generation, query = query, path = searchPath
        snippetTask = Task {
            defer { if generation == version { snippetTask = nil } }
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
            while generation == version && !pendingSnippets.isEmpty && !Task.isCancelled {
                let ids = pendingSnippets; pendingSnippets.removeAll()
                let sessions = hits.filter { ids.contains($0.id) }.map(\.session)
                let worker = Task.detached(priority: .userInitiated) {
                    (try? LocalSearch.snippets(query, sessions: sessions, path: path)) ?? [:]
                }
                snippetWorker = worker
                let values = await worker.value
                guard generation == version, !Task.isCancelled else { return }
                for i in hits.indices {
                    if let value = values[hits[i].id], !hits[i].semantic {
                        hits[i].snippet = value.0
                        if !value.1.isEmpty { hits[i].matchSource = value.1 }
                    }
                }
            }
        }
    }
    func updateCoverage() async {
        let path = searchPath
        let value = await Task.detached(priority: .utility) { LocalSearch.coverage(path: path) }.value
        let changed = value.conversations != coverage.conversations
        coverage = value
        if changed && sessions.isEmpty { await loadCache() }
        else if changed && !query.isEmpty && !searching { search() }
    }
    func buildSemantics() {
        guard related, !preview, semanticTask == nil, coverage.passages > coverage.embedded else { return }
        semanticIndexing = true
        let path = searchPath
        semanticTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var succeeded = false
            do {
                try await SemanticIndexer.build(path: path) { [weak self] in await self?.updateCoverage() }
                succeeded = true
            } catch is CancellationError {
                // Switching meaning search off is not an error.
            } catch {
                await MainActor.run { self.semanticNotice = error.localizedDescription }
            }
            let cancelled = Task.isCancelled, completed = succeeded
            await MainActor.run {
                self.semanticIndexing = false
                self.semanticTask = nil
                if completed && self.related { self.semanticNotice = ""; self.search() }
                // The toggle may have switched back on while cancellation drained.
                if cancelled && self.related { self.buildSemantics() }
            }
        }
    }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        let monitor = Task {
            while !Task.isCancelled {
                await updateCoverage()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        defer { refreshing = false; monitor.cancel() }
        do {
            let summary = try JSONDecoder().decode(RefreshSummary.self, from: await refreshRunner())
            if summary.changed || sessions.isEmpty { await loadCache() }
            notice = summary.warnings.joined(separator: "\n")
            // Cache contents needn't change for a refresh to be successful.
            indexedAt = Date()
            await updateCoverage()
            buildSemantics()
        } catch { self.error = "Couldn’t refresh the local index. Cached results are still available.\n\n\(error.localizedDescription)" }
    }
    func move(_ delta: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selected } ?? 0
        selected = list[max(0, min(list.count - 1, index + delta))].id
    }
    func copyCommand() {
        guard let current else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(current.command, forType: .string)
    }
    func openSession() {
        guard let session = current, session.available, !opening, !searching else { return }
        opening = true
        Task {
            defer { opening = false }
            do {
                _ = try await Self.helper(["--validate"], input: JSONEncoder().encode(session))
                try await Self.launch(session)
            } catch { self.error = error.localizedDescription }
        }
    }
    nonisolated static func helper(_ args: [String], input: Data? = nil) async throws -> Data {
        guard let script = Bundle.main.url(forResource: "index_sessions", withExtension: "py") else {
            throw AppError("The index helper is missing. Rebuild using scripts/build-app.sh.")
        }
        return try await Task.detached(priority: .utility) {
            try run("/usr/bin/python3", ["-B", script.path] + args, input: input)
        }.value
    }
    nonisolated static func run(_ executable: String, _ args: [String], input: Data? = nil) throws -> Data {
        let p = Process(), out = Pipe(), err = Pipe(), stdin = Pipe()
        p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
        p.standardOutput = out; p.standardError = err
        if input != nil { p.standardInput = stdin }
        try p.run()
        if let input { stdin.fileHandleForWriting.write(input); try? stdin.fileHandleForWriting.close() }
        // Helper/AppleScript output is bounded to a single short response.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw AppError(String(data: errors, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Command failed.")
        }
        return data
    }
    nonisolated static func appleString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
    nonisolated static func launch(_ session: Session) async throws {
        // Create a fresh tab with its command at process creation. Never write into
        // an existing session or use keystrokes (which could hit a running agent).
        let command = "/bin/zsh -lic " + Session.quote(session.command + "; exec /bin/zsh -l")
        let hasITerm = await MainActor.run { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil }
        let script: String
        if hasITerm {
            script = TerminalScript.iTerm(command: command)
        } else {
            script = "tell application id \"com.apple.Terminal\"\ndo script \(appleString(command))\nactivate\nend tell"
        }
        do {
            _ = try await Task.detached(priority: .userInitiated) { try run("/usr/bin/osascript", ["-e", script]) }.value
        } catch {
            throw AppError("Couldn’t open the session in a new terminal tab. If Automation access was denied, allow Backtrace to control iTerm or Terminal in System Settings → Privacy & Security → Automation. You can also copy the resume command.\n\n\(error.localizedDescription)")
        }
    }
}
private struct RefreshSummary: Decodable {
    let changed: Bool
    let warnings: [String]
}
struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
