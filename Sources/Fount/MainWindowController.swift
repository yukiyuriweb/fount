import AppKit
import UniformTypeIdentifiers
import WebKit

@MainActor
final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSToolbarDelegate, NSMenuDelegate, NSMenuItemValidation, NSToolbarItemValidation,
    WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

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
    /// Articles read since the last Refresh. They stay listed under Unread, so the reader can go back to them,
    /// until Refresh clears them out together.
    private var keptRead: Set<String> = []
    /// Articles scrolled past during the current scroll, marked read once it settles.
    private var scrolledPast: Set<String> = []
    private var scrollSettleTimer: Timer?
    /// The first visible row when the current live scroll began: only rows that cross the top during it count.
    private var liveScrollStartRow: Int?
    /// Set while switching feeds opens the top article, so that opening isn't recorded as the reader's pick.
    private var openingTopArticle = false
    /// The article whose page is measured for how far it was scrolled, and the deepest point reached so far
    /// (the bottom of the window as a fraction of the page's height). Recorded when the reader leaves it.
    private var depthKey: String?
    private var depth: Double?
    /// The navigation that loads `depthKey`'s page. The page's reports count only once it has committed, so that
    /// late reports from the page before don't, and stop once any other page replaces it. Jumps within the page
    /// (a table of contents) and ⌘-clicked links, which open in the browser, commit nothing and keep it measured.
    private var depthNavigation: WKNavigation?
    private var measuringDepth = false
    /// Sidebar order, saved by raw value. Menu item tags are indexes into `allCases`.
    private enum FeedSort: String, CaseIterable { case title, added, latest }
    private var feedSort = FeedSort(rawValue: UserDefaults.standard.string(forKey: "feedSort") ?? "") ?? .title
    private var sortDescending = UserDefaults.standard.bool(forKey: "feedSortDescending")
    /// The article list is newest first unless this is set.
    private var oldestFirst = UserDefaults.standard.bool(forKey: "articlesOldestFirst")
    /// The article list's title size; View > Bigger / Smaller List Text change it.
    private var rowMetrics = ArticleRowMetrics(titleSize: {
        let saved = CGFloat(UserDefaults.standard.double(forKey: "articleListTextSize"))
        return ArticleRowMetrics.sizes.contains(saved) ? saved : ArticleRowMetrics.defaultSize
    }())
    /// `store.feeds` in sidebar order; row 0 is All Articles, so feed rows are offset by one.
    private var feeds: [Feed] = []
    /// Set while tables are reloaded, so restoring the selection doesn't count as the user's choice.
    private var reloading = false
    private var adding = false
    private var refreshTimer: Timer?
    /// Tells the menu bar item the unread count, which it shows while the window is closed too.
    var onUnreadCountChange: ((Int) -> Void)?

    private static let feedColumn = NSUserInterfaceItemIdentifier("feed")
    private static let articleColumn = NSUserInterfaceItemIdentifier("article")

    init(store: Store) {
        self.store = store
        let configuration = WKWebViewConfiguration()
        // Runs apart from the page's own scripts, so a page can neither see nor break it.
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.depthScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        webView = WKWebView(frame: .zero, configuration: configuration)
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
        articleTable.rowHeight = rowMetrics.rowHeight
        articleTable.menu = contextMenu()
        articleTable.onKey = { [unowned self] in self.handleKey($0) }

        webView.configuration.userContentController.add(self, contentWorld: .defaultClient, name: "depth")
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

        // Live scrolls are the user's own (trackpad, wheel, scroller), unlike the scrolling that
        // reloads, feed switches and sorting cause, so only they mark articles read.
        NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
                                               object: articleTable.enclosingScrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveScrollStartRow = self?.firstVisibleRow() }
        }
        NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification,
                                               object: articleTable.enclosingScrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.markScrolledPastRead() }
        }
        // Going back to the list to pick the next article, the one just read would only distract.
        NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
                                               object: articleTable.enclosingScrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeArticle() }
        }

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

        // Closing the window keeps the app, the store and this timer running in the menu bar, so the window
        // is kept for showing again.
        window.isReleasedWhenClosed = false
        store.refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refresh() }
        }
        // Busy feeds list only their latest items, so catch up right after sleep rather than up to 30 minutes later.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
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
        feeds = store.feeds
        switch feedSort {
        case .title:
            feeds.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .added:
            break
        case .latest:
            // Ascending puts the feed with the oldest newest article, or none, first.
            var latest: [String: Date] = [:]
            for a in store.articles where latest[a.feed] == nil { latest[a.feed] = a.date }  // newest first
            feeds.sort { latest[$0.url, default: .distantPast] < latest[$1.url, default: .distantPast] }
        }
        if sortDescending { feeds.reverse() }
        feedTable.reloadData()
        let row = selectedFeed.flatMap { url in feeds.firstIndex { $0.url == url }.map { $0 + 1 } } ?? 0
        if selectedFeed != nil && row == 0 { selectedFeed = nil }  // the feed was removed
        feedTable.selectRowIndexes([row], byExtendingSelection: false)
        reloading = false
        reloadArticles()

        let total = store.totalUnread
        window?.subtitle = adding ? String(localized: "Adding feed…")
            : store.isRefreshing ? String(localized: "Updating…")
            : total > 0 ? String(localized: "\(total) unread") : ""
        NSApp.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
        onUnreadCountChange?(total)
        window?.toolbar?.validateVisibleItems()
    }

    private func reloadArticles() {
        visible = store.articles.filter {
            (selectedFeed == nil || $0.feed == selectedFeed)
                // Keep articles read since the last Refresh, and the open one, listed after they turn read.
                && (!unreadOnly || !$0.read || keptRead.contains($0.key) || $0.key == selectedKey)
        }
        if oldestFirst { visible.reverse() }  // the store keeps articles newest first
        reloading = true
        articleTable.reloadData()
        if let key = selectedKey, let row = visible.firstIndex(where: { $0.key == key }) {
            articleTable.selectRowIndexes([row], byExtendingSelection: false)
        }
        reloading = false
    }

    /// The first row at least partly visible. The list scrolls under the toolbar, so its visible top
    /// starts below the content inset.
    private func firstVisibleRow() -> Int {
        guard let clip = articleTable.enclosingScrollView?.contentView else { return 0 }
        let top = clip.bounds.minY + clip.contentInsets.top
        guard top > 0 else { return 0 }
        let row = articleTable.row(at: NSPoint(x: 0, y: top))
        return row >= 0 ? row : visible.count
    }

    /// Collects the articles that scrolled entirely above the top of the list during the current live scroll,
    /// and marks them read once the scroll (momentum included) has settled: marking reloads both tables, which
    /// would stutter mid-scroll. Rows that were already above the top when the scroll began, say after sorting
    /// moved the list down, were never scrolled past and stay as they are. Marked articles stay listed until
    /// Refresh, like opened ones, so the rows don't shift under the pointer.
    private func markScrolledPastRead() {
        guard !reloading, let start = liveScrollStartRow else { return }
        let first = min(firstVisibleRow(), visible.count)
        guard first > start else { return }
        scrolledPast.formUnion(visible[start..<first].lazy.filter { !$0.read }.map(\.key))
        guard !scrolledPast.isEmpty else { return }
        scrollSettleTimer?.invalidate()
        scrollSettleTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.keptRead.formUnion(self.scrolledPast)
                self.recordSkipped()
                self.store.markRead(self.scrolledPast)
                self.scrolledPast = []
            }
        }
    }

    /// Clears the page and the list's selection when the user starts scrolling the list. The article stays
    /// listed (read articles are kept until Refresh), so clicking it opens it again.
    private func closeArticle() {
        guard articleTable.selectedRow >= 0 || loadedKey != nil else { return }
        selectedKey = nil
        reloading = true
        articleTable.deselectAll(nil)
        reloading = false
        showPlaceholder()
    }

    private func showPlaceholder() {
        finishReading()
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
        tableView === feedTable ? feeds.count + 1 : visible.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === feedTable {
            let cell = tableView.makeView(withIdentifier: Self.feedColumn, owner: nil) as? FeedCell ?? FeedCell()
            if row == 0 {
                cell.show(title: String(localized: "All Articles"), symbol: "tray.full",
                          unread: store.totalUnread, error: nil, dead: false)
            } else {
                let feed = feeds[row - 1]
                cell.show(title: feed.title, symbol: "dot.radiowaves.up.forward",
                          unread: store.unreadCounts[feed.url] ?? 0, error: store.errors[feed.url], dead: feed.looksDead)
            }
            return cell
        }
        let cell = tableView.makeView(withIdentifier: Self.articleColumn, owner: nil) as? ArticleCell ?? ArticleCell()
        let article = visible[row]
        cell.show(article, feedTitle: selectedFeed == nil ? store.feed(article.feed)?.title : nil, metrics: rowMetrics)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading else { return }
        let table = notification.object as! NSTableView
        if table === feedTable {
            let row = feedTable.selectedRow
            selectedFeed = row > 0 ? feeds[row - 1].url : nil
            // A new scope no longer keeps the open, read article listed under Unread.
            selectedKey = nil
            reloadArticles()
            articleTable.scrollRowToVisible(0)
            // Open the top article right away (selecting it opens it below), or clear the page if there is none.
            if visible.isEmpty {
                showPlaceholder()
            } else {
                openingTopArticle = true
                articleTable.selectRowIndexes([0], byExtendingSelection: false)
                openingTopArticle = false
            }
        } else if articleTable.selectedRow >= 0 {
            open(visible[articleTable.selectedRow])
        }
    }

    private func open(_ article: Article) {
        selectedKey = article.key
        if loadedKey != article.key, let url = URL(string: article.link) {
            finishReading()
            loadedKey = article.key
            depthKey = article.key
            depthNavigation = webView.load(URLRequest(url: url))
        }
        // Only articles that turn read here; an already-read one opened under All doesn't belong under Unread.
        if !article.read { keptRead.insert(article.key) }
        store.setRead(article.key, true)
        if !openingTopArticle { record(.opened, [article]) }
    }

    private func record(_ kind: History.Kind, _ articles: [Article]) {
        History.record(kind, articles) { [store] in store.feed($0)?.title }
    }

    /// Records how far the article on the page was scrolled, if its page reported it, and stops measuring.
    /// Called when another article or the placeholder replaces it, and when Fount quits.
    func finishReading() {
        if let key = depthKey, let depth, let article = store.articles.first(where: { $0.key == key }) {
            History.record(.depth, [article], depth: depth) { [store] in store.feed($0)?.title }
        }
        depthKey = nil
        depth = nil
        depthNavigation = nil
        measuringDepth = false
    }

    /// Reports the deepest point the page has been scrolled to, as a fraction of its height, whenever it grows
    /// by at least 2 % or reaches the end. A page shorter than the window reports 1 at once.
    private static let depthScript = """
        (() => {
          let deepest = 0;
          const report = () => {
            const height = document.documentElement.scrollHeight;
            if (!height) return;
            const depth = Math.min(1, (window.scrollY + window.innerHeight) / height);
            if (depth >= deepest + 0.02 || (depth === 1 && deepest < 1)) {
              deepest = depth;
              window.webkit.messageHandlers.depth.postMessage(depth);
            }
          };
          window.addEventListener("scroll", report, { passive: true });
          window.addEventListener("load", report);
          report();
        })();
        """

    /// Records the articles collected in `scrolledPast`, which are unread ones, before they are marked read.
    private func recordSkipped() {
        record(.skipped, store.articles.filter { scrolledPast.contains($0.key) && !$0.read })
    }

    private var currentArticle: Article? {
        let row = articleTable.clickedRow >= 0 ? articleTable.clickedRow : articleTable.selectedRow
        return visible.indices.contains(row) ? visible[row] : nil
    }

    /// The feed the sidebar's context menu was opened on, or else the selected one.
    private var clickedFeed: String? {
        let row = feedTable.clickedRow >= 0 ? feedTable.clickedRow : feedTable.selectedRow
        return row > 0 ? feeds[row - 1].url : nil
    }

    /// The feed a sidebar context-menu item was built for, or else `clickedFeed`. The item keeps the URL
    /// because a refresh can re-sort the sidebar while the menu is open, moving another feed under `clickedRow`.
    private func feed(from sender: Any?) -> String? {
        (sender as? NSMenuItem)?.representedObject as? String ?? clickedFeed
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
            showError(error, title: String(localized: "Couldn't export the subscriptions"))
        }
    }

    /// Clears the articles read since the last Refresh out of the Unread list, scrolls the list back to the top,
    /// then fetches.
    @objc func refresh(_ sender: Any?) {
        // Articles scrolled past just before are read too, so they go with the rest.
        scrollSettleTimer?.invalidate()
        recordSkipped()
        store.markRead(scrolledPast)
        scrolledPast = []
        keptRead.removeAll()
        reloadArticles()
        articleTable.scrollRowToVisible(0)
        store.refresh()
    }

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
        if let url {
            Browser.open(url)
            if let article = currentArticle { record(.browser, [article]) }
        }
    }

    /// Article > Browser; an item without an app is the system default.
    @objc func chooseBrowser(_ sender: NSMenuItem) {
        Browser.chosen = sender.representedObject as? URL
    }

    @objc func copyLink(_ sender: Any?) {
        guard let link = currentArticle?.link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    @objc func toggleRead(_ sender: Any?) {
        guard let article = currentArticle else { return }
        if !article.read { keptRead.insert(article.key) }
        store.setRead(article.key, !article.read)
    }

    @objc func markAllRead(_ sender: Any?) {
        store.markAllRead(feed: sender is NSMenuItem && feedTable.clickedRow >= 0 ? feed(from: sender) : selectedFeed)
    }

    @objc func copyFeedURL(_ sender: Any?) {
        guard let url = feed(from: sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc func unsubscribe(_ sender: Any?) {
        guard let url = feed(from: sender), let feed = store.feed(url), let window else { return }
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

    @objc func biggerListText(_ sender: Any?) { setListTextSize(rowMetrics.titleSize + 1) }
    @objc func smallerListText(_ sender: Any?) { setListTextSize(rowMetrics.titleSize - 1) }
    @objc func defaultListTextSize(_ sender: Any?) { setListTextSize(ArticleRowMetrics.defaultSize) }

    private func setListTextSize(_ size: CGFloat) {
        let size = min(max(size, ArticleRowMetrics.sizes.lowerBound), ArticleRowMetrics.sizes.upperBound)
        guard size != rowMetrics.titleSize else { return }
        rowMetrics = ArticleRowMetrics(titleSize: size)
        UserDefaults.standard.set(Double(size), forKey: "articleListTextSize")
        articleTable.rowHeight = rowMetrics.rowHeight
        reloadArticles()
    }

    @objc func zoomIn(_ sender: Any?) { setZoom(webView.pageZoom * 1.1) }
    @objc func zoomOut(_ sender: Any?) { setZoom(webView.pageZoom / 1.1) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }

    @objc func sortFeeds(_ sender: NSMenuItem) {
        feedSort = FeedSort.allCases[sender.tag]
        UserDefaults.standard.set(feedSort.rawValue, forKey: "feedSort")
        storeChanged()
    }

    /// Tag 0 is ascending, 1 descending.
    @objc func setFeedSortOrder(_ sender: NSMenuItem) {
        sortDescending = sender.tag == 1
        UserDefaults.standard.set(sortDescending, forKey: "feedSortDescending")
        storeChanged()
    }

    /// Tag 0 is newest first, 1 oldest first.
    @objc func sortArticles(_ sender: NSMenuItem) {
        oldestFirst = sender.tag == 1
        UserDefaults.standard.set(oldestFirst, forKey: "articlesOldestFirst")
        reloadArticles()
        articleTable.scrollRowToVisible(max(articleTable.selectedRow, 0))
    }

    private func setZoom(_ zoom: CGFloat) {
        webView.pageZoom = max(0.5, min(3, zoom))
        UserDefaults.standard.set(Double(webView.pageZoom), forKey: "pageZoom")
    }

    private func showError(_ error: Error, title: String = String(localized: "Couldn't add the feed")) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleUnreadOnly(_:)):
            item.state = unreadOnly ? .on : .off
        case #selector(sortFeeds(_:)):
            item.state = FeedSort.allCases[item.tag] == feedSort ? .on : .off
        case #selector(sortArticles(_:)):
            item.state = (item.tag == 1) == oldestFirst ? .on : .off
        case #selector(setFeedSortOrder(_:)):
            item.state = (item.tag == 1) == sortDescending ? .on : .off
        case #selector(biggerListText(_:)):
            return rowMetrics.titleSize < ArticleRowMetrics.sizes.upperBound
        case #selector(smallerListText(_:)):
            return rowMetrics.titleSize > ArticleRowMetrics.sizes.lowerBound
        case #selector(defaultListTextSize(_:)):
            return rowMetrics.titleSize != ArticleRowMetrics.defaultSize
        case #selector(chooseBrowser(_:)):
            item.state = (item.representedObject as? URL)?.path == Browser.chosen?.path ? .on : .off
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
            let url = clickedFeed
            menu.addItem(withTitle: String(localized: "Mark All as Read"), action: #selector(markAllRead(_:)), keyEquivalent: "").representedObject = url
            guard feedTable.clickedRow > 0 else { return }
            menu.addItem(withTitle: String(localized: "Copy Feed URL"), action: #selector(copyFeedURL(_:)), keyEquivalent: "").representedObject = url
            menu.addItem(.separator())
            menu.addItem(withTitle: String(localized: "Unsubscribe…"), action: #selector(unsubscribe(_:)), keyEquivalent: "").representedObject = url
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

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // Another page replacing the article, say through a link in it, isn't the article; its depth would mislead.
        measuringDepth = navigation === depthNavigation
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard measuringDepth, let value = message.body as? Double else { return }
        depth = max(depth ?? 0, value)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // ⌘-click opens a link in the browser, as in Safari.
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command), let url = action.request.url {
            Browser.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    /// Links meant for a new window (target=_blank) go to the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { Browser.open(url) }
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

    /// `dead` takes precedence over `error`: the feed has failed as if gone several refreshes in a row.
    func show(title text: String, symbol: String, unread: Int, error: String?, dead: Bool) {
        title.stringValue = text
        count.stringValue = unread > 0 ? "\(unread)" : ""
        if dead {
            icon.image = NSImage(systemSymbolName: "xmark.octagon", accessibilityDescription: nil)
            icon.contentTintColor = .systemRed
            toolTip = [String(localized: "This feed may no longer exist."), error].compactMap { $0 }.joined(separator: "\n")
        } else {
            icon.image = NSImage(systemSymbolName: error == nil ? symbol : "exclamationmark.triangle",
                                 accessibilityDescription: nil)
            icon.contentTintColor = error == nil ? nil : .systemOrange
            toolTip = error
        }
    }
}

/// Sizes of an article row, all derived from the title's font size (View > Bigger / Smaller List Text).
/// Every row has room for two title lines, the feed and time, and two lines of excerpt, so the list keeps
/// an even rhythm and the faint excerpt sets the titles apart.
struct ArticleRowMetrics {
    static let defaultSize: CGFloat = 15
    static let sizes: ClosedRange<CGFloat> = 11...24
    static let padding: CGFloat = 12
    static let gap: CGFloat = 4

    let titleSize: CGFloat
    func titleFont(unread: Bool) -> NSFont { .systemFont(ofSize: titleSize, weight: unread ? .semibold : .regular) }
    var metaFont: NSFont { .systemFont(ofSize: (titleSize * 0.8).rounded()) }
    var excerptFont: NSFont { .systemFont(ofSize: (titleSize * 0.87).rounded()) }

    /// Measured on text with Japanese in it: the fallback font for kana and kanji has taller lines than the
    /// system font's own line height, which would cut a Japanese title short.
    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ("Agあ漢" as NSString).size(withAttributes: [.font: font]).height.rounded(.up)
    }
    var titleLine: CGFloat { Self.lineHeight(titleFont(unread: true)) }
    var metaLine: CGFloat { Self.lineHeight(metaFont) }
    var excerptLine: CGFloat { Self.lineHeight(excerptFont) }

    var rowHeight: CGFloat {
        Self.padding + 2 * titleLine + Self.gap + metaLine + Self.gap + 2 * excerptLine + Self.padding
    }
    /// A 3:2 landscape thumbnail, 120 × 80 at the default size.
    var thumbnail: NSSize {
        let height = min((titleSize * 16 / 3).rounded(), rowHeight - 2 * Self.padding)
        return NSSize(width: (height * 1.5).rounded(), height: height)
    }
}

final class ArticleCell: NSTableCellView {
    private let title = NSTextField(wrappingLabelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let excerpt = NSTextField(wrappingLabelWithString: "")
    private let dot = NSView()
    private let thumbnail = NSView()
    private var image: String?
    private var unread = false
    private var metrics = ArticleRowMetrics(titleSize: ArticleRowMetrics.defaultSize)
    /// The text runs to the cell's edge, or stops at the thumbnail when there is one.
    private var titleToEdge: NSLayoutConstraint!
    private var titleToThumbnail: NSLayoutConstraint!
    /// One or two lines: the feed and the excerpt follow right under the title. Set in `layout()`, where the
    /// width is known; a wrapping label in a table cell reports only one line as its intrinsic height.
    private var titleHeight: NSLayoutConstraint!
    private var excerptHeight: NSLayoutConstraint!
    private var dotCenter: NSLayoutConstraint!
    private var thumbnailWidth: NSLayoutConstraint!
    private var thumbnailHeight: NSLayoutConstraint!

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("article")
        for label in [title, excerpt] {
            label.maximumNumberOfLines = 2
            label.cell?.truncatesLastVisibleLine = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }
        meta.lineBreakMode = .byTruncatingTail
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 6
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.contentsGravity = .resizeAspectFill
        textField = title
        for view in [dot, title, meta, excerpt, thumbnail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let padding = ArticleRowMetrics.padding, gap = ArticleRowMetrics.gap
        titleToEdge = title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        titleToThumbnail = title.trailingAnchor.constraint(equalTo: thumbnail.leadingAnchor, constant: -12)
        titleHeight = title.heightAnchor.constraint(equalToConstant: 20)
        excerptHeight = excerpt.heightAnchor.constraint(equalToConstant: 34)
        dotCenter = dot.centerYAnchor.constraint(equalTo: title.topAnchor)
        thumbnailWidth = thumbnail.widthAnchor.constraint(equalToConstant: 120)
        thumbnailHeight = thumbnail.heightAnchor.constraint(equalToConstant: 80)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            dotCenter,
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            titleToEdge,
            title.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            titleHeight,
            meta.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            meta.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            meta.topAnchor.constraint(equalTo: title.bottomAnchor, constant: gap),
            excerpt.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            excerpt.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            excerpt.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: gap),
            excerptHeight,
            thumbnail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            thumbnail.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            thumbnailWidth,
            thumbnailHeight,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ article: Article, feedTitle: String?, metrics: ArticleRowMetrics) {
        self.metrics = metrics
        unread = !article.read
        title.stringValue = article.title.isEmpty ? article.link : article.title
        title.font = metrics.titleFont(unread: unread)
        meta.font = metrics.metaFont
        let time = Self.relative.localizedString(for: article.date, relativeTo: Date())
        meta.stringValue = [feedTitle, time].compactMap { $0 }.joined(separator: "  ·  ")
        excerpt.font = metrics.excerptFont
        excerpt.stringValue = article.excerpt ?? ""
        excerptHeight.constant = 2 * metrics.excerptLine
        dotCenter.constant = (metrics.titleLine / 2).rounded()
        thumbnailWidth.constant = metrics.thumbnail.width
        thumbnailHeight.constant = metrics.thumbnail.height
        showImage(article.image)
        updateColors()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = title.frame.width
        guard width > 0 else { return }
        let fits = title.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0
        let height = min(max(fits.rounded(.up), metrics.titleLine), 2 * metrics.titleLine)
        if titleHeight.constant != height {
            titleHeight.constant = height
            super.layout()
        }
    }

    /// Keeps the thumbnail's space while it loads, and gives it back if it fails.
    private func showImage(_ url: String?) {
        image = url
        setThumbnail(url.flatMap(Thumbnails.cached), visible: url != nil)
        guard let url, Thumbnails.cached(url) == nil else { return }
        Task {
            let loaded = await Thumbnails.image(url)
            guard image == url else { return }  // The cell was reused meanwhile.
            setThumbnail(loaded, visible: loaded != nil)
        }
    }

    private func setThumbnail(_ loaded: CGImage?, visible: Bool) {
        thumbnail.layer?.contents = loaded
        thumbnail.layer?.backgroundColor = loaded == nil ? NSColor.quaternaryLabelColor.cgColor : nil
        thumbnail.isHidden = !visible
        titleToEdge.isActive = !visible
        titleToThumbnail.isActive = visible
        needsLayout = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    /// The excerpt is fainter than any system label color: it is there to space the titles out, not to be read.
    private static let excerptColor = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(white: 1, alpha: 0.3) : NSColor(white: 0, alpha: 0.3)
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        let onSelection = NSColor.alternateSelectedControlTextColor
        meta.textColor = selected ? onSelection : .secondaryLabelColor
        excerpt.textColor = selected ? onSelection.withAlphaComponent(0.6) : Self.excerptColor
        title.textColor = selected ? onSelection : unread ? .labelColor : .secondaryLabelColor
        dot.isHidden = !unread
        dot.layer?.backgroundColor = (selected ? onSelection : .controlAccentColor).cgColor
    }
}
