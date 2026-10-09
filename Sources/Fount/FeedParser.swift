import Foundation

struct ParsedFeed {
    var title = ""
    var siteURL: String?
    var items: [ParsedItem] = []
}

struct ParsedItem {
    var id = ""
    var title = ""
    var link = ""
    var date: Date?
    var updated: Date?
    /// A thumbnail the feed itself provides; article pages are never fetched for one.
    var image: String?
}

/// Parses RSS 2.0, RSS 1.0 (RDF) and Atom. Only what the reader shows is kept:
/// the article body is never parsed, because articles are shown as web pages.
final class FeedParser: NSObject, XMLParserDelegate {
    private static let mediaRSS = "http://search.yahoo.com/mrss/"
    private static let hatena = "http://www.hatena.ne.jp/info/xmlns#"

    private var stack: [String] = []
    private var text = ""
    private var root: String?
    private var feed = ParsedFeed()
    private var item: ParsedItem?
    private var base: URL?

    /// Returns nil when `data` isn't a feed (for example an HTML page).
    /// Relative links, which Atom allows, are resolved against `base`.
    static func parse(_ data: Data, base: URL? = nil) -> ParsedFeed? {
        let delegate = FeedParser()
        delegate.base = base
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        guard let root = delegate.root, ["rss", "feed", "RDF"].contains(root) else { return nil }
        // A feed cut off by a parse error still yields the items read so far.
        return delegate.feed
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if root == nil { root = name }
        stack.append(name)
        text = ""
        switch name {
        case "item", "entry":
            item = ParsedItem(id: attributes["about"] ?? "")
        case "link":
            if item != nil, attributes["rel"] == "enclosure", let href = attributes["href"],
               Self.isImage(href, type: attributes["type"]) {
                setImage(href)
            }
            // Atom links carry the URL in href; take the page link, not self/enclosure/replies.
            guard let href = attributes["href"], attributes["rel"] == nil || attributes["rel"] == "alternate" else { break }
            if item != nil {
                if item!.link.isEmpty { item!.link = href }
            } else if parent == "feed", feed.siteURL == nil {
                feed.siteURL = href
            }
        case "enclosure" where item != nil:
            if let url = attributes["url"], Self.isImage(url, type: attributes["type"]) { setImage(url) }
        case "thumbnail" where item != nil && namespaceURI == Self.mediaRSS:
            if let url = attributes["url"] { setImage(url) }
        case "content" where item != nil && namespaceURI == Self.mediaRSS:
            if let url = attributes["url"], attributes["medium"] == "image" || Self.isImage(url, type: attributes["type"]) {
                setImage(url)
            }
        default:
            break
        }
    }

    /// Keeps the first image an item names.
    private func setImage(_ url: String) {
        if item?.image == nil, !url.isEmpty { item?.image = url }
    }

    /// Zenn's enclosures carry `type="false"`, so a type that isn't a MIME type falls back to the extension.
    private static func isImage(_ url: String, type: String?) -> Bool {
        if let type, type.contains("/") { return type.lowercased().hasPrefix("image/") }
        let ext = URL(string: url)?.pathExtension.lowercased() ?? ""
        return ["jpg", "jpeg", "png", "gif", "webp", "avif"].contains(ext)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        text += String(decoding: block, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "item" || name == "entry", var done = item {
            done.link = resolve(done.link)
            done.image = done.image.map(resolve)
            if done.id.isEmpty { done.id = done.link }
            if !done.link.isEmpty { feed.items.append(done) }
            item = nil
        } else if item != nil, parent == "item" || parent == "entry" {
            switch name {
            case "title": item!.title = value
            case "link" where item!.link.isEmpty: item!.link = value
            case "guid", "id": item!.id = value
            case "pubDate", "published", "date": item!.date = Self.date(value)
            case "updated": item!.updated = Self.date(value)
            case "imageurl" where namespaceURI == Self.hatena: setImage(value)
            default: break
            }
        } else if parent == "channel" || parent == "feed" {
            switch name {
            case "title": feed.title = value
            case "link" where feed.siteURL == nil && !value.isEmpty: feed.siteURL = value
            default: break
            }
        }
        stack.removeLast()
        text = ""
    }

    private func resolve(_ link: String) -> String {
        guard let base, !link.isEmpty, let url = URL(string: link, relativeTo: base) else { return link }
        return url.absoluteString
    }

    private var parent: String? { stack.count >= 2 ? stack[stack.count - 2] : nil }

    private static let iso: [ISO8601DateFormatter] = {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [plain, fractional]
    }()

    private static let rfc822: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm zzz", "EEE, dd MMM yyyy HH:mm Z",
    ].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = $0
        return f
    }

    static func date(_ s: String) -> Date? {
        for f in iso { if let d = f.date(from: s) { return d } }
        for f in rfc822 { if let d = f.date(from: s) { return d } }
        return nil
    }
}

/// Reads subscriptions from an OPML file, such as one exported from NetNewsWire.
final class OPMLParser: NSObject, XMLParserDelegate {
    private var feeds: [(url: String, title: String)] = []

    static func parse(_ data: Data) -> [(url: String, title: String)] {
        let delegate = OPMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.feeds
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        guard name == "outline", let url = attributes["xmlUrl"], !url.isEmpty else { return }
        feeds.append((url, attributes["title"] ?? attributes["text"] ?? url))
    }
}

enum FeedError: LocalizedError {
    case http(Int)
    case notFound

    var errorDescription: String? {
        switch self {
        case .http(let code): return String(localized: "The server returned HTTP \(code).")
        case .notFound: return String(localized: "No feed was found at this address.")
        }
    }
}

enum Fetcher {
    static func fetch(_ url: URL) async throws -> ParsedFeed {
        let (data, final) = try await load(url)
        guard let feed = FeedParser.parse(data, base: final) else { throw FeedError.notFound }
        return feed
    }

    /// Accepts a feed URL or a web page that links to its feed, and returns the feed's URL.
    static func discover(_ url: URL) async throws -> (URL, ParsedFeed) {
        let (data, final) = try await load(url)
        if let feed = FeedParser.parse(data, base: final) { return (final, feed) }
        let html = String(decoding: data, as: UTF8.self)
        for href in feedLinks(in: html) {
            guard let link = URL(string: href, relativeTo: final)?.absoluteURL else { continue }
            if let feed = try? await fetch(link) { return (link, feed) }
        }
        throw FeedError.notFound
    }

    /// Whether `error` suggests the feed is gone, rather than briefly unreachable.
    static func isPermanent(_ error: Error) -> Bool {
        switch error {
        case FeedError.notFound: return true
        case FeedError.http(let code): return code == 404 || code == 410
        case let error as URLError:
            return [.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .httpTooManyRedirects,
                    .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                    .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid].contains(error.code)
        default: return false
        }
    }

    private static func load(_ url: URL) async throws -> (Data, URL) {
        let request = URLRequest(url: url, timeoutInterval: 30)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError.http(http.statusCode)
        }
        return (data, response.url ?? url)
    }

    /// `href`s of `<link rel="alternate" type="application/rss+xml">` and Atom equivalents.
    static func feedLinks(in html: String) -> [String] {
        let tag = try! NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive)
        let range = NSRange(html.startIndex..., in: html)
        return tag.matches(in: html, range: range).compactMap { match in
            let tag = String(html[Range(match.range, in: html)!])
            guard let type = attribute("type", in: tag)?.lowercased(),
                  type.contains("rss+xml") || type.contains("atom+xml") || type.contains("rdf+xml"),
                  let href = attribute("href", in: tag) else { return nil }
            return href.replacingOccurrences(of: "&amp;", with: "&")
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for i in 1...2 where m.range(at: i).location != NSNotFound {
            return String(tag[Range(m.range(at: i), in: tag)!])
        }
        return nil
    }
}
