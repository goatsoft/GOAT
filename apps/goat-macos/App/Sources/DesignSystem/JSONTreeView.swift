import SwiftUI

/// Displays JSON as a collapsible key/value tree.
/// Objects and arrays are disclosure rows; scalars sit inline, colored by type.
struct JSONTreeView: View {
    let raw: String
    @Environment(AppModel.self) private var model

    var body: some View {
        if let node = JSONNode.parse(raw) {
            JSONRowsView(node: node, depth: 0)
                .font(.system(size: 11, design: .monospaced))
        } else {
            // Not JSON - show it plainly.
            Text(raw)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .textSelection(.enabled)
        }
    }
}

private struct JSONRowsView: View {
    let node: JSONNode
    let depth: Int

    var body: some View {
        switch node {
        case .object(let pairs):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(pairs) { pair in
                    JSONEntryRow(key: pair.key, value: pair.value, depth: depth)
                }
            }
        case .array(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, value in
                    JSONEntryRow(key: "\(index)", value: value, depth: depth)
                }
            }
        default:
            JSONEntryRow(key: nil, value: node, depth: depth)
        }
    }
}

private struct JSONEntryRow: View {
    let key: String?
    let value: JSONNode
    let depth: Int
    @State private var expanded: Bool
    @Environment(AppModel.self) private var model

    init(key: String?, value: JSONNode, depth: Int) {
        self.key = key
        self.value = value
        self.depth = depth
        _expanded = State(initialValue: depth < 1)  // top level open, nested collapsed
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
                    JSONRowsView(node: value, depth: depth + 1)
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
            Text(s)
                .foregroundStyle(model.theme.tokens.ink)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .number(let n):
            Text(n == n.rounded() ? String(Int(n)) : String(n))
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

indirect enum JSONNode {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONNode])
    case object([Pair])

    struct Pair: Identifiable {
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

    var summary: String {
        switch self {
        case .object(let p): "{ \(p.count) field\(p.count == 1 ? "" : "s") }"
        case .array(let a): "[ \(a.count) item\(a.count == 1 ? "" : "s") ]"
        default: ""
        }
    }

    static func parse(_ raw: String) -> JSONNode? {
        guard let data = raw.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return convert(obj)
    }

    private static func convert(_ any: Any) -> JSONNode {
        switch any {
        case let dict as [String: Any]:
            return .object(dict.sorted { $0.key < $1.key }.map { Pair(key: $0.key, value: convert($0.value)) })
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

private extension NSNumber {
    var isBool: Bool { CFGetTypeID(self) == CFBooleanGetTypeID() }
}
