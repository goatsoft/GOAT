import Foundation
import Testing

@testable import Herd

@Test func discardedPreparedAttachmentsAreRemoved() throws {
    let name = try #require(AttachmentStore.save(Data("not-an-image".utf8), ext: "test"))
    let url = try #require(AttachmentStore.url(for: name))
    #expect(FileManager.default.fileExists(atPath: url.path))

    AttachmentStore.delete([name])

    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func attachmentNamesCannotEscapeOrFollowSymlinks() throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-attachment-security-\(UUID().uuidString)", isDirectory: true)
    let root = parent.appendingPathComponent("attachments", isDirectory: true)
    let outside = parent.appendingPathComponent("outside.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("outside".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: parent) }

    #expect(AttachmentStore.url(for: "../outside.txt", in: root) == nil)
    #expect(AttachmentStore.url(for: outside.path, in: root) == nil)
    AttachmentStore.delete(["../outside.txt", outside.path], in: root)
    #expect(FileManager.default.fileExists(atPath: outside.path))

    let linkedName = "\(UUID().uuidString).png"
    let linkedURL = root.appendingPathComponent(linkedName)
    try FileManager.default.createSymbolicLink(at: linkedURL, withDestinationURL: outside)
    #expect(AttachmentStore.load(linkedName, in: root) == nil)
    AttachmentStore.delete([linkedName], in: root)
    #expect(FileManager.default.fileExists(atPath: outside.path))
    #expect(FileManager.default.fileExists(atPath: linkedURL.path))
}

@Test func attachmentExtensionsAndReadsAreBounded() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-attachment-bounds-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(AttachmentStore.save(Data(), ext: "../png", in: root) == nil)
    #expect(AttachmentStore.save(Data(), ext: "", in: root) == nil)
    let valid = try #require(AttachmentStore.save(Data("safe".utf8), ext: "png", in: root))
    #expect(AttachmentStore.load(valid, in: root) == Data("safe".utf8))

    let oversizedName = "\(UUID().uuidString).png"
    let oversizedURL = root.appendingPathComponent(oversizedName)
    FileManager.default.createFile(atPath: oversizedURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: oversizedURL)
    try handle.truncate(atOffset: UInt64(AttachmentStore.maximumBytes + 1))
    try handle.close()
    #expect(AttachmentStore.load(oversizedName, in: root) == nil)
}

@Test func textAttachmentsPreserveSourceAndRevalidateStoredMetadata() throws {
    let original = try #require(
        TextAttachment(name: "trail-guide.md", text: "# Goat Trails\n\n```html\n<main>🐐</main>\n```"))
    let encoded = try #require(original.encoded)
    #expect(TextAttachment.decode(encoded) == original)
    #expect(original.promptText.contains(original.text))
    #expect(TextAttachment.isStoredDocument("\(UUID().uuidString).goatdoc"))
    #expect(!TextAttachment.isStoredDocument("\(UUID().uuidString).png"))
    #expect(TextAttachment(name: "../secret.txt", text: "secret") == nil)
    #expect(TextAttachment(name: "fake\nname.txt", text: "secret") == nil)
    #expect(TextAttachment(name: "binary.txt", text: "abc\0def") == nil)
    #expect(
        TextAttachment(name: "large.txt", text: String(repeating: "x", count: TextAttachment.maximumBytes + 1)) == nil)
    let invalid = Data(#"{"name":"../outside.txt","text":"data"}"#.utf8)
    #expect(TextAttachment.decode(invalid) == nil)
}

@Test func textAttachmentCopiesRoundTripThroughTheExistingStore() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("goat-document-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let document = try #require(TextAttachment(name: "goats.swift", text: "let goats = 7\n"))
    let encoded = try #require(document.encoded)
    let name = try #require(
        AttachmentStore.save(encoded, ext: TextAttachment.storedExtension, in: root))
    let data = try #require(AttachmentStore.load(name, in: root))
    #expect(TextAttachment.decode(data) == document)
    AttachmentStore.delete([name], in: root)
    #expect(AttachmentStore.load(name, in: root) == nil)
}
