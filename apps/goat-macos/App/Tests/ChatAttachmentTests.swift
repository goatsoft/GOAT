import AppKit
import Foundation
import Herd
import Testing

@testable import GOAT

@Test @MainActor func composerPasteboardPrefersFinderFilesAndLeavesTextAsText() throws {
    let pasteboard = NSPasteboard(name: .init("GOATAttachmentTest-\(UUID())"))
    defer { pasteboard.releaseGlobally() }
    let url = URL(fileURLWithPath: "/tmp/goat-trails.md")
    pasteboard.writeObjects([url as NSURL])
    #expect(ComposerPasteboard.fileURLs(from: pasteboard) == [url])
    pasteboard.clearContents()
    pasteboard.setString("https://example.com/goat.png", forType: .string)
    #expect(ComposerPasteboard.fileURLs(from: pasteboard).isEmpty)
    #expect(!ComposerPasteboard.hasImage(pasteboard))
    pasteboard.clearContents()
    let bytes = Data([1, 2, 3])
    pasteboard.setData(bytes, forType: .png)
    #expect(ComposerPasteboard.hasImage(pasteboard))
    #expect(ComposerPasteboard.imageData(from: pasteboard) == bytes)
}

@Test func fileImportReportsUnsupportedFilesAndCopiesText() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("goat-import-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let text = root.appendingPathComponent("trail.md")
    let binary = root.appendingPathComponent("archive.zip")
    let invalid = root.appendingPathComponent("binary.txt")
    try Data("# A goat trail\n".utf8).write(to: text)
    try Data([0, 1, 2, 3]).write(to: binary)
    try Data([0xff, 0xfe, 0]).write(to: invalid)
    let result = await ChatAttachmentImporter.shared.importFiles([text, binary, invalid])
    #expect(result.documents.count == 1)
    #expect(result.documents.first?.name == "trail.md")
    #expect(result.documents.first?.text == "# A goat trail\n")
    #expect(result.images.isEmpty)
    #expect(result.failures.count == 2)
}
