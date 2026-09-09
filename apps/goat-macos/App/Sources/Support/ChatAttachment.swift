import CoreGraphics
import Foundation
import Herd
import UniformTypeIdentifiers

struct PendingAttachment: Identifiable {
    let id = UUID()
    let data: Data
    let preview: CGImage?
    let name: String
    let document: TextAttachment?
    var imageData: Data? { document == nil ? data : nil }
    var fileExtension: String { (name as NSString).pathExtension.uppercased() }

    init(data: Data, preview: CGImage, name: String = "Image.png") {
        self.data = data
        self.preview = preview
        self.name = name
        document = nil
    }

    init(document: TextAttachment) {
        data = Data()
        preview = nil
        name = document.name
        self.document = document
    }
}

enum ChatAttachmentTypes {
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "jsonl", "yaml", "yml", "toml",
        "xml", "html", "htm", "svg", "css", "scss", "js", "jsx", "ts", "tsx", "vue",
        "svelte", "swift", "py", "rs", "go", "c", "h", "cpp", "hpp", "java", "kt",
        "rb", "php", "sh", "bash", "zsh", "sql", "log", "ini", "cfg", "conf", "mmd",
    ]
    static var allowedContentTypes: [UTType] {
        [.image, .text, .sourceCode, .json, .xml]
            + textExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }

    static func isText(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return textExtensions.contains(ext)
            || ["readme", "license", "makefile", "dockerfile", ".gitignore"].contains(
                url.lastPathComponent.lowercased())
            || UTType(filenameExtension: ext)?.conforms(to: .text) == true
    }
}

/// File reads, UTF-8 validation and image decoding stay off the UI actor.
actor ChatAttachmentImporter {
    static let shared = ChatAttachmentImporter()

    struct Result: Sendable {
        var images: [(name: String, image: PreparedImage)] = []
        var documents: [TextAttachment] = []
        var failures: [String] = []
    }

    func importFiles(_ urls: [URL]) -> Result {
        var result = Result()
        for url in urls {
            guard !Task.isCancelled else { break }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                guard url.isFileURL else { throw ImportError.unsupported }
                let textFile = ChatAttachmentTypes.isText(url)
                let limit = textFile ? TextAttachment.maximumBytes : AttachmentStore.maximumBytes
                guard let data = try LocalFileStore.boundedDataIfPresent(at: url, maximumBytes: limit) else {
                    throw ImportError.unreadable
                }
                if textFile {
                    guard let text = String(data: data, encoding: .utf8),
                        let document = TextAttachment(name: url.lastPathComponent, text: text)
                    else { throw ImportError.invalidText }
                    result.documents.append(document)
                } else if let image = ImageProcessing.prepare(data) {
                    result.images.append((url.lastPathComponent, image))
                } else {
                    throw ImportError.unsupported
                }
            } catch {
                result.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    func storedDocument(_ path: String) -> TextAttachment? {
        guard TextAttachment.isStoredDocument(path), let data = AttachmentStore.load(path) else { return nil }
        return TextAttachment.decode(data)
    }

    enum ImportError: LocalizedError {
        case unsupported, unreadable, invalidText
        var errorDescription: String? {
            switch self {
            case .unsupported: "Choose an image or a supported text/code file."
            case .unreadable: "The file could not be read."
            case .invalidText: "Text files must be UTF-8, without binary content, and at most 512 KB."
            }
        }
    }
}
