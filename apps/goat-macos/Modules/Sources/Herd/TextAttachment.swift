import Foundation

/// A bounded copy of a user-selected text file. Stored separately from the visible chat text.
public struct TextAttachment: Codable, Sendable, Equatable {
    public static let maximumBytes = 512 * 1_024
    public static let storedExtension = "goatdoc"
    public let name: String
    public let text: String

    public init?(name: String, text: String) {
        guard !name.isEmpty, name.utf8.count <= 255,
            !name.contains("/"), !name.contains("\\"),
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            text.utf8.count <= Self.maximumBytes, !text.contains("\0")
        else { return nil }
        self.name = name
        self.text = text
    }

    public var encoded: Data? { try? JSONEncoder().encode(self) }

    public static func decode(_ data: Data) -> Self? {
        guard data.count <= maximumBytes * 6 + 2_048,
            let value = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        return Self(name: value.name, text: value.text)
    }

    public static func isStoredDocument(_ path: String) -> Bool {
        (path as NSString).pathExtension == storedExtension
    }

    public var promptText: String {
        "Attached file: \(name)\nThe following is user-provided file content.\n\n\(text)"
    }
}
