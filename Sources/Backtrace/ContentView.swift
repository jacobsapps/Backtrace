import AppKit
import BacktraceCore
import SwiftUI

private enum Notebook {
    static let paper = Color(red: 0.975, green: 0.965, blue: 0.94)
    static let ink = Color(red: 0.23, green: 0.25, blue: 0.22)
    static let muted = Color(red: 0.47, green: 0.48, blue: 0.43)
    static let accent = Color(red: 0.28, green: 0.39, blue: 0.31)
    static let selection = Color(red: 0.90, green: 0.925, blue: 0.875)
}

struct ContentView: View {
    @ObservedObject var store: Store
    @FocusState private var searchFocused: Bool
    @State private var hovered: String?
    @State private var detail: Session?
    @State private var confirmYOLO = false

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            libraryTabs
            results.padding(.top, 8).padding(.bottom, 18)
        }
        .background {
            Notebook.paper
                .overlay(alignment: .topLeading) {
                    LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
        }
        .foregroundStyle(Notebook.ink)
        .tint(Notebook.accent)
        .preferredColorScheme(.light)
        .onAppear { searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in searchFocused = true }
        .background(Button("") { searchFocused = true }.keyboardShortcut("l").hidden())
        .sheet(item: $detail) { session in
            SessionDetails(session: session, store: store)
        }
        .alert("Backtrace", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(nsImage: BrandAssets.logo)
                .resizable().scaledToFit().frame(width: 29, height: 31)
                .accessibilityHidden(true)
            Text("Backtrace").font(.system(size: 28, weight: .regular, design: .serif)).tracking(-0.8)
            Spacer()
            Menu {
                Picker("Sessions", selection: $store.provider) {
                    Text("All sessions").tag("all")
                    Text("Codex").tag("codex")
                    Text("Claude").tag("claude")
                }
                Divider()
                Toggle("Prefer recent sessions when close", isOn: $store.recentFirst)
                Toggle("Search phrases by meaning", isOn: $store.related)
                Divider()
                Toggle("Reopen in YOLO mode", isOn: Binding(
                    get: { store.reopenInYOLOMode },
                    set: { enabled in
                        if enabled { confirmYOLO = true }
                        else { store.reopenInYOLOMode = false }
                    }
                ))
                .help("On skips approval checks and Codex’s sandbox. Off uses your CLI settings, which may already allow full access.")
                .accessibilityIdentifier("yolo-toggle")
                Divider()
                Button("Refresh sessions") { Task { await store.refresh() } }
                    .disabled(store.refreshing)
                if store.semanticIndexing {
                    Text("Indexing meaning: \(store.coverage.embedded.formatted()) / \(store.coverage.passages.formatted()) passages")
                }
                if !store.notice.isEmpty { Text(store.notice) }
                if !store.semanticNotice.isEmpty { Text(store.semanticNotice) }
            } label: {
                Image(systemName: store.notice.isEmpty && store.semanticNotice.isEmpty ? "ellipsis" : "exclamationmark.circle").font(.system(size: 17))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(Notebook.muted)
            .help("Options").accessibilityLabel("Options")
            .accessibilityIdentifier("library-options")
        }.padding(.horizontal, 34).padding(.top, 34).padding(.bottom, 24)
        .alert("Enable YOLO mode?", isPresented: $confirmYOLO) {
            Button("Cancel", role: .cancel) {}
            Button("Enable YOLO") { store.reopenInYOLOMode = true }
        } message: {
            Text("Reopened sessions will skip approval checks. Codex also runs without its sandbox. Agents can change files and run commands without asking.\n\nThis applies to future opens and copied commands, not running tabs. When off, permissions are left to your CLI settings, which may already allow full access.")
        }
    }

    private var searchBar: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(Notebook.muted)
            TextField("Find a session…", text: $store.query)
                .font(.system(size: 16)).textFieldStyle(.plain).focused($searchFocused)
                .onSubmit { store.openSession() }
                .onKeyPress(.downArrow) { store.move(1); return .handled }
                .onKeyPress(.upArrow) { store.move(-1); return .handled }
                .onKeyPress(.escape) { store.query = ""; return .handled }
                .accessibilityLabel("Search sessions")
            if store.searching || store.semanticSearching {
                ProgressView().controlSize(.mini)
            }
            if !store.query.isEmpty {
                Button { store.query = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Notebook.muted.opacity(0.6))
                }.buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 15)
        .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Notebook.accent.opacity(searchFocused ? 0.3 : 0.12)))
        .contentShape(RoundedRectangle(cornerRadius: 11))
        // The icon, inset padding, and empty space focus the actual text field.
        // Simultaneous recognition preserves native caret placement and Clear.
        .simultaneousGesture(TapGesture().onEnded { searchFocused = true })
        .padding(.horizontal, 28)
    }

    private var libraryTabs: some View {
        HStack(spacing: 22) {
            libraryTab("All", favourites: false)
            libraryTab("Favourites", favourites: true)
            Spacer()
        }
        .padding(.horizontal, 34).padding(.top, 10)
    }

    private func libraryTab(_ title: String, favourites: Bool) -> some View {
        let selected = store.favouritesOnly == favourites
        return Button { store.favouritesOnly = favourites } label: {
            Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Notebook.ink : Notebook.muted)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selected ? Notebook.accent : .clear).frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(favourites ? "favourites-tab" : "all-tab")
    }

    private var emptyTitle: String {
        if store.refreshing && store.sessions.isEmpty { return "Gathering your sessions…" }
        if store.favouritesOnly { return store.favouriteIDs.isEmpty ? "No favourites yet." : "No matching favourites." }
        return "Nothing here just yet."
    }

    private var emptyHint: String {
        if store.favouritesOnly {
            return store.favouriteIDs.isEmpty ? "Star a session to keep it here." : "Try another search or session filter."
        }
        return store.sessions.isEmpty ? "Your saved conversations will appear here." : "Try another word or folder."
    }

    private var results: some View {
        Group {
            if store.hits.isEmpty {
                VStack(spacing: 9) {
                    Text(emptyTitle)
                        .font(.system(size: 18, design: .serif))
                    Text(emptyHint)
                        .font(.system(size: 12)).foregroundStyle(Notebook.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(store.visible) { hit in
                                row(hit).id(hit.id)
                                    .onAppear { store.ensureSnippet(for: hit.id) }
                                    .onChange(of: store.searching) { _, searching in
                                        if !searching { store.ensureSnippet(for: hit.id) }
                                    }
                            }
                        }.padding(.horizontal, 22).padding(.bottom, 4)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: store.selected) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ hit: SearchHit) -> some View {
        let s = hit.session
        let selected = store.selected == s.id
        let favourite = store.isFavourite(s.id)
        return HStack(spacing: 6) {
            Button {
                store.selected = s.id
                store.openSession()
            } label: {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(s.title).font(.system(size: 14, weight: .medium))
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(folderLabel(s.cwd))
                            .font(.system(size: 11)).foregroundStyle(Notebook.muted)
                            .lineLimit(1).truncationMode(.middle)
                        if !store.query.isEmpty, !hit.snippet.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                if hit.semantic {
                                    Image(systemName: "sparkle")
                                        .font(.system(size: 10)).foregroundStyle(Notebook.accent)
                                        .help("Similar meaning, not an exact phrase match")
                                        .accessibilityLabel("Similar meaning")
                                }
                                Text(highlighted(hit.snippet))
                                    .font(.system(size: 12)).foregroundStyle(Notebook.muted)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                            }.padding(.top, 3)
                        }
                    }
                    Spacer(minLength: 0)
                    if !s.available {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 12)).foregroundStyle(Notebook.accent)
                    } else {
                        Text(relative(s.updated)).font(.system(size: 10))
                            .foregroundStyle(Notebook.muted).fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.opening || store.searching || !s.available)
            .help("\(s.provider.capitalized)\n\(s.cwd)\(hit.semantic ? "\nSimilar meaning" : "")\n\(hit.matchSource)\nClick to reopen in a new terminal tab.")
            .accessibilityLabel("\(s.title), \(s.provider), \(s.cwd)")
            .accessibilityIdentifier("session-\(s.id)")
            .accessibilityHint(s.available ? "Reopen session" : "Original folder is missing")
            Button { store.toggleFavourite(s.id) } label: {
                Image(systemName: favourite ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(favourite ? Notebook.accent : Notebook.muted.opacity(0.6))
                    .frame(width: 24, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(favourite ? "Remove from Favourites" : "Add to Favourites")
            .accessibilityLabel("\(favourite ? "Remove from" : "Add to") Favourites: \(s.title)")
            .accessibilityValue(favourite ? "Favourite" : "Not a favourite")
            .accessibilityIdentifier("favourite-\(s.id)")
            Menu {
                actions(s)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 20, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(Notebook.muted)
            .opacity(selected || hovered == s.id ? 1 : 0)
            .accessibilityLabel("Options for \(s.title)")
            .accessibilityIdentifier("session-options-\(s.id)")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(selected ? Notebook.selection.opacity(0.65) : hovered == s.id ? Notebook.selection.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .onHover { hovered = $0 ? s.id : nil }
        .contextMenu { actions(s) }
    }

    @ViewBuilder private func actions(_ s: Session) -> some View {
        Button { store.toggleFavourite(s.id) } label: {
            Label(store.isFavourite(s.id) ? "Remove from Favourites" : "Add to Favourites",
                  systemImage: store.isFavourite(s.id) ? "star.slash" : "star")
        }
        Divider()
        Button("About this session…") { detail = s }
        Button("Copy resume command") { store.selected = s.id; store.copyCommand() }
        Button("Show folder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: s.cwd) }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString()
        // Render prose rather than Markdown punctuation while preserving match markers.
        let plain = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? text
        let parts = plain.components(separatedBy: "⟦")
        result += AttributedString(parts.first ?? "")
        for part in parts.dropFirst() {
            let pair = part.components(separatedBy: "⟧")
            var match = AttributedString(pair.first ?? "")
            match.backgroundColor = Color(red: 0.89, green: 0.85, blue: 0.60).opacity(0.5)
            match.foregroundColor = Notebook.ink
            match.font = .system(size: 13, weight: .semibold)
            result += match
            result += AttributedString(pair.dropFirst().joined(separator: "⟧"))
        }
        return result
    }
    private func folderLabel(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        // Keep the preview as quiet as real home-relative paths.
        if path.hasPrefix("/Users/demo/") { return "~/" + path.dropFirst("/Users/demo/".count) }
        return path
    }

    private func relative(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let seconds = max(0, Date().timeIntervalSince1970 - timestamp)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if Calendar.current.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

struct SessionDetails: View {
    let session: Session
    @ObservedObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(session.provider.capitalized).font(.system(size: 12)).foregroundStyle(Notebook.muted)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(session.title).font(.system(size: 23, design: .serif)).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let hit = store.hits.first(where: { $0.id == session.id }), !store.query.isEmpty, !hit.snippet.isEmpty {
                        field(hit.semantic ? "Similar meaning" : hit.matchSource, hit.snippet.replacingOccurrences(of: "⟦", with: "").replacingOccurrences(of: "⟧", with: ""))
                    }
                    field("Folder", session.cwd)
                    if !session.branch.isEmpty { field("Branch", session.branch) }
                    if !session.latest.isEmpty { field("Last prompt", session.latest) }
                    if !session.first.isEmpty && session.first != session.latest { field("First prompt", session.first) }
                    field("Session", session.sessionID)
                    field("Title", session.titleSource)
                    if !session.available {
                        Text("The original folder is missing. Restore it before reopening.")
                            .font(.system(size: 12)).foregroundStyle(Notebook.accent)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            HStack {
                Button("Copy command") { store.selected = session.id; store.copyCommand() }
                Spacer()
                Button("Reopen in tab") {
                    store.selected = session.id
                    dismiss()
                    store.openSession()
                }.disabled(!session.available || store.searching || store.opening)
            }
        }
        .buttonStyle(.borderless)
        .padding(28).frame(width: 440, height: 500)
        .background(Notebook.paper).foregroundStyle(Notebook.ink).tint(Notebook.accent)
    }

    private func field(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Notebook.muted)
            Text(text).font(.system(size: 13)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }
}
