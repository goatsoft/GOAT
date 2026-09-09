import JUDAS
import MarkdownUI
import SwiftUI

/// Assistant Markdown is untrusted model output. Rendering an image URL with MarkdownUI's default
/// provider would issue a network request without a user gesture, leaking the user's IP address and
/// any attacker-controlled query data. Attachments use GOAT's explicit local image pipeline instead.
struct BlockedMarkdownImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        Label("External image blocked", systemImage: "photo.badge.exclamationmark")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
            .task(id: url) { Judas.shared.record(.preview, .denied, url: url) }
    }
}

struct BlockedMarkdownInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label _: String) async throws -> Image {
        Judas.shared.record(.preview, .denied, url: url)
        throw BlockedMarkdownImageError()
    }
}

private struct BlockedMarkdownImageError: LocalizedError {
    var errorDescription: String? { "External Markdown images are blocked." }
}
