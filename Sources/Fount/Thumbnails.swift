import Foundation
import ImageIO

/// Article thumbnails, downloaded and shrunk off the main thread and kept in memory only.
@MainActor
enum Thumbnails {
    /// Shortest side in pixels: the 56-point square thumbnail on a 2x display.
    private nonisolated static let pixels = 112

    /// Larger responses are dropped before they are buffered: the URLs come from feeds.
    private nonisolated static let maxBytes = 10 << 20

    private static let cache = NSCache<NSString, CGImage>()
    private static var failed: Set<String> = []
    private static var loading: [String: Task<CGImage?, Never>] = [:]

    static func cached(_ url: String) -> CGImage? { cache.object(forKey: url as NSString) }

    static func image(_ url: String) async -> CGImage? {
        if let image = cached(url) { return image }
        if failed.contains(url) { return nil }
        if let task = loading[url] { return await task.value }
        let task = Task { await load(url) }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image { cache.setObject(image, forKey: url as NSString) } else { failed.insert(url) }
        return image
    }

    private nonisolated static func load(_ string: String) async -> CGImage? {
        guard let url = URL(string: string),
              let data = await download(url),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // The thumbnail is cropped to a square, so size it by its shorter side.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? pixels
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? pixels
        let longest = pixels * max(width, height) / max(min(width, height), 1)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longest, pixels * 4),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func download(_ url: URL) async -> Data? {
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: URLRequest(url: url, timeoutInterval: 30)),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              response.expectedContentLength <= maxBytes else { return nil }
        var data = Data()
        data.reserveCapacity(max(Int(response.expectedContentLength), 0))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes {
                    bytes.task.cancel()
                    return nil
                }
            }
        } catch {
            return nil
        }
        return data
    }
}
