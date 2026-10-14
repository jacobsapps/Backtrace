import AppKit

/// Small, cached vector assets generated alongside the app icon from one path.
/// Template rendering lets macOS adapt the menu-bar mark to light/dark mode.
enum BrandAssets {
    static let logo = load("BrandMark", size: NSSize(width: 29, height: 31))
    static let menuBar = load("MenuBarMark", size: NSSize(width: 17, height: 18), template: true)

    private static func load(_ name: String, size: NSSize, template: Bool = false) -> NSImage {
        let image = Bundle.main.url(forResource: name, withExtension: "pdf")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "Backtrace")
            ?? NSImage(size: size)
        image.size = size
        image.isTemplate = template
        return image
    }
}
