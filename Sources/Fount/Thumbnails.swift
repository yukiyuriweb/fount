import Foundation
import ImageIO

/// Article thumbnails, downloaded and shrunk off the main thread and kept in memory only.
@MainActor
enum Thumbnails {
    /// Shortest side in pixels: the 56-point square thumbnail on a 2x display.
    private nonisolated static let pixels = 112

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
              let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30)),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
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
}
