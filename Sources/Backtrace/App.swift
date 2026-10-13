import AppKit
import Carbon
import SwiftUI

@main struct BacktraceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store()
    @Environment(\.openWindow) private var openWindow
    init() {
        if CommandLine.arguments.contains("--verify-search") { Diagnostics.verifySearch(); exit(0) }
        if CommandLine.arguments.contains("--semantic-benchmark") { Diagnostics.semanticBenchmark(); exit(0) }
        if CommandLine.arguments.contains("--index-semantics") { Diagnostics.embedIndex(); exit(0) }
        if CommandLine.arguments.contains("--benchmark") { Diagnostics.benchmark(); exit(0) }
        if CommandLine.arguments.contains("--snapshot") { Diagnostics.snapshot(); exit(0) }
    }
    var body: some Scene {
        Window("Backtrace", id: "main") {
            ContentView(store: store)
                .onAppear {
                    delegate.presentWindow = { openWindow(id: "main") }
                    DispatchQueue.main.async { delegate.applyCompactLayoutOnce() }
                }
                .frame(minWidth: 460, minHeight: 440)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    if store.indexedAt == nil || Date().timeIntervalSince(store.indexedAt!) > 20 {
                        Task { await store.refresh() }
                    }
                }
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        if NSApp.isActive { await store.refresh() }
                    }
                }
        }
        .defaultSize(width: 620, height: 640)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Sessions") { Task { await store.refresh() } }.keyboardShortcut("r")
                Button("Copy Resume Command") { store.copyCommand() }.keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
        MenuBarExtra("Backtrace", systemImage: "clock.arrow.circlepath") {
            Button("Find a session…    ⌃⌥Space") { openWindow(id: "main"); delegate.show() }
            Button("Refresh Index") { Task { await store.refresh() } }
            Divider()
            Button("Quit Backtrace") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: EventHotKeyRef?
    var presentWindow: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in delegate.show() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: 0x4241434B, id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }
    func applyCompactLayoutOnce() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Backtrace" }) else { return }
        window.isMovableByWindowBackground = false
        guard !UserDefaults.standard.bool(forKey: "simpleLibraryLayoutApplied") else { return }
        window.setContentSize(NSSize(width: 620, height: 640))
        UserDefaults.standard.set(true, forKey: "simpleLibraryLayoutApplied")
    }
    func show() {
        presentWindow?()
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Backtrace" }) {
            window.makeKeyAndOrderFront(nil)
        }
        NotificationCenter.default.post(name: .focusSearch, object: nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
extension Notification.Name { static let focusSearch = Notification.Name("BacktraceFocusSearch") }
