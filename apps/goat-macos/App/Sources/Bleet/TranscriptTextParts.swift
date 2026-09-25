import Caprine
import Foundation
import SwiftUI

/// Split at Unicode scalar boundaries so even a pathological combining sequence is bounded.
/// Joining the parts recovers every original scalar, including whitespace and fence markers.
enum TranscriptTextParts {
    static let maximumBytes = 8 * 1_024

    static func split(_ source: String, maximumBytes: Int = maximumBytes) throws -> [String] {
        let limit = max(4, maximumBytes)
        var parts: [String] = []
        var part = String.UnicodeScalarView()
        var bytes = 0
        for scalar in source.unicodeScalars {
            if bytes + scalar.utf8.count > limit {
                try Task.checkCancellation()
                parts.append(String(part))
                part = String.UnicodeScalarView()
                bytes = 0
            }
            part.append(scalar)
            bytes += scalar.utf8.count
        }
        if !part.isEmpty || parts.isEmpty { parts.append(String(part)) }
        return parts
    }
}

private actor TranscriptPartPreparation {
    static let shared = TranscriptPartPreparation()
    func prepare(_ source: String) throws -> [String] {
        try Task.checkCancellation()
        return try TranscriptTextParts.split(source)
    }
}

/// Full source stays available for copying; only the selected part enters native text layout.
struct TranscriptTextPartsView: View {
    let source: String
    let fontSize: CGFloat
    var onPrepared: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(\.transcriptInspection) private var inspection
    @State private var parts: [String] = []
    @State private var selectedPart: Int?

    init(source: String, fontSize: CGFloat, onPrepared: @escaping () -> Void = {}) {
        self.source = source
        self.fontSize = fontSize
        self.onPrepared = onPrepared
        let initialParts = (try? TranscriptTextParts.split(source)) ?? []
        _parts = State(initialValue: initialParts)
    }

    private var index: Int { min(selectedPart ?? max(0, parts.count - 1), max(0, parts.count - 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: Caprine.Activity.spacing) {
            if parts.isEmpty {
                Text("Preparing text…").foregroundStyle(.secondary)
            } else {
                Text(verbatim: parts[index])
                    .font(Font(ReadingFonts.nsFont(model.effectiveChatFontID, size: fontSize, role: .chat)))
                    .textSelection(.enabled)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Caprine.Activity.spacing) { controls }
                    VStack(alignment: .leading, spacing: Caprine.Activity.spacing) { controls }
                }
                .font(Caprine.Activity.font)
            }
        }
        .task(id: source) {
            if parts.isEmpty {
                guard let prepared = try? await TranscriptPartPreparation.shared.prepare(source), !Task.isCancelled
                else {
                    return
                }
                parts = prepared
            }
            onPrepared()
        }
    }

    @ViewBuilder private var controls: some View {
        Button("Earlier text") {
            inspection.perform()
            selectedPart = max(0, index - 1)
        }
        .disabled(index == 0)
        Text("Part \(index + 1) of \(parts.count)")
            .foregroundStyle(.secondary)
            .accessibilityLabel("Text part \(index + 1) of \(parts.count)")
        Button("Later text") {
            inspection.perform()
            selectedPart = min(parts.count - 1, index + 1)
        }
        .disabled(index >= parts.count - 1)
        if selectedPart != nil {
            Button("Latest text") { selectedPart = nil }
        }
        CopyButton(text: source)
            .help("Copy the full text")
    }
}
