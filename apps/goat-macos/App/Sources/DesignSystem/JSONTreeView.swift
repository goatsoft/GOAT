import Caprine
import Foundation
import Inference
import SwiftUI

/// Cache parsed JSON representations to avoid re-parsing on every view evaluation.
@MainActor
final class JSONValueCache {
    static let shared = JSONValueCache()
    private let cache = NSCache<NSString, Box>()

    final class Box: @unchecked Sendable {
        let value: JSONValue?
        init(_ value: JSONValue?) { self.value = value }
    }

    init() {
        cache.countLimit = 250
    }

    func peek(_ raw: String) -> JSONValue?? {
        cache.object(forKey: raw as NSString).map(\.value)
    }

    func set(_ raw: String, value: JSONValue?) {
        cache.setObject(Box(value), forKey: raw as NSString)
    }
}

/// Presentation order for JSON object keys:
/// Identity keys first (`path`, `pattern`, etc.), bulky payloads last (`content`, `stdout`, etc.),
/// and remaining keys in alphabetical order.
enum JSONPresentationOrder {
    private static let identityKeys: [String] = [
        "path", "pattern", "query", "command", "args", "job_id", "id", "name",
    ]
    private static let bulkyKeys: [String] = [
        "content", "old_text", "new_text", "text", "stdout", "stderr",
    ]

    private static let identityRank: [String: Int] = {
        Dictionary(uniqueKeysWithValues: identityKeys.enumerated().map { ($1, $0) })
    }()

    private static let bulkyRank: [String: Int] = {
        Dictionary(uniqueKeysWithValues: bulkyKeys.enumerated().map { ($1, $0) })
    }()

    static func compare(_ a: String, _ b: String) -> Bool {
        let aIdentity = identityRank[a]
        let bIdentity = identityRank[b]
        if let aIdentity, let bIdentity {
            return aIdentity < bIdentity
        }
        if aIdentity != nil { return true }
        if bIdentity != nil { return false }

        let aBulky = bulkyRank[a]
        let bBulky = bulkyRank[b]
        if let aBulky, let bBulky {
            return aBulky < bBulky
        }
        if aBulky != nil { return false }
        if bBulky != nil { return true }

        return a.localizedStandardCompare(b) == .orderedAscending
    }

    static func sortedPairs(from dict: [String: JSONValue]) -> [(key: String, value: JSONValue)] {
        dict.map { (key: $0.key, value: $0.value) }
            .sorted { compare($0.key, $1.key) }
    }
}

/// Displays JSON as a collapsible key/value tree.
/// Objects and arrays are disclosure rows; scalars sit inline, colored by type.
struct JSONTreeView: View {
    let raw: String
    @Environment(AppModel.self) private var model
    @State private var parsedRaw: String?
    @State private var value: JSONValue?

    init(raw: String) {
        self.raw = raw
        if let cached = JSONValueCache.shared.peek(raw) {
            _parsedRaw = State(initialValue: raw)
            _value = State(initialValue: cached)
        } else if raw.utf8.count <= 4096 {
            let parsed = JSONValue.parse(raw)
            JSONValueCache.shared.set(raw, value: parsed)
            _parsedRaw = State(initialValue: raw)
            _value = State(initialValue: parsed)
        }
    }

    private var codeFont: Font {
        Font(ReadingFonts.nsFont(model.effectiveCodeFontID, size: 11, role: .code))
    }

    var body: some View {
        Group {
            if parsedRaw == raw, let value {
                JSONRowsView(value: value, depth: 0)
            } else if parsedRaw != raw {
                ProgressView()
                    .controlSize(.mini)
            } else {
                // Not JSON - show it plainly.
                Text(raw)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
        }
        .font(codeFont)
        .task(id: raw) {
            if parsedRaw == raw { return }
            if let cached = JSONValueCache.shared.peek(raw) {
                parsedRaw = raw
                value = cached
                return
            }
            let parsed = await Task.detached(priority: .userInitiated) {
                JSONValue.parse(raw)
            }.value
            guard !Task.isCancelled else { return }
            JSONValueCache.shared.set(raw, value: parsed)
            parsedRaw = raw
            value = parsed
        }
    }
}

private struct JSONRowsView: View {
    let value: JSONValue
    let depth: Int
    var pathContext: String? = nil

    var body: some View {
        switch value {
        case .object(let dict):
            let context = dict["path"]?.stringValue ?? pathContext
            let pairs = JSONPresentationOrder.sortedPairs(from: dict)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(pairs, id: \.key) { pair in
                    JSONEntryRow(key: pair.key, value: pair.value, depth: depth, pathContext: context)
                }
            }
        case .array(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    JSONEntryRow(key: "\(index)", value: item, depth: depth, pathContext: pathContext)
                }
            }
        default:
            JSONScalarView(value: value)
        }
    }
}

private struct JSONEntryRow: View {
    let key: String
    let value: JSONValue
    let depth: Int
    var pathContext: String? = nil
    @State private var isExpanded: Bool
    @Environment(AppModel.self) private var model

    init(key: String, value: JSONValue, depth: Int, pathContext: String? = nil) {
        self.key = key
        self.value = value
        self.depth = depth
        self.pathContext = pathContext
        _isExpanded = State(initialValue: depth < 1)
    }

    private var isCodeContent: Bool {
        if key == "stdout" || key == "stderr" { return true }
        if pathContext != nil && (key == "content" || key == "old_text" || key == "new_text" || key == "text") {
            return true
        }
        return false
    }

    private var codeLanguage: String? {
        if let pathContext {
            let ext = (pathContext as NSString).pathExtension
            return ext.isEmpty ? nil : ext
        }
        return nil
    }

    var body: some View {
        switch value {
        case .object:
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.tertiary)
                        Text(key)
                            .foregroundStyle(model.theme.tokens.accent)
                        Text(value.summary)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    JSONRowsView(value: value, depth: depth + 1, pathContext: pathContext)
                        .padding(.leading, 14)
                }
            }

        case .array:
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.tertiary)
                        Text(key)
                            .foregroundStyle(model.theme.tokens.accent)
                        Text(value.summary)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    JSONRowsView(value: value, depth: depth + 1, pathContext: pathContext)
                        .padding(.leading, 14)
                }
            }

        case .string(let s) where isCodeContent && (s.contains("\n") || s.count > 60):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("\(key):")
                        .foregroundStyle(model.theme.tokens.accent)
                    if let codeLanguage {
                        Text(codeLanguage)
                            .foregroundStyle(.tertiary)
                            .font(.caption2)
                    }
                }
                .padding(.leading, 12)

                HighlightedCodeView(code: s, language: codeLanguage, isStreaming: false)
                    .padding(.leading, 12)
            }

        default:
            HStack(alignment: .top, spacing: 5) {
                Text("\(key):")
                    .foregroundStyle(model.theme.tokens.accent)
                JSONScalarView(value: value)
            }
            .padding(.leading, 12)
        }
    }
}

private struct JSONScalarView: View {
    let value: JSONValue
    @Environment(AppModel.self) private var model

    var body: some View {
        switch value {
        case .string(let s):
            Text(s)
                .foregroundStyle(model.theme.tokens.ink)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .integer(let i):
            Text("\(i)")
                .foregroundStyle(model.theme.tokens.glow)
                .textSelection(.enabled)
        case .number(let n):
            Text(formatNumber(n))
                .foregroundStyle(model.theme.tokens.glow)
                .textSelection(.enabled)
        case .bool(let b):
            Text(b ? "true" : "false")
                .foregroundStyle(model.theme.tokens.accent2)
                .textSelection(.enabled)
        case .null:
            Text("null")
                .foregroundStyle(.secondary)
        case .object, .array:
            Text(value.summary)
                .foregroundStyle(.tertiary)
        }
    }
}

private extension JSONValue {
    var summary: String {
        switch self {
        case .object(let dict):
            "{ \(dict.count) field\(dict.count == 1 ? "" : "s") }"
        case .array(let items):
            "[ \(items.count) item\(items.count == 1 ? "" : "s") ]"
        default:
            ""
        }
    }
}

private func formatNumber(_ n: Double) -> String {
    if n.isFinite && n == n.rounded() && n >= Double(Int.min) && n <= Double(Int.max) {
        return "\(Int(n))"
    }
    return "\(n)"
}
