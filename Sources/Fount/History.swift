import Foundation

/// An append-only log of what the reader did with articles, kept for suggesting articles later.
/// It lives apart from `state.json`, so it outlasts the pruning of old articles and unsubscribing.
/// Each line of `history.jsonl` is one `Event`, with enough of the article to stand on its own.
enum History {
    enum Kind: String, Codable {
        /// Picked in the list, by click or j/k; the top article opened by switching feeds doesn't count.
        case opened
        /// Opened in the browser (o, Return, or the menu).
        case browser
        /// Scrolled past the top of the list while unread, without being opened.
        case skipped
        /// Left after being shown, with `depth` set to how far down its page the reader got (0–1). Written for
        /// every article shown, including the top article that switching feeds opens, which has no `opened`.
        case depth
    }

    private struct Event: Codable {
        var time: Date
        var kind: Kind
        var feed: String
        var feedTitle: String?
        var id: String
        var link: String
        var title: String
        var excerpt: String?
        var date: Date
        var depth: Double?
    }

    private static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Fount/history.jsonl")

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static func record(_ kind: Kind, _ articles: [Article], depth: Double? = nil, feedTitle: (String) -> String?) {
        guard !articles.isEmpty else { return }
        let now = Date()
        var data = Data()
        for a in articles {
            let event = Event(time: now, kind: kind, feed: a.feed, feedTitle: feedTitle(a.feed), id: a.id,
                              link: a.link, title: a.title, excerpt: a.excerpt, date: a.date,
                              depth: depth.map { ($0 * 100).rounded() / 100 })
            guard let line = try? encoder.encode(event) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }
}
