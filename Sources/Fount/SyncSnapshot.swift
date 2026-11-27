import Foundation

struct SyncSnapshot: Encodable {
    struct Activity: Encodable {
        struct Site: Encodable {
            let host: String
            let opened: Int
            let browser: Int
            let skipped: Int
            let averageDepth: Double?
            let depthCount: Int
        }

        let startedAt: Date?
        let endedAt: Date?
        let sites: [Site]

        init(_ summary: History.Summary) {
            startedAt = summary.period?.lowerBound
            endedAt = summary.period?.upperBound
            sites = summary.sites.map {
                Site(host: $0.host, opened: $0.opened, browser: $0.browser, skipped: $0.skipped,
                     averageDepth: $0.averageDepth, depthCount: $0.depthCount)
            }
        }
    }

    let schemaVersion = 1
    let exportedAt = Date()
    let feeds: [Feed]
    let articles: [Article]
    let activity: Activity

    static func encode(feeds: [Feed], articles: [Article]) throws -> String {
        let snapshot = SyncSnapshot(feeds: feeds, articles: articles, activity: Activity(try History.summarize()))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(snapshot), as: UTF8.self)
    }
}
