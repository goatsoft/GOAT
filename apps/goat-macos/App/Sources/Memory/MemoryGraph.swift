import AppKit
import Charts
import Memory
import SwiftUI

/// The two curated-memory surfaces shared by a Pen and Settings. Local Markdown is intentionally
/// pages-only; the LLM Wiki earns a map because it has linked, source-backed structure.
enum MemoryBrowserMode: Hashable, CaseIterable, Identifiable {
    case pages
    case map
    case insights

    var id: Self { self }

    var title: String {
        switch self {
        case .pages: "Pages"
        case .map: "Map"
        case .insights: "Connections"
        }
    }
}

/// A deliberately quiet view switcher shared by global and Pen memory. These browser modes are
/// secondary navigation, so selection uses a neutral outline instead of the primary accent fill.
struct MemoryBrowserModePicker: View {
    @Binding var selection: MemoryBrowserMode
    var includesInsights = true
    var recordsLabel = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(MemoryBrowserMode.allCases.filter { includesInsights || $0 != .insights }) { mode in
                let selected = selection == mode
                Button {
                    selection = mode
                } label: {
                    Text(mode == .pages && recordsLabel ? "Records" : mode.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        // Plain buttons otherwise hit-test only the text in an unselected segment.
                        // Define the target inside the label, after its full-width frame.
                        .contentShape(Rectangle())
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.secondary.opacity(0.16))
                            }
                        }
                        .overlay {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("memory-browser-mode-\(mode)")
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.26), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Memory browser view")
    }
}

enum MemoryGraphNodeKind: Sendable, Hashable {
    case page
    case source
    case knowledge
}

enum MemoryGraphFactType: String, Sendable, Hashable, CaseIterable {
    case world, experience, observation, opinion, unknown

    var title: String {
        switch self {
        case .world: "World"
        case .experience: "Experience"
        case .observation: "Observation"
        case .opinion: "Opinion"
        case .unknown: "Other memory"
        }
    }
}

struct MemoryGraphPosition: Sendable, Hashable {
    let x: Double
    let y: Double
    var z: Double = 0
}

struct MemoryGraphNode: Sendable, Hashable {
    let id: MemoryEntryID
    let title: String
    let summary: String
    let kind: MemoryGraphNodeKind
    let incomingPageLinks: Int
    let outgoingPageLinks: Int
    let sourceCitationCount: Int
    let isHub: Bool
    let isOrphan: Bool
    let isDisconnected: Bool
    let position: MemoryGraphPosition
    var factType: MemoryGraphFactType = .unknown

    var pageDegree: Int { incomingPageLinks + outgoingPageLinks }
}

/// Hindsight associations are symmetric even when the API serializes a source and target.
/// Causal links and document citations carry meaning in their direction; unknown types do not.
enum MemoryGraphRelationship: String, Sendable {
    case wikiLink, citation, semantic, temporal, entity, cooccurrence
    case causedBy = "caused_by"
    case causes, enables, prevents, unknown

    static func hindsightType(_ value: String) -> Self {
        switch value {
        case "semantic": .semantic
        case "temporal": .temporal
        case "entity": .entity
        case "cooccurrence": .cooccurrence
        case "caused_by": .causedBy
        case "causes": .causes
        case "enables": .enables
        case "prevents": .prevents
        default: .unknown
        }
    }

    var isAssociation: Bool {
        switch self {
        case .semantic, .temporal, .entity, .cooccurrence: true
        default: false
        }
    }
}

struct MemoryGraphFlow: Sendable, Hashable {
    let fromID: MemoryEntryID
    let toID: MemoryEntryID

    static let maximumDots = 24

    static func preview(edges: [MemoryGraphEdge], visibleIDs: Set<MemoryEntryID>, focus: MemoryEntryID?) -> [Self] {
        guard let focus else { return [] }
        var result: [Self] = []
        var seen = Set<Self>()
        for edge in edges {
            guard edge.sourceID == focus || edge.targetID == focus,
                visibleIDs.contains(edge.sourceID), visibleIDs.contains(edge.targetID)
            else { continue }
            let additions = edge.flows.filter { !seen.contains($0) }
            // Keep association pairs together. Multiple link types can share one visual tracer.
            guard result.count + additions.count <= maximumDots else { continue }
            result += additions
            seen.formUnion(additions)
        }
        return result
    }
}

struct MemoryGraphEdge: Sendable, Hashable {
    let sourceID: MemoryEntryID
    let targetID: MemoryEntryID
    /// `true` joins memory nodes; `false` cites a supporting page or source.
    let directLink: Bool
    let relationship: MemoryGraphRelationship

    init(
        sourceID: MemoryEntryID, targetID: MemoryEntryID, directLink: Bool,
        relationship: MemoryGraphRelationship? = nil
    ) {
        self.sourceID = sourceID
        self.targetID = targetID
        self.directLink = directLink
        self.relationship = relationship ?? (directLink ? .wikiLink : .citation)
    }

    /// Causal motion goes from cause to effect. Hindsight stores caused_by as effect to cause.
    /// Citations go from the citing document to its evidence, not the reverse.
    var flows: [MemoryGraphFlow] {
        let forward = MemoryGraphFlow(fromID: sourceID, toID: targetID)
        let reverse = MemoryGraphFlow(fromID: targetID, toID: sourceID)
        switch relationship {
        case .semantic, .temporal, .entity, .cooccurrence: return [forward, reverse]
        case .causedBy: return [reverse]
        case .unknown: return []
        default: return [forward]
        }
    }
}

struct MemoryGraphSnapshot: Sendable, Equatable {
    let nodes: [MemoryGraphNode]
    let edges: [MemoryGraphEdge]
    let isTruncated: Bool
    var isHindsight = false
    var notice: String?
    var knowledge: [MemoryGraphNode] { nodes.filter { $0.kind == .knowledge } }

    static let empty = MemoryGraphSnapshot(nodes: [], edges: [], isTruncated: false)

    var pages: [MemoryGraphNode] { nodes.filter { $0.kind == .page } }
    var sources: [MemoryGraphNode] { nodes.filter { $0.kind == .source } }
    var hubCount: Int { pages.count(where: \.isHub) }
    var orphanCount: Int { pages.count(where: \.isOrphan) }
    var sourceBackedPageCount: Int { pages.count { $0.sourceCitationCount > 0 } }
}

/// Link parsing and deterministic layout both run from MemoryModel in a detached task. This type
/// has no app state, filesystem access, or MainActor isolation so it remains straightforward to
/// test and cannot make SwiftUI's render path do graph work.
enum MemoryGraphBuilder {
    private static let hubMinimumDegree = 3
    private static let maximumEdges = 480
    private static let maximumLinksPerPage = 64

    static func build(from material: LLMWikiGraphMaterial) -> MemoryGraphSnapshot {
        let pages = material.pages.sorted { lhs, rhs in
            (lhs.name, lhs.entry.id.rawValue) < (rhs.name, rhs.entry.id.rawValue)
        }
        let pageIDsByName = Dictionary(uniqueKeysWithValues: pages.map { ($0.name, $0.entry.id) })
        let sourcesByName = Dictionary(uniqueKeysWithValues: material.sources.map { ($0.name, $0.entry) })

        var edges = Set<MemoryGraphEdge>()
        var directIncoming: [MemoryEntryID: Int] = [:]
        var directOutgoing: [MemoryEntryID: Int] = [:]
        var sourceCitations: [MemoryEntryID: Int] = [:]
        var citedSourceIDs = Set<MemoryEntryID>()
        var sourceParents: [MemoryEntryID: Set<MemoryEntryID>] = [:]
        var isTruncated = material.isTruncated

        for page in pages {
            let links = wikiLinks(in: page.content)
            if links.count >= maximumLinksPerPage { isTruncated = true }
            for name in links.sorted() {
                guard edges.count < maximumEdges else {
                    isTruncated = true
                    break
                }
                if let targetID = pageIDsByName[name], targetID != page.entry.id {
                    let edge = MemoryGraphEdge(
                        sourceID: page.entry.id, targetID: targetID, directLink: true)
                    guard edges.insert(edge).inserted else { continue }
                    directOutgoing[page.entry.id, default: 0] += 1
                    directIncoming[targetID, default: 0] += 1
                } else if let source = sourcesByName[name] {
                    let edge = MemoryGraphEdge(
                        sourceID: page.entry.id, targetID: source.id, directLink: false)
                    guard edges.insert(edge).inserted else { continue }
                    sourceCitations[page.entry.id, default: 0] += 1
                    citedSourceIDs.insert(source.id)
                    sourceParents[source.id, default: []].insert(page.entry.id)
                }
            }
        }

        let pageLayoutOrder = pages.sorted { lhs, rhs in
            let lhsDegree = directIncoming[lhs.entry.id, default: 0] + directOutgoing[lhs.entry.id, default: 0]
            let rhsDegree = directIncoming[rhs.entry.id, default: 0] + directOutgoing[rhs.entry.id, default: 0]
            if lhsDegree != rhsDegree { return lhsDegree > rhsDegree }
            return lhs.name < rhs.name
        }
        let pagePositions = pagePositions(for: pageLayoutOrder.map(\.entry.id), edges: edges)
        var nodes: [MemoryGraphNode] = pageLayoutOrder.map { page in
            let incoming = directIncoming[page.entry.id, default: 0]
            let outgoing = directOutgoing[page.entry.id, default: 0]
            let citations = sourceCitations[page.entry.id, default: 0]
            let degree = incoming + outgoing
            return MemoryGraphNode(
                id: page.entry.id,
                title: page.entry.displayTitle,
                summary: page.entry.summary,
                kind: .page,
                incomingPageLinks: incoming,
                outgoingPageLinks: outgoing,
                sourceCitationCount: citations,
                isHub: degree >= hubMinimumDegree,
                // This follows `wiki_lint`: a page no other page references is an orphan even
                // when it has outgoing links of its own.
                isOrphan: incoming == 0,
                isDisconnected: degree == 0 && citations == 0,
                position: pagePositions[page.entry.id] ?? MemoryGraphPosition(x: 0, y: 0))
        }

        let pagePositionByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position) })
        let citedSources = material.sources
            .filter { citedSourceIDs.contains($0.entry.id) }
            .sorted { $0.name < $1.name }
        for (index, source) in citedSources.enumerated() {
            let parents = sourceParents[source.entry.id, default: []]
            let parentPositions = parents.compactMap { pagePositionByID[$0] }
            let position = sourcePosition(
                parents: parentPositions,
                ordinal: index,
                total: citedSources.count)
            nodes.append(
                MemoryGraphNode(
                    id: source.entry.id,
                    title: source.entry.displayTitle,
                    summary: source.entry.summary,
                    kind: .source,
                    incomingPageLinks: parents.count,
                    outgoingPageLinks: 0,
                    sourceCitationCount: 0,
                    isHub: false,
                    isOrphan: false,
                    isDisconnected: false,
                    position: position))
        }

        return MemoryGraphSnapshot(
            nodes: nodes,
            edges: edges.sorted {
                ($0.directLink ? 0 : 1, $0.sourceID.rawValue, $0.targetID.rawValue)
                    < ($1.directLink ? 0 : 1, $1.sourceID.rawValue, $1.targetID.rawValue)
            },
            isTruncated: isTruncated)
    }

    private static func wikiLinks(in content: String) -> Set<String> {
        var links = Set<String>()
        var remainder = content[...]
        while let start = remainder.range(of: "[["),
            let end = remainder[start.upperBound...].range(of: "]]"),
            start.upperBound < end.lowerBound
        {
            let candidate = String(remainder[start.upperBound..<end.lowerBound])
            if isWikiName(candidate) { links.insert(candidate) }
            if links.count >= maximumLinksPerPage { break }
            remainder = remainder[end.upperBound...]
        }
        return links
    }

    private static func isWikiName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        let scalars = Array(value.unicodeScalars)
        guard let first = scalars.first, let last = scalars.last,
            isLowercaseLetterOrDigit(first), isLowercaseLetterOrDigit(last)
        else { return false }
        return scalars.allSatisfy { isLowercaseLetterOrDigit($0) || $0.value == 45 }
    }

    private static func isLowercaseLetterOrDigit(_ scalar: UnicodeScalar) -> Bool {
        (97...122).contains(scalar.value) || (48...57).contains(scalar.value)
    }

    /// A stable, bounded force layout. It makes actual memory links pull related pages together
    /// while keeping unrelated pages apart, mapping wiki structure instead of using a decorative
    /// radial arrangement. Coordinates are normalised for the desktop viewport.
    static func pagePositions(
        for pages: [MemoryEntryID], edges: Set<MemoryGraphEdge>
    ) -> [MemoryEntryID: MemoryGraphPosition] {
        GraphLayout3D.positions(for: pages, edges: edges)
    }

    private static func adding(
        _ position: MemoryGraphPosition?, x: Double, y: Double
    ) -> MemoryGraphPosition {
        let position = position ?? MemoryGraphPosition(x: 0, y: 0)
        return MemoryGraphPosition(x: position.x + x, y: position.y + y)
    }

    private static func sourcePosition(
        parents: [MemoryGraphPosition], ordinal: Int, total: Int
    ) -> MemoryGraphPosition {
        let average = parents.reduce(MemoryGraphPosition(x: 0, y: 0)) {
            MemoryGraphPosition(x: $0.x + $1.x, y: $0.y + $1.y, z: $0.z + $1.z)
        }
        let count = Double(max(parents.count, 1))
        let base = MemoryGraphPosition(x: average.x / count, y: average.y / count, z: average.z / count)
        let angle = atan2(base.y, base.x) + (Double(ordinal) / Double(max(total, 1))) * 0.9
        return MemoryGraphPosition(
            x: min(0.94, max(-0.94, base.x + cos(angle) * 0.14)),
            y: min(0.94, max(-0.94, base.y + sin(angle) * 0.14)), z: base.z)
    }
}

/// A native Swift Charts view for the separate Connections tab. Charts owns the categorical scale,
/// axes, and marks; the desktop map stays a node-link graph because Charts does not model graph
/// topology or graph-camera interaction.
struct MemoryGraphInsightsView: View {
    @Environment(AppModel.self) private var model
    let graph: MemoryGraphSnapshot
    var tint: Color = .accentColor
    var maximumPages = 8

    private var rankedPages: [MemoryGraphNode] {
        Array(
            graph.pages
                .sorted {
                    ($0.pageDegree + $0.sourceCitationCount, $0.title)
                        > ($1.pageDegree + $1.sourceCitationCount, $1.title)
                }
                .prefix(maximumPages))
    }

    var body: some View {
        GroupBox {
            if rankedPages.isEmpty {
                ContentUnavailableView(
                    "No connection data yet",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Add linked pages or cited sources to compare the wiki's connections.")
                )
                .frame(maxWidth: .infinity, minHeight: 130)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connections by page")
                        .font(.caption.weight(.semibold))
                    Text("Each total includes links to memory pages and cited source documents.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Chart(rankedPages, id: \.id) { page in
                        let signal = page.pageDegree + page.sourceCitationCount
                        BarMark(
                            x: .value("Connections", signal),
                            y: .value("Page", page.title)
                        )
                        .foregroundStyle(page.isOrphan ? model.theme.tokens.accent2 : tint)
                        .annotation(position: .trailing) {
                            Text(signal, format: .number)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .chartLegend(.hidden)
                    .chartXAxisLabel("Connections")
                    .chartYAxis {
                        AxisMarks { value in
                            AxisValueLabel {
                                if let title = value.as(String.self) {
                                    Text(title)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                        }
                    }
                    .frame(minHeight: CGFloat(rankedPages.count * 26 + 48))
                    .accessibilityLabel("Memory page connection signal chart")
                }
            }
        } label: {
            Label("Connections", systemImage: "chart.bar.xaxis")
        }
    }
}
