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

/// Prepared parts keyed by their owner (for example a message's text or reasoning), retained under a
/// deterministic byte budget. A hit requires the exact source, so a stale entry is never shown; Swift
/// string equality short-circuits on shared storage and on differing lengths. The view never splits on
/// the main actor and keeps its own prepared parts, so a source this cache declines still renders.
///
/// Cost is the retained UTF-8 bytes: the source plus its parts, which copy the same bytes. Sources
/// whose cost exceeds `maximumEntryCost` are never retained. Least recently used entries are evicted
/// until the total cost and entry count fit. Memory pressure clears it through `RenderingCaches`.
@MainActor
final class TranscriptPartsCache {
    static let shared = TranscriptPartsCache()

    struct Snapshot: Equatable {
        let entryCount: Int
        let totalCost: Int
    }

    private struct Entry {
        let source: String
        let parts: [String]
        let cost: Int
        var access: UInt64
    }

    let maximumEntries: Int
    let maximumTotalCost: Int
    let maximumEntryCost: Int
    private var entries: [String: Entry] = [:]
    private var totalCost = 0
    private var clock: UInt64 = 0

    /// Defaults retain at most 8 MiB of text (for example sixteen 256 KiB replies with their parts);
    /// one entry may use at most 1 MiB, so a single enormous reply is rendered but never retained.
    init(maximumEntries: Int = 64, maximumTotalCost: Int = 8 * 1_024 * 1_024, maximumEntryCost: Int = 1_024 * 1_024) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumTotalCost = max(1, maximumTotalCost)
        self.maximumEntryCost = max(1, min(maximumEntryCost, maximumTotalCost))
    }

    static func cost(of source: String) -> Int { source.utf8.count * 2 }

    func parts(for key: String, source: String) -> [String]? {
        guard var entry = entries[key], entry.source == source else { return nil }
        clock &+= 1
        entry.access = clock
        entries[key] = entry
        return entry.parts
    }

    /// Returns whether the parts were retained. A declined store also drops any older entry for the
    /// key, because that entry describes a source the owner no longer shows.
    @discardableResult
    func store(_ parts: [String], for key: String, source: String) -> Bool {
        remove(key)
        let cost = Self.cost(of: source)
        guard cost <= maximumEntryCost else { return false }
        clock &+= 1
        entries[key] = Entry(source: source, parts: parts, cost: cost, access: clock)
        totalCost += cost
        while totalCost > maximumTotalCost || entries.count > maximumEntries,
            let victim = entries.min(by: { $0.value.access < $1.value.access })?.key
        {
            remove(victim)
        }
        return entries[key] != nil
    }

    func removeAll() {
        entries.removeAll()
        totalCost = 0
    }

    func snapshot() -> Snapshot { Snapshot(entryCount: entries.count, totalCost: totalCost) }

    private func remove(_ key: String) {
        guard let old = entries.removeValue(forKey: key) else { return }
        totalCost -= old.cost
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
