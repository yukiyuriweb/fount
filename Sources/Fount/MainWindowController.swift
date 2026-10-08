import AppKit
import UniformTypeIdentifiers
import WebKit

@MainActor
final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSToolbarDelegate, NSMenuDelegate, NSMenuItemValidation, NSToolbarItemValidation,
    WKNavigationDelegate, WKUIDelegate {

    private let store: Store
    private let feedTable = NSTableView()
    private let articleTable = ArticleTableView()
    private let webView: WKWebView
    private let filter = NSSegmentedControl(labels: [String(localized: "All"), String(localized: "Unread")],
                                            trackingMode: .selectOne, target: nil, action: nil)

    /// nil shows the articles of every feed.
    private var selectedFeed: String?
    private var selectedKey: String?
    private var loadedKey: String?
    private var visible: [Article] = []
    private var unreadOnly = UserDefaults.standard.bool(forKey: "unreadOnly")
    /// Set while tables are reloaded, so restoring the selection doesn't count as the user's choice.
    private var reloading = false
    private var adding = false
    private var refreshTimer: Timer?

    private static let feedColumn = NSUserInterfaceItemIdentifier("feed")
    private static let articleColumn = NSUserInterfaceItemIdentifier("article")

    init(store: Store) {
        self.store = store
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)

        setUp(feedTable, column: Self.feedColumn)
        feedTable.style = .sourceList
        feedTable.rowHeight = 26
        feedTable.menu = contextMenu()

        setUp(articleTable, column: Self.articleColumn)
        articleTable.style = .plain
        articleTable.rowHeight = 62
        articleTable.menu = contextMenu()
        articleTable.onKey = { [unowned self] in self.handleKey($0) }

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        let zoom = UserDefaults.standard.double(forKey: "pageZoom")
        webView.pageZoom = zoom > 0 ? zoom : 1

        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: Self.wrap(scrolling(feedTable)))
        sidebar.minimumThickness = 160
        sidebar.maximumThickness = 400
        let list = NSSplitViewItem(contentListWithViewController: Self.wrap(scrolling(articleTable)))
        list.minimumThickness = 260
        list.maximumThickness = 600
        let detail = NSSplitViewItem(viewController: Self.wrap(webView))
        detail.minimumThickness = 360
        [sidebar, list, detail].forEach(split.addSplitViewItem)
        split.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
        split.splitView.autosaveName = "MainSplit"

        window.contentViewController = split
        window.title = "Fount"
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.center()
        window.setFrameAutosaveName("MainWindow")

        filter.selectedSegment = unreadOnly ? 1 : 0
        filter.target = self
        filter.action = #selector(filterChanged(_:))

        store.onChange = { [unowned self] in self.storeChanged() }
        storeChanged()
        feedTable.selectRowIndexes([0], byExtendingSelection: false)
        showPlaceholder()

        store.refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refresh() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp(_ table: NSTableView, column id: NSUserInterfaceItemIdentifier) {
        let column = NSTableColumn(identifier: id)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
    }

    private func scrolling(_ table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    private static func wrap(_ view: NSView) -> NSViewController {
        let controller = NSViewController()
        controller.view = view
        return controller
    }

    // MARK: Updating

    private func storeChanged() {
        reloading = true
        feedTable.reloadData()
        let row = selectedFeed.flatMap { url in store.feeds.firstIndex { $0.url == url }.map { $0 + 1 } } ?? 0
        if selectedFeed != nil && row == 0 { selectedFeed = nil }  // the feed was removed
        feedTable.selectRowIndexes([row], byExtendingSelection: false)
        reloading = false
        reloadArticles()

        let total = store.totalUnread
        window?.subtitle = adding ? String(localized: "Adding feed…")
            : store.isRefreshing ? String(localized: "Updating…")
            : total > 0 ? String(localized: "\(total) unread") : ""
        NSApp.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
        window?.toolbar?.validateVisibleItems()
    }

    private func reloadArticles() {
        visible = store.articles.filter {
            (selectedFeed == nil || $0.feed == selectedFeed)
                // Keep the open article listed after it turns read.
                && (!unreadOnly || !$0.read || $0.key == selectedKey)
        }
        reloading = true
        articleTable.reloadData()
        if let key = selectedKey, let row = visible.firstIndex(where: { $0.key == key }) {
            articleTable.selectRowIndexes([row], byExtendingSelection: false)
        }
        reloading = false
    }

    private func showPlaceholder() {
        loadedKey = nil
        let message = store.feeds.isEmpty
            ? String(localized: "Add a feed with ⌘N, or import an OPML file from the File menu.")
            : ""
        webView.loadHTMLString("""
            <html><head><meta name="color-scheme" content="light dark"></head>
            <body style="font: 14px -apple-system; color: GrayText; display: grid; place-items: center; height: 90vh">
            \(message)</body></html>
            """, baseURL: nil)
    }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === feedTable ? store.feeds.count + 1 : visible.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === feedTable {
            let cell = tableView.makeView(withIdentifier: Self.feedColumn, owner: nil) as? FeedCell ?? FeedCell()
            if row == 0 {
                cell.show(title: String(localized: "All Articles"), symbol: "tray.full",
                          unread: store.totalUnread, error: nil)
            } else {
                let feed = store.feeds[row - 1]
                cell.show(title: feed.title, symbol: "dot.radiowaves.up.forward",
                          unread: store.unreadCounts[feed.url] ?? 0, error: store.errors[feed.url])
            }
            return cell
        }
        let cell = tableView.makeView(withIdentifier: Self.articleColumn, owner: nil) as? ArticleCell ?? ArticleCell()
        let article = visible[row]
        cell.show(article, feedTitle: selectedFeed == nil ? store.feed(article.feed)?.title : nil)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading else { return }
        let table = notification.object as! NSTableView
        if table === feedTable {
            let row = feedTable.selectedRow
            selectedFeed = row > 0 ? store.feeds[row - 1].url : nil
            reloadArticles()
            articleTable.scrollRowToVisible(0)
        } else if articleTable.selectedRow >= 0 {
            open(visible[articleTable.selectedRow])
        }
    }

    private func open(_ article: Article) {
        selectedKey = article.key
        if loadedKey != article.key, let url = URL(string: article.link) {
            loadedKey = article.key
            webView.load(URLRequest(url: url))
        }
        store.setRead(article.key, true)
    }

    private var currentArticle: Article? {
        let row = articleTable.clickedRow >= 0 ? articleTable.clickedRow : articleTable.selectedRow
        return visible.indices.contains(row) ? visible[row] : nil
    }

    /// The feed the sidebar's context menu was opened on, or else the selected one.
    private var clickedFeed: String? {
        let row = feedTable.clickedRow >= 0 ? feedTable.clickedRow : feedTable.selectedRow
        return row > 0 ? store.feeds[row - 1].url : nil
    }

    // MARK: Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.charactersIgnoringModifiers {
        case "j": move(1)
        case "k": move(-1)
        case " ":
            let direction = event.modifierFlags.contains(.shift) ? -1 : 1
            webView.evaluateJavaScript("window.scrollBy(0, \(direction) * window.innerHeight * 0.85)")
        case "o", "\r": openInBrowser(nil)
        case "m": toggleRead(nil)
        default: return false
        }
        return true
    }

    private func move(_ delta: Int) {
        let row = max(0, min(visible.count - 1, articleTable.selectedRow + delta))
        guard visible.indices.contains(row) else { return }
        articleTable.selectRowIndexes([row], byExtendingSelection: false)
        articleTable.scrollRowToVisible(row)
    }

    // MARK: Actions

    @objc func addFeed(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Add Feed")
        alert.informativeText = String(localized: "Enter a feed URL, or the address of a page that links to one.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "https://zenn.dev/…"
        if let text = NSPasteboard.general.string(forType: .string), text.hasPrefix("http") {
            field.stringValue = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Add"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                self.subscribe(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    private func subscribe(_ input: String) {
        guard !input.isEmpty else { return }
        guard let url = URL(string: input.contains("://") ? input : "https://" + input) else {
            showError(FeedError.notFound)
            return
        }
        adding = true
        storeChanged()
        Task {
            defer { adding = false; storeChanged() }
            do {
                let (feedURL, parsed) = try await Fetcher.discover(url)
                store.add(feedURL.absoluteString, parsed)
                selectedFeed = feedURL.absoluteString
            } catch {
                showError(error)
            }
        }
    }

    @objc func importOPML(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml, .xml]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let feeds = OPMLParser.parse(data)
        guard !feeds.isEmpty else {
            showError(FeedError.notFound)
            return
        }
        store.importFeeds(feeds)
        store.refresh()
    }

    @objc func exportOPML(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml]
        panel.nameFieldStringValue = "Fount.opml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.opml().write(to: url, options: .atomic)
        } catch {
            showError(error)
        }
    }

    @objc func refresh(_ sender: Any?) { store.refresh() }

    @objc func filterChanged(_ sender: NSSegmentedControl) {
        unreadOnly = sender.selectedSegment == 1
        UserDefaults.standard.set(unreadOnly, forKey: "unreadOnly")
        reloadArticles()
    }

    @objc func toggleUnreadOnly(_ sender: Any?) {
        filter.selectedSegment = unreadOnly ? 0 : 1
        filterChanged(filter)
    }

    @objc func openInBrowser(_ sender: Any?) {
        // Prefer the page the reader is on, in case a link inside the article was followed.
        let url = sender is NSMenuItem && articleTable.clickedRow >= 0
            ? currentArticle.flatMap { URL(string: $0.link) }
            : webView.url?.scheme?.hasPrefix("http") == true ? webView.url : currentArticle.flatMap { URL(string: $0.link) }
        if let url { NSWorkspace.shared.open(url) }
    }

    @objc func copyLink(_ sender: Any?) {
        guard let link = currentArticle?.link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    @objc func toggleRead(_ sender: Any?) {
        guard let article = currentArticle else { return }
        store.setRead(article.key, !article.read)
    }

    @objc func markAllRead(_ sender: Any?) {
        store.markAllRead(feed: sender is NSMenuItem && feedTable.clickedRow >= 0 ? clickedFeed : selectedFeed)
    }

    @objc func copyFeedURL(_ sender: Any?) {
        guard let url = clickedFeed else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc func unsubscribe(_ sender: Any?) {
        guard let url = clickedFeed, let feed = store.feed(url), let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Unsubscribe from “\(feed.title)”?")
        alert.informativeText = String(localized: "Its articles are removed too.")
        alert.addButton(withTitle: String(localized: "Unsubscribe")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { self.store.remove(url) }
            }
        }
    }

    @objc func zoomIn(_ sender: Any?) { setZoom(webView.pageZoom * 1.1) }
    @objc func zoomOut(_ sender: Any?) { setZoom(webView.pageZoom / 1.1) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }

    private func setZoom(_ zoom: CGFloat) {
        webView.pageZoom = max(0.5, min(3, zoom))
        UserDefaults.standard.set(Double(webView.pageZoom), forKey: "pageZoom")
    }

    private func showError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn't add the feed")
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleUnreadOnly(_:)):
            item.state = unreadOnly ? .on : .off
        case #selector(openInBrowser(_:)), #selector(copyLink(_:)):
            return currentArticle != nil
        case #selector(toggleRead(_:)):
            item.title = currentArticle?.read == false ? String(localized: "Mark as Read") : String(localized: "Mark as Unread")
            return currentArticle != nil
        case #selector(unsubscribe(_:)), #selector(copyFeedURL(_:)):
            return clickedFeed != nil
        case #selector(refresh(_:)):
            return !store.isRefreshing
        case #selector(exportOPML(_:)):
            return !store.feeds.isEmpty
        default:
            break
        }
        return true
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.action {
        case #selector(refresh(_:)): return !store.isRefreshing
        case #selector(openInBrowser(_:)): return currentArticle != nil
        default: return true
        }
    }

    // MARK: Context menus

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === feedTable.menu {
            guard feedTable.clickedRow >= 0 else { return }
            menu.addItem(withTitle: String(localized: "Mark All as Read"), action: #selector(markAllRead(_:)), keyEquivalent: "")
            guard feedTable.clickedRow > 0 else { return }
            menu.addItem(withTitle: String(localized: "Copy Feed URL"), action: #selector(copyFeedURL(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: String(localized: "Unsubscribe…"), action: #selector(unsubscribe(_:)), keyEquivalent: "")
        } else {
            guard articleTable.clickedRow >= 0 else { return }
            menu.addItem(withTitle: String(localized: "Open in Browser"), action: #selector(openInBrowser(_:)), keyEquivalent: "")
            menu.addItem(withTitle: String(localized: "Copy Link"), action: #selector(copyLink(_:)), keyEquivalent: "")
            menu.addItem(withTitle: String(localized: "Mark as Read"), action: #selector(toggleRead(_:)), keyEquivalent: "")
        }
    }

    // MARK: Toolbar

    private static let addItem = NSToolbarItem.Identifier("add")
    private static let refreshItem = NSToolbarItem.Identifier("refresh")
    private static let filterItem = NSToolbarItem.Identifier("filter")
    private static let browserItem = NSToolbarItem.Identifier("browser")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.filterItem, .flexibleSpace,
         Self.refreshItem, Self.addItem, Self.browserItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        func button(_ label: String, _ symbol: String, _ action: Selector) {
            item.label = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.action = action
            item.target = self
            item.isBordered = true
        }
        switch id {
        case Self.addItem: button(String(localized: "Add Feed"), "plus", #selector(addFeed(_:)))
        case Self.refreshItem: button(String(localized: "Refresh"), "arrow.clockwise", #selector(refresh(_:)))
        case Self.browserItem: button(String(localized: "Open in Browser"), "safari", #selector(openInBrowser(_:)))
        case Self.filterItem:
            item.label = String(localized: "Filter")
            item.view = filter
        default: return nil
        }
        return item
    }

    // MARK: Web view

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // ⌘-click opens a link in the default browser, as in Safari.
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command), let url = action.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    /// Links meant for a new window (target=_blank) go to the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }
}

/// Lets the window controller handle reader shortcuts (j/k, space, o, m) before the table does.
final class ArticleTableView: NSTableView {
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

final class FeedCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("feed")
        title.lineBreakMode = .byTruncatingTail
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        count.textColor = .secondaryLabelColor
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = title
        imageView = icon
        for view in [icon, title, count] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(title text: String, symbol: String, unread: Int, error: String?) {
        title.stringValue = text
        count.stringValue = unread > 0 ? "\(unread)" : ""
        icon.image = NSImage(systemSymbolName: error == nil ? symbol : "exclamationmark.triangle",
                             accessibilityDescription: nil)
        icon.contentTintColor = error == nil ? nil : .systemOrange
        toolTip = error
    }
}

final class ArticleCell: NSTableCellView {
    private let title = NSTextField(wrappingLabelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let dot = NSView()
    private var unread = false

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("article")
        title.maximumNumberOfLines = 2
        title.cell?.truncatesLastVisibleLine = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        title.setContentHuggingPriority(.defaultLow, for: .vertical)
        meta.font = .systemFont(ofSize: 11)
        meta.lineBreakMode = .byTruncatingTail
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        textField = title
        for view in [dot, title, meta] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            dot.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            // A fixed height for two lines; the intrinsic size of a wrapping label is one line in a table cell.
            title.bottomAnchor.constraint(equalTo: meta.topAnchor, constant: -1),
            meta.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            meta.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            meta.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ article: Article, feedTitle: String?) {
        unread = !article.read
        title.stringValue = article.title.isEmpty ? article.link : article.title
        title.font = .systemFont(ofSize: 13, weight: unread ? .semibold : .regular)
        let date = Self.relative.localizedString(for: article.date, relativeTo: Date())
        meta.stringValue = [feedTitle, date].compactMap { $0 }.joined(separator: " · ")
        updateColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        meta.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        title.textColor = selected ? .alternateSelectedControlTextColor : unread ? .labelColor : .secondaryLabelColor
        dot.isHidden = !unread
        dot.layer?.backgroundColor = (selected ? NSColor.alternateSelectedControlTextColor : .controlAccentColor).cgColor
    }
}
