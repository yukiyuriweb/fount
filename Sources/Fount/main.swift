import AppKit
import ServiceManagement

/// Fount keeps refreshing after its window is closed: it leaves the Dock and stays in the menu bar with the
/// unread count, until Quit. Feeds list only their latest items, so a reader that isn't running misses
/// whatever scrolls out of them meanwhile.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = Store()
    private var controller: MainWindowController?
    private lazy var readingActivity = ReadingActivityController()
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private let loginItem = NSMenuItem(title: String(localized: "Open at Login"), action: #selector(toggleOpenAtLogin(_:)), keyEquivalent: "")

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read before anything else handles an Apple event.
        let atLogin = Self.launchedAsLoginItem
        let controller = MainWindowController(store: store)
        self.controller = controller
        controller.onUnreadCountChange = { [weak self] in self?.showUnread($0) }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: controller.window, queue: .main) { _ in
            MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
        }
        setUpStatusItem()
        showUnread(store.totalUnread)
        registerAtLoginOnce()
        if atLogin {
            NSApp.setActivationPolicy(.accessory)
        } else {
            openWindow(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening Fount again from the Finder or Spotlight while it sits in the menu bar brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow(nil)
        return true
    }

    @objc func openWindow(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular)
        controller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showReadingActivity(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        readingActivity.showWindow(sender)
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "dot.radiowaves.up.forward", accessibilityDescription: "Fount")
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: String(localized: "Open Fount"), action: #selector(openWindow(_:)), keyEquivalent: "").target = self
        let refresh = menu.addItem(withTitle: String(localized: "Refresh"), action: #selector(MainWindowController.refresh(_:)), keyEquivalent: "")
        refresh.target = controller
        menu.addItem(withTitle: String(localized: "Reading Activity…"), action: #selector(showReadingActivity(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Fount"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        // A click opens the window; the menu is for a right-click or Control-click.
        statusMenu = menu
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            // Attached only for this click, so a plain click doesn't open it
            statusItem?.menu = statusMenu
            sender.performClick(nil)
            statusItem?.menu = nil
        } else {
            openWindow(nil)
        }
    }

    private func showUnread(_ count: Int) {
        statusItem?.button?.title = count > 0 ? " \(count)" : ""
        statusItem?.button?.toolTip = count > 0 ? String(localized: "\(count) unread") : "Fount"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: Open at login

    /// Registers once; after that the menu bar item's toggle is the user's choice. A failed attempt is
    /// tried again on the next launch rather than leaving Fount off the login items for good.
    private func registerAtLoginOnce() {
        let key = "registeredOpenAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            NSLog("Fount couldn't register to open at login: %@", error.localizedDescription)
        }
    }

    @objc func toggleOpenAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// A login item starts in the menu bar without opening its window.
    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.finishReading()
        store.save()
    }

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
        fileMenu.addItem(withTitle: String(localized: "Export OPML…"), action: #selector(MainWindowController.exportOPML(_:)), keyEquivalent: "")
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
        let articleSortMenu = NSMenu(title: String(localized: "Sort Articles"))
        articleSortMenu.addItem(withTitle: String(localized: "Newest First"), action: #selector(MainWindowController.sortArticles(_:)), keyEquivalent: "").tag = 0
        articleSortMenu.addItem(withTitle: String(localized: "Oldest First"), action: #selector(MainWindowController.sortArticles(_:)), keyEquivalent: "").tag = 1
        viewMenu.addItem(withTitle: String(localized: "Sort Articles"), action: nil, keyEquivalent: "").submenu = articleSortMenu
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: String(localized: "Zoom In"), action: #selector(MainWindowController.zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: String(localized: "Zoom Out"), action: #selector(MainWindowController.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: String(localized: "Actual Size"), action: #selector(MainWindowController.actualSize(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: String(localized: "Bigger List Text"), action: #selector(MainWindowController.biggerListText(_:)), keyEquivalent: "+").keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(withTitle: String(localized: "Smaller List Text"), action: #selector(MainWindowController.smallerListText(_:)), keyEquivalent: "-").keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(withTitle: String(localized: "Default List Text Size"), action: #selector(MainWindowController.defaultListTextSize(_:)), keyEquivalent: "0").keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: String(localized: "Toggle Sidebar"), action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s").keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: String(localized: "Reading Activity…"), action: #selector(showReadingActivity(_:)), keyEquivalent: "").target = self
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = viewMenu

        let articleMenu = NSMenu(title: String(localized: "Article"))
        articleMenu.addItem(withTitle: String(localized: "Open in Browser"), action: #selector(MainWindowController.openInBrowser(_:)), keyEquivalent: "\r")
        articleMenu.addItem(withTitle: String(localized: "Copy Link"), action: #selector(MainWindowController.copyLink(_:)), keyEquivalent: "C").keyEquivalentModifierMask = [.command, .shift]
        articleMenu.addItem(withTitle: String(localized: "Mark as Read"), action: #selector(MainWindowController.toggleRead(_:)), keyEquivalent: "U").keyEquivalentModifierMask = [.command, .shift, .option]
        articleMenu.addItem(withTitle: String(localized: "Mark All as Read"), action: #selector(MainWindowController.markAllRead(_:)), keyEquivalent: "k")
        articleMenu.addItem(.separator())
        let browserMenu = NSMenu(title: String(localized: "Browser"))
        browserMenu.delegate = BrowserMenuDelegate.shared
        articleMenu.addItem(withTitle: String(localized: "Browser"), action: nil, keyEquivalent: "").submenu = browserMenu
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
