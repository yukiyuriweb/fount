import Foundation

struct Feed: Codable {
    var url: String
    var title: String
    var siteURL: String?
}

struct Article: Codable {
    var id: String
    var feed: String
    var title: String
    var link: String
    var date: Date
    var read: Bool

    var key: String { feed + "\n" + id }
}

/// Subscriptions and articles, kept in one JSON file under Application Support.
@MainActor
final class Store {
    /// Articles kept per feed beyond those still listed in the feed itself.
    private static let keepPerFeed = 200

    private(set) var feeds: [Feed] = []
    /// Newest first.
    private(set) var articles: [Article] = []
    private(set) var unreadCounts: [String: Int] = [:]
    private(set) var totalUnread = 0
    /// Last refresh error per feed URL.
    private(set) var errors: [String: String] = [:]
    private(set) var isRefreshing = false
    var onChange: (() -> Void)?

    private let file: URL
    private var pendingSave: DispatchWorkItem?

    private struct State: Codable {
        var feeds: [Feed]
        var articles: [Article]
    }

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fount")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("state.json")
        if let data = try? Data(contentsOf: file), let state = try? JSONDecoder().decode(State.self, from: data) {
            feeds = state.feeds
            articles = state.articles
        }
        recount()
    }

    func feed(_ url: String) -> Feed? { feeds.first { $0.url == url } }

    // MARK: Changes

    /// Returns false if the feed is already subscribed.
    @discardableResult
    func add(_ url: String, _ parsed: ParsedFeed) -> Bool {
        guard feed(url) == nil else { return false }
        feeds.append(Feed(url: url, title: parsed.title.isEmpty ? url : parsed.title, siteURL: parsed.siteURL))
        merge(parsed, into: url)
        changed()
        return true
    }

    /// Adds feeds without fetching them; the next refresh fills them in.
    func importFeeds(_ list: [(url: String, title: String)]) {
        for entry in list where feed(entry.url) == nil {
            feeds.append(Feed(url: entry.url, title: entry.title))
        }
        changed()
    }

    func remove(_ url: String) {
        feeds.removeAll { $0.url == url }
        articles.removeAll { $0.feed == url }
        errors[url] = nil
        changed()
    }

    func setRead(_ key: String, _ read: Bool) {
        guard let i = articles.firstIndex(where: { $0.key == key }), articles[i].read != read else { return }
        articles[i].read = read
        changed()
    }

    /// Marks every article read, or only those of `feed`.
    func markAllRead(feed: String?) {
        for i in articles.indices where feed == nil || articles[i].feed == feed {
            articles[i].read = true
        }
        changed()
    }

    // MARK: Refresh

    func refresh() {
        guard !isRefreshing, !feeds.isEmpty else { return }
        isRefreshing = true
        onChange?()
        let urls = feeds.map(\.url)
        Task {
            await withTaskGroup(of: (String, Result<ParsedFeed, Error>).self) { group in
                for url in urls {
                    group.addTask {
                        do {
                            guard let u = URL(string: url) else { throw FeedError.notFound }
                            return (url, .success(try await Fetcher.fetch(u)))
                        } catch {
                            return (url, .failure(error))
                        }
                    }
                }
                for await (url, result) in group {
                    guard let i = feeds.firstIndex(where: { $0.url == url }) else { continue }  // removed meanwhile
                    switch result {
                    case .success(let parsed):
                        if !parsed.title.isEmpty { feeds[i].title = parsed.title }
                        feeds[i].siteURL = parsed.siteURL ?? feeds[i].siteURL
                        errors[url] = nil
                        merge(parsed, into: url)
                    case .failure(let error):
                        errors[url] = error.localizedDescription
                    }
                    changed()
                }
            }
            isRefreshing = false
            onChange?()
        }
    }

    private func merge(_ parsed: ParsedFeed, into url: String) {
        let now = Date()
        var index: [String: Int] = [:]
        for (i, a) in articles.enumerated() where a.feed == url { index[a.id] = i }
        for item in parsed.items {
            let date = item.date ?? item.updated
            if let i = index[item.id] {
                articles[i].title = item.title
                articles[i].link = item.link
                if let date { articles[i].date = date }
            } else {
                index[item.id] = articles.count
                articles.append(Article(id: item.id, feed: url, title: item.title, link: item.link,
                                        date: date ?? now, read: false))
            }
        }
        articles.sort { $0.date > $1.date }
        // Drop the oldest articles, but never one the feed still lists: it would come back as unread.
        let current = Set(parsed.items.map(\.id))
        var kept = 0
        articles.removeAll { a in
            guard a.feed == url, !current.contains(a.id) else { return false }
            kept += 1
            return kept > Self.keepPerFeed
        }
    }

    // MARK: Saving

    private func changed() {
        recount()
        onChange?()
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func recount() {
        unreadCounts = [:]
        for a in articles where !a.read { unreadCounts[a.feed, default: 0] += 1 }
        totalUnread = unreadCounts.values.reduce(0, +)
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        if let data = try? JSONEncoder().encode(State(feeds: feeds, articles: articles)) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
