import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private var controller: MainWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MainWindowController(store: store)
        controller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { store.save() }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About Fount"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide Fount"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: String(localized: "Quit Fount"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu

        let fileMenu = NSMenu(title: String(localized: "File"))
        fileMenu.addItem(withTitle: String(localized: "Add Feed…"), action: #selector(MainWindowController.addFeed(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: String(localized: "Import OPML…"), action: #selector(MainWindowController.importOPML(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: String(localized: "Refresh"), action: #selector(MainWindowController.refresh(_:)), keyEquivalent: "r")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: String(localized: "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = fileMenu

        let editMenu = NSMenu(title: String(localized: "Edit"))
        editMenu.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = editMenu

        let viewMenu = NSMenu(title: String(localized: "View"))
        viewMenu.addItem(withTitle: String(localized: "Unread Only"), action: #selector(MainWindowController.toggleUnreadOnly(_:)), keyEquivalent: "u").keyEquivalentModifierMask = [.command, .shift]
        let sortMenu = NSMenu(title: String(localized: "Sort Feeds By"))
        sortMenu.addItem(withTitle: String(localized: "Title"), action: #selector(MainWindowController.sortFeeds(_:)), keyEquivalent: "").tag = 0
        sortMenu.addItem(withTitle: String(localized: "Date Added"), action: #selector(MainWindowController.sortFeeds(_:)), keyEquivalent: "").tag = 1
        sortMenu.addItem(withTitle: String(localized: "Latest Article"), action: #selector(MainWindowController.sortFeeds(_:)), keyEquivalent: "").tag = 2
        sortMenu.addItem(.separator())
        sortMenu.addItem(withTitle: String(localized: "Ascending"), action: #selector(MainWindowController.setFeedSortOrder(_:)), keyEquivalent: "").tag = 0
        sortMenu.addItem(withTitle: String(localized: "Descending"), action: #selector(MainWindowController.setFeedSortOrder(_:)), keyEquivalent: "").tag = 1
        viewMenu.addItem(withTitle: String(localized: "Sort Feeds By"), action: nil, keyEquivalent: "").submenu = sortMenu
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: String(localized: "Zoom In"), action: #selector(MainWindowController.zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: String(localized: "Zoom Out"), action: #selector(MainWindowController.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: String(localized: "Actual Size"), action: #selector(MainWindowController.actualSize(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: String(localized: "Toggle Sidebar"), action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s").keyEquivalentModifierMask = [.command, .control]
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = viewMenu

        let articleMenu = NSMenu(title: String(localized: "Article"))
        articleMenu.addItem(withTitle: String(localized: "Open in Browser"), action: #selector(MainWindowController.openInBrowser(_:)), keyEquivalent: "\r")
        articleMenu.addItem(withTitle: String(localized: "Copy Link"), action: #selector(MainWindowController.copyLink(_:)), keyEquivalent: "C").keyEquivalentModifierMask = [.command, .shift]
        articleMenu.addItem(withTitle: String(localized: "Mark as Read"), action: #selector(MainWindowController.toggleRead(_:)), keyEquivalent: "U").keyEquivalentModifierMask = [.command, .shift, .option]
        articleMenu.addItem(withTitle: String(localized: "Mark All as Read"), action: #selector(MainWindowController.markAllRead(_:)), keyEquivalent: "k")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = articleMenu

        let windowMenu = NSMenu(title: String(localized: "Window"))
        windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        return main
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
