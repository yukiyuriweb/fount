import AppKit

@MainActor
final class ReadingActivityController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Column: String, CaseIterable {
        case site, opened, browser, skipped, depth

        var title: String {
            switch self {
            case .site: return String(localized: "Site")
            case .opened: return String(localized: "Articles Selected")
            case .browser: return String(localized: "Opened in Browser")
            case .skipped: return String(localized: "Skipped")
            case .depth: return String(localized: "Avg. Page Depth")
            }
        }

        var width: CGFloat {
            switch self {
            case .site: return 230
            case .opened, .depth: return 120
            case .browser: return 136
            case .skipped: return 78
            }
        }
    }

    private let table = NSTableView()
    private let overview = NSTextField(labelWithString: "")
    private var sites: [History.Site] = []
    private var loadTask: Task<Void, Never>?

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 740, height: 430),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = String(localized: "Reading Activity")
        panel.contentMinSize = NSSize(width: 650, height: 260)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.center()

        overview.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let notes = NSTextField(wrappingLabelWithString: String(localized:
            "Counts are grouped by the article’s site. Page depth is the furthest point shown, including the visible part of the page."))
        notes.textColor = .secondaryLabelColor
        notes.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 24
        for column in Column.allCases {
            let item = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            item.title = column.title
            item.headerCell.alignment = column == .site ? .left : .right
            item.minWidth = column == .site ? 140 : column.width
            item.width = column.width
            item.resizingMask = column == .site ? .autoresizingMask : []
            table.addTableColumn(item)
        }
        table.allowsColumnReordering = false
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let stack = NSStackView(views: [overview, scroll, notes])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        panel.contentView = stack
        let contentWidth = stack.widthAnchor
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: contentWidth, constant: -32),
            notes.widthAnchor.constraint(equalTo: contentWidth, constant: -32)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        guard loadTask == nil else { return }
        overview.stringValue = String(localized: "Loading reading activity…")
        loadTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try History.summarize() }
            }.value
            loadTask = nil
            switch result {
            case .success(let summary):
                sites = summary.sites
                if let period = summary.period {
                    let start = period.lowerBound.formatted(date: .abbreviated, time: .omitted)
                    let end = period.upperBound.formatted(date: .abbreviated, time: .omitted)
                    overview.stringValue = start == end
                        ? String(localized: "Recorded on \(start)")
                        : String(localized: "Recorded from \(start) to \(end)")
                } else {
                    overview.stringValue = String(localized: "No reading activity recorded yet.")
                }
            case .failure:
                sites = []
                overview.stringValue = String(localized: "Couldn’t load reading activity.")
            }
            table.reloadData()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sites.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, let column = Column(rawValue: identifier.rawValue) else { return nil }
        let site = sites[row]
        let text: String
        switch column {
        case .site: text = site.host
        case .opened: text = site.opened.formatted()
        case .browser: text = site.browser.formatted()
        case .skipped: text = site.skipped.formatted()
        case .depth: text = site.averageDepth?.formatted(.percent.precision(.fractionLength(0))) ?? "—"
        }
        let label = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
            ?? NSTextField(labelWithString: "")
        label.identifier = identifier
        label.stringValue = text
        label.lineBreakMode = .byTruncatingTail
        label.alignment = column == .site ? .left : .right
        label.toolTip = column == .site ? site.host : nil
        return label
    }
}
