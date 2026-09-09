import Foundation

/// Stores attachment files referenced by message rows (docs/reference/STORAGE.md).
public enum AttachmentStore {
    public static let maximumBytes = 25 * 1_024 * 1_024

    private static var dir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GOAT/Attachments", isDirectory: true)
    }

    /// Writes bounded data and returns the stored filename, or nil for an invalid extension/write.
    public static func save(_ data: Data, ext: String = "png") -> String? {
        save(data, ext: ext, in: dir)
    }

    static func save(_ data: Data, ext: String = "png", in root: URL) -> String? {
        guard data.count <= maximumBytes, validExtension(ext) else { return nil }
        let name = UUID().uuidString + "." + ext
        guard let url = url(for: name, in: root) else { return nil }
        do {
            try LocalFileStore.write(data, to: url)
            return name
        } catch {
            return nil
        }
    }

    public static func url(for name: String) -> URL? {
        url(for: name, in: dir)
    }

    static func url(for name: String, in root: URL) -> URL? {
        guard validStoredName(name) else { return nil }
        let url = root.appendingPathComponent(name)
        guard (try? LocalFileStore.requireContained(url, in: root)) != nil else { return nil }
        return url
    }

    public static func load(_ name: String) -> Data? {
        load(name, in: dir)
    }

    static func load(_ name: String, in root: URL) -> Data? {
        guard let url = url(for: name, in: root) else { return nil }
        return try? LocalFileStore.boundedDataIfPresent(at: url, maximumBytes: maximumBytes)
    }

    /// Remove files prepared for a turn which lost ownership. Invalid, escaped, and symlinked
    /// names are ignored, so tampered DB rows cannot delete outside the attachment root.
    public static func delete(_ names: [String]) {
        delete(names, in: dir)
    }

    static func delete(_ names: [String], in root: URL) {
        for name in names {
            guard let url = url(for: name, in: root) else { continue }
            try? LocalFileStore.removeItem(at: url)
        }
    }

    private static func validStoredName(_ name: String) -> Bool {
        guard (try? LocalFileStore.validateComponent(name, label: "attachment filename")) != nil else {
            return false
        }
        let value = name as NSString
        let ext = value.pathExtension
        let stem = value.deletingPathExtension
        guard validExtension(ext), let id = UUID(uuidString: stem), id.uuidString == stem else {
            return false
        }
        return name == "\(stem).\(ext)"
    }

    private static func validExtension(_ ext: String) -> Bool {
        !ext.isEmpty && ext.count <= 10
            && ext.unicodeScalars.allSatisfy { scalar in
                let value = scalar.value
                return (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
            }
    }
}
