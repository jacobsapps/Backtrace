import Foundation

public struct Session: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var sessionID: String
    public var provider: String
    public var cwd: String
    public var transcript: String
    public var title: String
    public var titleSource: String
    public var branch: String
    public var first: String
    public var latest: String
    public var searchText: String
    public var updated: Double
    public var available: Bool
    public init(id: String, sessionID: String = "00000000-0000-0000-0000-000000000001", provider: String = "codex", cwd: String = "/tmp", transcript: String = "", title: String, titleSource: String = "Native session title", branch: String = "", first: String = "", latest: String = "", searchText: String = "", updated: Double, available: Bool = true) {
        self.id = id; self.sessionID = sessionID; self.provider = provider; self.cwd = cwd
        self.transcript = transcript; self.title = title; self.titleSource = titleSource
        self.branch = branch; self.first = first; self.latest = latest; self.searchText = searchText
        self.updated = updated; self.available = available
    }
    public var folder: String { URL(fileURLWithPath: cwd).lastPathComponent }
    public var command: String {
        "cd -- \(Self.quote(cwd)) && \(provider == "claude" ? "claude --resume" : "codex resume") \(Self.quote(sessionID))"
    }
    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

public struct SessionIndex: Codable, Sendable {
    public var version: Int
    public var indexedAt: Double
    public var duration: Double
    public var warnings: [String]
    public var sessions: [Session]
}

public struct SearchHit: Identifiable, Sendable {
    public var session: Session
    public var score: Double
    public var related: Bool
    public var snippet: String = ""
    public var matchSource: String = ""
    public var semantic: Bool = false
    public var id: String { session.id }
}

public struct SearchEngine: Sendable {
    struct Document: Sendable {
        let session: Session
        let title: String
        let fields: [(String, Double)]
        let words: [String: Double]
    }
    private var documents: [Document]
    private var vocabulary: Set<String>
    public init(_ sessions: [Session]) {
        vocabulary = []
        documents = sessions.map { s in
            let fields = [(s.title, 12.0), (s.cwd + " " + s.branch, 7.0), (s.first + " " + s.latest, 4.0), (s.searchText, 2.0), (s.sessionID, 8.0)]
                .map { (Self.normalize($0.0), $0.1) }
            var words: [String: Double] = [:]
            for (text, weight) in fields {
                for word in Self.tokens(text) { words[word] = max(words[word] ?? 0, weight) }
            }
            return Document(session: s, title: Self.normalize(s.title), fields: fields, words: words)
        }
        vocabulary = Set(documents.flatMap { $0.words.keys })
    }
    public static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public static func tokens(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    // Small, deterministic offline query expansion. No downloaded model or network.
    static let groups = [
        "crash crashes crashing exception fatal", "slow speed performance latency sluggish optimize optimization",
        "build compile compilation compiler xcode", "notification notifications push apns alert alerts",
        "background bgprocessing backgroundtask", "blog article post essay writing",
        "tweet tweets twitter social", "login signin authentication auth oauth",
        "storage disk space cleanup clean", "bug broken fix repair failure error",
        "ui interface screen layout design", "animation animate transition motion",
        "audio microphone mic sound recording", "meeting meetings notes transcript transcription",
        "deploy deployment release ship shipping", "test tests testing verify verification",
        "flag flags toggle rollout", "widget widgets live activity liveactivity",
        "session sessions conversation conversations chat", "image images picture photo screenshot",
        "price pricing cost billing spend", "search find lookup locate", "memory ram leak",
        "database db sqlite sql", "dependency dependencies package spm", "keyboard typing input"
    ].map { Set($0.split(separator: " ").map(String.init)) }
    static func expansions(_ term: String) -> Set<String> {
        groups.filter { $0.contains(term) }.reduce(into: Set<String>()) { $0.formUnion($1) }.subtracting([term])
    }
    public static func oneEdit(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            // Adjacent transpositions cover common typing mistakes.
            if a.count == b.count && i + 1 < a.count && a[i] == b[j + 1] && a[i + 1] == b[j] {
                i += 2; j += 2
            } else if a.count > b.count { i += 1 }
            else if b.count > a.count { j += 1 }
            else { i += 1; j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }
    public func search(_ query: String, provider: String = "all", related: Bool = true, recentFirst: Bool = true, now: Double = Date().timeIntervalSince1970) -> [SearchHit] {
        let normalized = Self.normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = Array(Set(Self.tokens(normalized))).sorted()
        let expansions = terms.map { related ? Self.expansions($0) : [] }
        let prefixes = terms.map { term in term.count >= 2 ? vocabulary.filter { $0 != term && $0.hasPrefix(term) } : [] }
        let typos = terms.map { term in
            term.count >= 5 ? vocabulary.filter { abs($0.count - term.count) <= 1 && Self.oneEdit(term, $0) } : []
        }
        var hits: [SearchHit] = []
        for doc in documents where provider == "all" || provider == doc.session.provider {
            var quality = 0.0
            var expanded = false
            var matches = true
            for (index, term) in terms.enumerated() {
                var weight = doc.words[term] ?? 0
                if weight == 0 {
                    for word in prefixes[index] { weight = max(weight, (doc.words[word] ?? 0) * 0.85) }
                }
                if weight == 0 && term.count >= 5 {
                    for word in typos[index] { weight = max(weight, (doc.words[word] ?? 0) * 0.55) }
                }
                if weight == 0 && related {
                    for synonym in expansions[index] { weight = max(weight, (doc.words[synonym] ?? 0) * 0.45) }
                    if weight > 0 { expanded = true }
                }
                if weight == 0 { matches = false; break }
                quality += weight
            }
            guard matches else { continue }
            if !terms.isEmpty && doc.title.contains(normalized) { quality += 12 }
            let days = max(0, now - doc.session.updated) / 86400
            // Compress text-score differences so recency dominates broad searches.
            // Equal-quality matches today rank up to ~17x above very old matches.
            let recency = 0.06 + 0.94 * exp(-days / 21)
            let score = terms.isEmpty ? doc.session.updated : (recentFirst ? sqrt(quality) * recency : quality)
            hits.append(SearchHit(session: doc.session, score: score, related: expanded))
        }
        return hits.sorted {
            if $0.score == $1.score {
                if $0.session.updated == $1.session.updated { return $0.id < $1.id }
                return $0.session.updated > $1.session.updated
            }
            return $0.score > $1.score
        }
    }
}
