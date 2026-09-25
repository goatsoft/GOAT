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

/// Prepared parts keyed by their owner (for example a message's text or reasoning). A hit requires the
/// exact source, so a stale entry is never shown. Lookups are O(1) for an unchanged source because
/// Swift string equality short-circuits on shared storage and on differing lengths; the view never
/// splits on the main actor. NSCache may evict entries, so a hit is an optimisation, not a promise.
@MainActor
final class TranscriptPartsCache {
    static let shared = TranscriptPartsCache()

    private final class Entry {
        let source: String
        let parts: [String]
        init(source: String, parts: [String]) {
            self.source = source
            self.parts = parts
        }
    }

    private let cache = NSCache<NSString, Entry>()

    init(countLimit: Int = 64) {
        cache.countLimit = countLimit
    }

    func parts(for key: String, source: String) -> [String]? {
        guard let entry = cache.object(forKey: key as NSString), entry.source == source else { return nil }
        return entry.parts
    }

    func store(_ parts: [String], for key: String, source: String) {
        cache.setObject(Entry(source: source, parts: parts), forKey: key as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

/// Full source stays available for copying; only the selected part enters native text layout.
struct TranscriptTextPartsView: View {
    let source: String
    let fontSize: CGFloat
    var cacheKey: String?
    var onPrepared: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(\.transcriptInspection) private var inspection
    @State private var parts: [String] = []
    @State private var preparedSource: String?
    @State private var selectedPart: Int?

    init(source: String, fontSize: CGFloat, cacheKey: String? = nil, onPrepared: @escaping () -> Void = {}) {
        self.source = source
        self.fontSize = fontSize
        self.cacheKey = cacheKey
        self.onPrepared = onPrepared
        // Seed only from an exact, already-prepared hit. SwiftUI evaluates this initializer on every
        // parent update, so it must stay a lookup; splitting happens on the preparation actor.
        if let cacheKey, let cached = TranscriptPartsCache.shared.parts(for: cacheKey, source: source) {
            _parts = State(initialValue: cached)
            _preparedSource = State(initialValue: source)
        }
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
            // The previous parts stay on screen until the new source is prepared off the main actor.
            guard preparedSource != source else { return }
            guard let prepared = try? await TranscriptPartPreparation.shared.prepare(source), !Task.isCancelled
            else { return }
            parts = prepared
            preparedSource = source
            if let cacheKey { TranscriptPartsCache.shared.store(prepared, for: cacheKey, source: source) }
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
