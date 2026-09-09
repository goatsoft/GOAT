import Caprine
import CoreGraphics
import Foundation
import Herd
import Hoofprint
import ImageIO

struct PreparedImage: Sendable {
    let pngData: Data
    let preview: CGImage
}

/// Actor-confined LRU for immutable decoded attachment thumbnails. Cost is the actual bitmap row
/// storage, so scrolling cannot retain an unbounded number of decoded images.
struct DecodedImageCache {
    struct Snapshot: Sendable, Equatable {
        let entryCount: Int
        let byteCost: Int
    }

    private struct Entry {
        let image: CGImage
        let byteCost: Int
        var access: UInt64
    }

    private let maximumEntries: Int
    private let maximumBytes: Int
    private var entries: [String: Entry] = [:]
    private var byteCost = 0
    private var access: UInt64 = 0

    init(maximumEntries: Int = 64, maximumBytes: Int = 64 * 1_024 * 1_024) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(1, maximumBytes)
    }

    mutating func image(for key: String) -> CGImage? {
        guard var entry = entries[key] else { return nil }
        access &+= 1
        entry.access = access
        entries[key] = entry
        return entry.image
    }

    mutating func insert(_ image: CGImage, for key: String) {
        let size = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !size.overflow, size.partialValue <= maximumBytes else { return }
        if let replaced = entries.removeValue(forKey: key) {
            byteCost -= replaced.byteCost
        }
        access &+= 1
        entries[key] = Entry(image: image, byteCost: size.partialValue, access: access)
        byteCost += size.partialValue
        while entries.count > maximumEntries || byteCost > maximumBytes {
            guard let victim = entries.min(by: { $0.value.access < $1.value.access }) else {
                break
            }
            byteCost -= victim.value.byteCost
            entries.removeValue(forKey: victim.key)
        }
    }

    mutating func removeAll() {
        entries.removeAll()
        byteCost = 0
    }

    func snapshot() -> Snapshot {
        Snapshot(entryCount: entries.count, byteCost: byteCost)
    }
}

enum ImageProcessing {
    /// Downscale any readable image to a PNG capped at `maxDimension` px on the long side.
    /// Returns nil for non-image data, which conveniently filters junk drops.
    static func prepare(_ data: Data, maxDimension: CGFloat = 1024) -> PreparedImage? {
        RenderSignposts.measure("ImageDecode") {
            guard let preview = thumbnail(from: data, maxDimension: maxDimension),
                let pngData = pngData(from: preview)
            else { return nil }
            return PreparedImage(pngData: pngData, preview: preview)
        }
    }

    static func thumbnail(from data: Data, maxDimension: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let thumb = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary)
        else { return nil }
        return thumb
    }

    private static func pngData(from image: CGImage) -> Data? {
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// Owns blocking image file reads and ImageIO work away from the main actor.
actor ImageFileWorker {
    static let shared = ImageFileWorker()
    private var attachmentCache = DecodedImageCache()

    func clearCache() { attachmentCache.removeAll() }

    func prepare(_ data: Data, maxDimension: CGFloat = 1024) -> PreparedImage? {
        guard !Task.isCancelled, data.count <= AttachmentStore.maximumBytes else { return nil }
        let image = ImageProcessing.prepare(data, maxDimension: maxDimension)
        guard !Task.isCancelled else { return nil }
        return image
    }

    func importImages(at urls: [URL], maxDimension: CGFloat = 1024) -> [PreparedImage] {
        var images: [PreparedImage] = []
        images.reserveCapacity(urls.count)
        for url in urls {
            guard !Task.isCancelled else { break }
            guard let data = read(url),
                let image = ImageProcessing.prepare(data, maxDimension: maxDimension)
            else { continue }
            images.append(image)
        }
        return images
    }

    func storedAttachment(named name: String, maxDimension: CGFloat = 192) -> CGImage? {
        let key = "\(name):\(Int(maxDimension.rounded()))"
        if let cached = attachmentCache.image(for: key) { return cached }
        guard !Task.isCancelled, let data = AttachmentStore.load(name) else { return nil }
        let image = RenderSignposts.measure("ImageDecode") {
            ImageProcessing.thumbnail(from: data, maxDimension: maxDimension)
        }
        guard !Task.isCancelled else { return nil }
        if let image { attachmentCache.insert(image, for: key) }
        return image
    }

    func themePreview(for spec: ThemeSpec, maxDimension: CGFloat = 1200) -> CGImage? {
        guard !Task.isCancelled,
            let url = ThemeStore.previewURL(for: spec),
            let data = read(url)
        else { return nil }
        let image = ImageProcessing.thumbnail(from: data, maxDimension: maxDimension)
        guard !Task.isCancelled else { return nil }
        return image
    }

    private func read(_ url: URL) -> Data? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        return try? LocalFileStore.boundedDataIfPresent(
            at: url, maximumBytes: AttachmentStore.maximumBytes)
    }
}
