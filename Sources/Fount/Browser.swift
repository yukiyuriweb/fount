import AppKit
import UniformTypeIdentifiers

/// The browser Fount opens pages in: the one picked in Article > Browser, or the system default.
enum Browser {
    private static let key = "browser"

    /// The picked browser's app bundle, or nil for the system default (also when the app is gone).
    static var chosen: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty,
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
        set { UserDefaults.standard.set(newValue?.path ?? "", forKey: key) }
    }

    static func open(_ url: URL) {
        if let app = chosen {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private static let probe = URL(string: "https://example.com")!

    static var systemDefault: URL? { NSWorkspace.shared.urlForApplication(toOpen: probe) }

    /// Browsers, one per bundle ID, by name. Downloaders and media players also claim https URLs,
    /// so only apps that open HTML files as well count.
    static var installed: [URL] {
        let html = Set(NSWorkspace.shared.urlsForApplications(toOpen: UTType.html).map(\.path))
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: probe)
            .filter { html.contains($0.path) && seen.insert(Bundle(url: $0)?.bundleIdentifier ?? $0.path).inserted }
            .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    /// The app's name without a trailing ".app", which the display name keeps when the Finder shows extensions.
    static func name(_ app: URL) -> String {
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static func icon(_ app: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

/// Fills Article > Browser each time it opens, since browsers come and go.
@MainActor
final class BrowserMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = BrowserMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let defaultTitle = Browser.systemDefault.map { String(localized: "System Default (\(Browser.name($0)))") }
            ?? String(localized: "System Default")
        menu.addItem(withTitle: defaultTitle, action: #selector(MainWindowController.chooseBrowser(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        for app in Browser.installed {
            let item = menu.addItem(withTitle: Browser.name(app), action: #selector(MainWindowController.chooseBrowser(_:)), keyEquivalent: "")
            item.image = Browser.icon(app)
            item.representedObject = app
        }
    }
}
