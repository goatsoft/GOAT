import Caprine
import Foundation
import SwiftUI

/// Cache parsed JSON representations to avoid re-parsing on every view evaluation.
@MainActor
final class JSONNodeCache {
    static let shared = JSONNodeCache()
    private let cache = NSCache<NSString, JSONNodeBox>()

    final class JSONNodeBox: @unchecked Sendable {
        let node: JSONNode?
        init(_ node: JSONNode?) { self.node = node }
    }

    init() {
        cache.countLimit = 250
    }

    func peek(_ raw: String) -> JSONNode?? {
        cache.object(forKey: raw as NSString).map(\.node)
    }

    func set(_ raw: String, node: JSONNode?) {
        cache.setObject(JSONNodeBox(node), forKey: raw as NSString)
    }
}

/// Displays JSON as a collapsible key/value tree.
/// Objects and arrays are disclosure rows; scalars sit inline, colored by type.
struct JSONTreeView: View {
    let raw: String
    @Environment(AppModel.self) private var model
    @State private var node: JSONNode?
    @State private var didParse = false

    init(raw: String) {
        self.raw = raw
        if let cached = JSONNodeCache.shared.peek(raw) {
            _node = State(initialValue: cached)
            _didParse = State(initialValue: true)
        } else if raw.utf8.count <= 4096 {
            let parsed = JSONNode.parse(raw)
            JSONNodeCache.shared.set(raw, node: parsed)
            _node = State(initialValue: parsed)
            _didParse = State(initialValue: true)
        }
    }

    private var codeFont: Font {
        Font(ReadingFonts.nsFont(model.effectiveCodeFontID, size: 11, role: .code))
    }

    var body: some View {
        Group {
            if let node {
                JSONRowsView(node: node, depth: 0)
            } else if !didParse {
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
            if !didParse {
                let parsed = await Task.detached(priority: .userInitiated) {
                    JSONNode.parse(raw)
                }.value
                JSONNodeCache.shared.set(raw, node: parsed)
                self.node = parsed
                self.didParse = true
            }
        }
    }
}

private struct JSONRowsView: View {
    let node: JSONNode
    let depth: Int
    var pathContext: String? = nil

    var body: some View {
        switch node {
        case .object(let pairs):
            let context = pairs.first(where: { $0.key == "path" })?.value.stringValue ?? pathContext
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    JSONEntryRow(key: pair.key, value: pair.value, depth: depth, pathContext: context)
                }
            }
        case .array(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, value in
                    JSONEntryRow(key: "\(index)", value: value, depth: depth, pathContext: pathContext)
                }
            }
        default:
            JSONEntryRow(key: nil, value: node, depth: depth, pathContext: pathContext)
        }
    }
}

private struct JSONEntryRow: View {
    let key: String?
    let value: JSONNode
    let depth: Int
    let pathContext: String?
    @State private var expanded: Bool
    @Environment(AppModel.self) private var model

    init(key: String?, value: JSONNode, depth: Int, pathContext: String? = nil) {
        self.key = key
        self.value = value
        self.depth = depth
        self.pathContext = pathContext
        _expanded = State(initialValue: depth < 1)  // top level open, nested collapsed
    }

    private var isCodeKey: Bool {
        guard let key else { return false }
        return ["content", "text", "stdout", "stderr"].contains(key)
    }

    var body: some View {
        if value.isContainer {
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.tertiary)
                        if let key { Text(key).foregroundStyle(model.theme.tokens.accent) }
                        Text(value.summary).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    JSONRowsView(node: value, depth: depth + 1, pathContext: pathContext)
                        .padding(.leading, 14)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 5) {
                if let key {
                    Text("\(key):").foregroundStyle(model.theme.tokens.accent)
                }
                scalar
            }
            .padding(.leading, key == nil ? 0 : 12)
        }
    }

    @ViewBuilder private var scalar: some View {
        switch value {
        case .string(let s):
            if isCodeKey, !s.isEmpty {
                let ext = pathContext.flatMap { ($0 as NSString).pathExtension }
                let lang = (ext?.isEmpty == false) ? ext : nil
                HighlightedCodeView(
                    code: s,
                    fontSize: 11,
                    showLineNumbers: s.contains("\n"),
                    language: lang,
                    wordWrap: true
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Text(s)
                    .foregroundStyle(model.theme.tokens.ink)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .number(let n):
            Text(JSONNode.formatNumber(n))
                .foregroundStyle(model.theme.tokens.glow)
        case .bool(let b):
            Text(b ? "true" : "false").foregroundStyle(model.theme.tokens.accent2)
        case .null:
            Text("null").foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}

// MARK: - Parsed JSON model

indirect enum JSONNode: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONNode])
    case object([Pair])

    struct Pair: Identifiable, Sendable, Equatable {
        let key: String
        let value: JSONNode
        var id: String { key }
    }

    var isContainer: Bool {
        switch self {
        case .array, .object: true
        default: false
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var summary: String {
        switch self {
        case .object(let p): "{ \(p.count) field\(p.count == 1 ? "" : "s") }"
        case .array(let a): "[ \(a.count) item\(a.count == 1 ? "" : "s") ]"
        default: ""
        }
    }

    static func formatNumber(_ n: Double) -> String {
        if n.isNaN { return "NaN" }
        if n.isInfinite { return n < 0 ? "-Infinity" : "Infinity" }
        if n == n.rounded() && n >= Double(Int64.min) && n <= Double(Int64.max) {
            return Int64(n).formatted(.number.grouping(.never))
        }
        return n.formatted(.number.grouping(.never))
    }

    static func parse(_ raw: String) -> JSONNode? {
        var parser = JSONOrderedParser(raw)
        if let node = parser.parse() {
            return node
        }
        // Fallback for non-standard or edge cases
        guard let data = raw.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return convert(obj)
    }

    private static func convert(_ any: Any) -> JSONNode {
        switch any {
        case let dict as [String: Any]:
            return .object(dict.map { Pair(key: $0.key, value: convert($0.value)) })
        case let arr as [Any]:
            return .array(arr.map(convert))
        case let s as String:
            return .string(s)
        case let b as Bool where type(of: any) == type(of: NSNumber(value: true)) && (any as? NSNumber)?.isBool == true:
            return .bool(b)
        case let n as NSNumber:
            return n.isBool ? .bool(n.boolValue) : .number(n.doubleValue)
        case is NSNull:
            return .null
        default:
            return .string(String(describing: any))
        }
    }
}

// MARK: - Ordered JSON Parser

struct JSONOrderedParser {
    private let scalars: String.UnicodeScalarView
    private var index: String.UnicodeScalarIndex

    init(_ string: String) {
        self.scalars = string.unicodeScalars
        self.index = self.scalars.startIndex
    }

    mutating func parse() -> JSONNode? {
        skipWhitespace()
        guard let node = parseValue() else {
            return nil
        }
        skipWhitespace()
        guard index == scalars.endIndex else {
            return nil
        }
        return node
    }

    private mutating func skipWhitespace() {
        while index < scalars.endIndex {
            let s = scalars[index]
            if s == " " || s == "\t" || s == "\n" || s == "\r" {
                index = scalars.index(after: index)
            } else {
                break
            }
        }
    }

    private mutating func parseValue() -> JSONNode? {
        skipWhitespace()
        guard index < scalars.endIndex else { return nil }
        let c = scalars[index]
        switch c {
        case "{":
            return parseObject()
        case "[":
            return parseArray()
        case "\"":
            return parseString().map { .string($0) }
        case "t":
            return consume("true") ? .bool(true) : nil
        case "f":
            return consume("false") ? .bool(false) : nil
        case "n":
            return consume("null") ? .null : nil
        case "-", "0"..."9":
            return parseNumber()
        default:
            return nil
        }
    }

    private mutating func consume(_ literal: String) -> Bool {
        var temp = index
        for char in literal.unicodeScalars {
            guard temp < scalars.endIndex, scalars[temp] == char else { return false }
            temp = scalars.index(after: temp)
        }
        index = temp
        return true
    }

    private mutating func parseString() -> String? {
        guard index < scalars.endIndex, scalars[index] == "\"" else { return nil }
        index = scalars.index(after: index)
        var result = String.UnicodeScalarView()
        while index < scalars.endIndex {
            let s = scalars[index]
            if s == "\"" {
                index = scalars.index(after: index)
                return String(result)
            }
            if s == "\\" {
                index = scalars.index(after: index)
                guard index < scalars.endIndex else { return nil }
                let esc = scalars[index]
                index = scalars.index(after: index)
                switch esc {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "u":
                    guard let codePoint = parseHex4() else { return nil }
                    if (0xD800...0xDBFF).contains(codePoint) {
                        let saved = index
                        if index < scalars.endIndex && scalars[index] == "\\" {
                            let nextIndex = scalars.index(after: index)
                            if nextIndex < scalars.endIndex && scalars[nextIndex] == "u" {
                                index = scalars.index(after: nextIndex)
                                if let low = parseHex4(), (0xDC00...0xDFFF).contains(low) {
                                    let combined = 0x10000 + ((codePoint - 0xD800) << 10) + (low - 0xDC00)
                                    if let scalar = UnicodeScalar(combined) {
                                        result.append(scalar)
                                        continue
                                    }
                                }
                            }
                        }
                        index = saved
                    }
                    guard let scalar = UnicodeScalar(codePoint) else { return nil }
                    result.append(scalar)
                default:
                    return nil
                }
            } else {
                result.append(s)
                index = scalars.index(after: index)
            }
        }
        return nil
    }

    private mutating func parseHex4() -> UInt32? {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard index < scalars.endIndex else { return nil }
            let s = scalars[index]
            let digit: UInt32
            switch s {
            case "0"..."9": digit = s.value - 48
            case "a"..."f": digit = s.value - 97 + 10
            case "A"..."F": digit = s.value - 65 + 10
            default: return nil
            }
            value = (value << 4) | digit
            index = scalars.index(after: index)
        }
        return value
    }

    private mutating func parseNumber() -> JSONNode? {
        let start = index
        if scalars[index] == "-" {
            index = scalars.index(after: index)
        }
        guard index < scalars.endIndex else { return nil }
        if scalars[index] == "0" {
            index = scalars.index(after: index)
        } else if ("1"..."9").contains(scalars[index]) {
            while index < scalars.endIndex && ("0"..."9").contains(scalars[index]) {
                index = scalars.index(after: index)
            }
        } else {
            return nil
        }
        if index < scalars.endIndex && scalars[index] == "." {
            index = scalars.index(after: index)
            guard index < scalars.endIndex && ("0"..."9").contains(scalars[index]) else { return nil }
            while index < scalars.endIndex && ("0"..."9").contains(scalars[index]) {
                index = scalars.index(after: index)
            }
        }
        if index < scalars.endIndex && (scalars[index] == "e" || scalars[index] == "E") {
            index = scalars.index(after: index)
            if index < scalars.endIndex && (scalars[index] == "+" || scalars[index] == "-") {
                index = scalars.index(after: index)
            }
            guard index < scalars.endIndex && ("0"..."9").contains(scalars[index]) else { return nil }
            while index < scalars.endIndex && ("0"..."9").contains(scalars[index]) {
                index = scalars.index(after: index)
            }
        }
        let numStr = String(scalars[start..<index])
        guard let doubleVal = Double(numStr) else { return nil }
        return .number(doubleVal)
    }

    private mutating func parseArray() -> JSONNode? {
        guard index < scalars.endIndex && scalars[index] == "[" else { return nil }
        index = scalars.index(after: index)
        skipWhitespace()
        if index < scalars.endIndex && scalars[index] == "]" {
            index = scalars.index(after: index)
            return .array([])
        }
        var items: [JSONNode] = []
        while true {
            guard let val = parseValue() else { return nil }
            items.append(val)
            skipWhitespace()
            guard index < scalars.endIndex else { return nil }
            if scalars[index] == "]" {
                index = scalars.index(after: index)
                return .array(items)
            }
            if scalars[index] == "," {
                index = scalars.index(after: index)
            } else {
                return nil
            }
        }
    }

    private mutating func parseObject() -> JSONNode? {
        guard index < scalars.endIndex && scalars[index] == "{" else { return nil }
        index = scalars.index(after: index)
        skipWhitespace()
        if index < scalars.endIndex && scalars[index] == "}" {
            index = scalars.index(after: index)
            return .object([])
        }
        var pairs: [JSONNode.Pair] = []
        while true {
            skipWhitespace()
            guard let key = parseString() else { return nil }
            skipWhitespace()
            guard index < scalars.endIndex && scalars[index] == ":" else { return nil }
            index = scalars.index(after: index)
            guard let value = parseValue() else { return nil }
            pairs.append(JSONNode.Pair(key: key, value: value))
            skipWhitespace()
            guard index < scalars.endIndex else { return nil }
            if scalars[index] == "}" {
                index = scalars.index(after: index)
                return .object(pairs)
            }
            if scalars[index] == "," {
                index = scalars.index(after: index)
            } else {
                return nil
            }
        }
    }
}

private extension NSNumber {
    var isBool: Bool { CFGetTypeID(self) == CFBooleanGetTypeID() }
}
