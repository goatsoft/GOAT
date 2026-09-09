import Caprine
import Memory
import SwiftUI

/// Canvas for topology, native controls for exploration. Layout is computed off-main upstream;
/// rendering and hit targets stay bounded by the provider's node and edge budgets.
struct MemoryGraphView: View {
    let graph: MemoryGraphSnapshot
    var tint: Color = .accentColor
    var compact = false
    var onSelect: ((MemoryEntryID) -> Void)?
    var expanded = false

    @Environment(AppModel.self) private var model
    @State private var camera = GraphCamera()
    @State private var isMapActive = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showFlow = true
    @State private var selectedID: MemoryEntryID?
    @State private var hoveredID: MemoryEntryID?
    @State private var query = ""
    @State private var legendHelpID: String?
    @State private var neighborsOnly = false
    @State private var showLabels = true
    @State private var showExpanded = false
    @State private var pendingOpenID: MemoryEntryID?
    @State private var viewport = CGSize.zero

    private var tokens: Caprine { model.theme.tokens }
    private var focusedID: MemoryEntryID? { hoveredID ?? selectedID }
    private var selectedNode: MemoryGraphNode? { graph.nodes.first { $0.id == selectedID } }
    private var matches: [MemoryGraphNode] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return graph.nodes.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query)
        }
    }
    private var neighborhood: Set<MemoryEntryID> {
        guard let focusedID else { return [] }
        var ids: Set<MemoryEntryID> = [focusedID]
        for edge in graph.edges {
            if edge.sourceID == focusedID { ids.insert(edge.targetID) }
            if edge.targetID == focusedID { ids.insert(edge.sourceID) }
        }
        return ids
    }
    private var visibleEdgeCount: Int {
        let ids = Set(visibleNodes.map(\.id))
        return graph.edges.count { ids.contains($0.sourceID) && ids.contains($0.targetID) }
    }
    private var visibleNodes: [MemoryGraphNode] {
        guard neighborsOnly && focusedID != nil else { return graph.nodes }
        // Build the edge-derived neighborhood once, not once for every candidate node.
        let ids = neighborhood
        return graph.nodes.filter { ids.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { proxy in
                ZStack {
                    Canvas { context, size in render(in: &context, size: size) }
                        .allowsHitTesting(false)
                    if showFlow && isMapActive && focusedID != nil && scenePhase == .active && !reduceMotion
                        && model.animationsEnabled
                    {
                        connectorFlow(size: proxy.size)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    GraphInteractionSurface(
                        isActive: $isMapActive,
                        onScroll: { delta, location, precise in
                            camera.scroll(delta: delta, precise: precise, anchor: location, size: proxy.size)
                        },
                        onRotate: { camera.orbit(horizontal: $0, vertical: $1) },
                        onPan: { delta in
                            camera.move(
                                to: CGSize(
                                    width: camera.pan.width + delta.width, height: camera.pan.height + delta.height),
                                size: proxy.size)
                        },
                        onMagnify: { factor in
                            camera.scale(
                                to: camera.zoom * factor,
                                anchor: CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2), size: proxy.size)
                        },
                        onKey: { key in
                            switch key {
                            case "+", "=": zoom(by: 1.25)
                            case "-": zoom(by: 0.8)
                            case "0": camera = GraphCamera()
                            default: return false
                            }
                            return true
                        },
                        onSelect: { location in
                            if let node = node(at: location, size: proxy.size) { selectedID = node.id }
                        },
                        onHover: { location in hoveredID = location.flatMap { node(at: $0, size: proxy.size)?.id } })
                    ForEach(visibleNodes, id: \.id) { node in
                        Button {
                            activateMap()
                            selectedID = node.id
                        } label: {
                            Circle().fill(.clear).frame(width: 26, height: 26).contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .position(point(node.position, in: proxy.size))
                        .zIndex(Double(camera.project(node.position, size: proxy.size).depth) + 2)
                        // Pointer picking belongs to the native surface; these remain accessibility actions.
                        .allowsHitTesting(false)
                        .accessibilityLabel("Focus \(node.title)")
                        .accessibilityHint(
                            "Highlights connected nodes. Use Open in the focus panel to read the record.")
                    }
                    if graph.nodes.isEmpty {
                        ContentUnavailableView("No map yet", systemImage: "point.3.connected.by.line")
                    }
                }
                .onAppear { viewport = proxy.size }
                .onChange(of: proxy.size) { _, size in viewport = size }
                .clipped()
                .overlay(alignment: .topTrailing) {
                    Text(isMapActive ? "Map active" : "Click map to explore")
                        .font(.caption2)
                        .foregroundStyle(isMapActive ? tint : tokens.muted)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(tokens.surface.opacity(0.92), in: Capsule())
                        .padding(8).allowsHitTesting(false)
                }
                .overlay(alignment: .topLeading) {
                    if !query.isEmpty {
                        Text("\(matches.count) matches in this map")
                            .font(.caption2).foregroundStyle(tokens.muted)
                            .padding(8).background(tokens.surface.opacity(0.92), in: Capsule()).padding(8)
                            .allowsHitTesting(false)
                    }
                }
                // Selection is an overlay so its card never changes projection or hit-test geometry.
                .overlay(alignment: .bottom) { selectedNodePanel.padding(10) }
            }
            footer
        }
        .background {
            RoundedRectangle(cornerRadius: 14).fill(tokens.bg.gradient)
                .overlay {
                    RoundedRectangle(cornerRadius: 14).fill(
                        RadialGradient(
                            colors: [tokens.tint.opacity(0.09), .clear], center: .center, startRadius: 0,
                            endRadius: expanded ? 450 : 230))
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(tokens.tint.opacity(0.2), lineWidth: 1) }
        .overlayPreferenceValue(MapLegendHelpKey.self) { items in
            GeometryReader { proxy in
                if let item = items.first {
                    let bounds = proxy[item.bounds]
                    let width = min(320, max(1, proxy.size.width - 20))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.caption.weight(.semibold)).foregroundStyle(tokens.ink)
                        Text(item.explanation).font(.caption).foregroundStyle(tokens.ink)
                    }
                    .padding(12).frame(width: width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(tokens.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(tokens.muted.opacity(0.35)) }
                    .shadow(color: tokens.bg.opacity(0.5), radius: 8, y: 3)
                    .frame(height: max(1, bounds.minY - 8), alignment: .bottom)
                    .offset(x: min(max(10, bounds.midX - width / 2), proxy.size.width - width - 10))
                }
            }
            .allowsHitTesting(false)
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { deactivateMap() } }
        .onDisappear { deactivateMap() }
        .onChange(of: graph) { _, _ in
            deactivateMap()
            if !graph.nodes.contains(where: { $0.id == selectedID }) { selectedID = nil }
            hoveredID = nil
            camera = GraphCamera()
        }
        .sheet(
            isPresented: $showExpanded,
            onDismiss: {
                if let id = pendingOpenID, graph.nodes.contains(where: { $0.id == id }) { onSelect?(id) }
                pendingOpenID = nil
            }
        ) {
            VStack(spacing: 12) {
                HStack {
                    Text("Memory map").font(.headline)
                    Spacer()
                    Button("Done") { showExpanded = false }.keyboardShortcut(.cancelAction)
                }
                MemoryGraphView(
                    graph: graph, tint: tint,
                    onSelect: { id in
                        pendingOpenID = id
                        showExpanded = false
                    }, expanded: true)
            }
            .padding(20).frame(minWidth: 800, idealWidth: 1050, minHeight: 600, idealHeight: 760)
            .background(tokens.bg)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Memory map, \(graph.nodes.count) nodes and \(graph.edges.count) connections")
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(tint)
            TextField("Search", text: $query)
                .textFieldStyle(.plain).font(.caption)
                .onSubmit { if let first = matches.first { focus(first) } }
                .accessibilityLabel("Search memory map")
            if !query.isEmpty {
                Menu {
                    if matches.isEmpty { Text("No matching nodes") }
                    ForEach(matches, id: \.id) { node in
                        Button(node.title) { focus(node) }
                    }
                    Divider()
                    Button("Clear search") { query = "" }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .help("Choose a matching node")
            }
            Divider().frame(height: 16)
            Button {
                zoom(by: 0.8)
            } label: {
                Image(systemName: "minus")
            }
            .help("Zoom out").accessibilityLabel("Zoom out").disabled(camera.zoom <= GraphCamera.minimumZoom)
            Text("\(Int((camera.zoom * 100).rounded()))%")
                .font(.caption2).monospacedDigit().frame(width: 46)
                .foregroundStyle(tokens.muted)
            Button {
                zoom(by: 1.25)
            } label: {
                Image(systemName: "plus")
            }
            .help("Zoom in").accessibilityLabel("Zoom in").disabled(camera.zoom >= GraphCamera.maximumZoom)
            Button {
                camera = GraphCamera()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Fit the whole map").accessibilityLabel("Fit the whole map")
            Menu {
                Toggle("Show labels", isOn: $showLabels)
                Toggle("Animate connections", isOn: $showFlow)
                Toggle("Focused neighborhood only", isOn: $neighborsOnly).disabled(selectedID == nil)
                Button("Clear focus") {
                    selectedID = nil
                    neighborsOnly = false
                }
                Divider()
                Button("Orbit left") { camera.orbit(horizontal: -.pi / 12, vertical: 0) }
                Button("Orbit right") { camera.orbit(horizontal: .pi / 12, vertical: 0) }
                Divider()
                Text("Click to activate · leave map to release")
                Text("Drag to pan · scroll or pinch to zoom")
                Button("Orbit up") { camera.orbit(horizontal: 0, vertical: -.pi / 12) }
                Button("Orbit down") { camera.orbit(horizontal: 0, vertical: .pi / 12) }
                Text("Right-drag to orbit in 3D · 0 to fit · + / - to zoom")
                Text("Associations: dots travel both ways in their starting node's colour")
                Text("Causal links: cause to effect · citations: page to evidence")
                Text("Click a node to pin its connections")
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help("Map display and controls").accessibilityLabel("Map display and controls")
            if !expanded {
                Button {
                    showExpanded = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right.square")
                }
                .help("Expand memory map").accessibilityLabel("Expand memory map")
            }
        }
        .buttonStyle(.borderless).controlSize(.small)
        .padding(10).background(tokens.surface.opacity(0.72))
    }

    @ViewBuilder private var selectedNodePanel: some View {
        if let selectedNode {
            HStack(spacing: 8) {
                nodeShape(selectedNode, rect: CGRect(x: 0, y: 0, width: 10, height: 10)).fill(
                    nodeColor(selectedNode)
                ).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        "\(selectedNode.kind == .knowledge ? "Knowledge" : selectedNode.factType.title): \(selectedNode.title)"
                    ).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(selectedNode.summary).font(.caption2).foregroundStyle(tokens.muted).lineLimit(
                        expanded ? 2 : 1)
                }
                Spacer(minLength: 0)
                if let onSelect {
                    Button("Open") { onSelect(selectedNode.id) }.controlSize(.small)
                }
                Button {
                    selectedID = nil
                    neighborsOnly = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless).accessibilityLabel("Clear node focus")
            }
            .padding(10)
            .background(nodeColor(selectedNode).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .background(tokens.surface.opacity(0.97), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(nodeColor(selectedNode).opacity(0.3), lineWidth: 1)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            legend
            if let notice = graph.notice {
                Text(notice).font(.caption2).foregroundStyle(tokens.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text(
                    "\(visibleNodes.count) nodes · \(visibleEdgeCount) connections\(graph.isTruncated ? " · partial map" : "")"
                )
                Spacer(minLength: 0)
            }
            .font(.caption2).foregroundStyle(tokens.muted).lineLimit(1)
        }
        .padding(10).background(tokens.surface.opacity(0.72))
        .overlay(alignment: .top) { Rectangle().fill(tokens.muted.opacity(0.2)).frame(height: 1) }
    }

    private var legend: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                if graph.isHindsight {
                    ForEach(
                        MemoryGraphFactType.allCases.filter {
                            $0 != .unknown
                                || graph.nodes.contains(where: { $0.kind == .page && $0.factType == .unknown })
                        }, id: \.self
                    ) { kind in
                        legendItem(
                            kind.title, kind: .page, factType: kind,
                            count: graph.nodes.count { $0.kind == .page && $0.factType == kind })
                    }
                    legendItem("Knowledge", kind: .knowledge, factType: .unknown, count: graph.knowledge.count)
                } else {
                    legendItem("Page", kind: .page, factType: .unknown, count: graph.pages.count)
                    legendItem("Source", kind: .source, factType: .unknown, count: graph.sources.count)
                }
                connectionLegend(
                    "Links", dashed: false,
                    explanation: graph.isHindsight
                        ? "Semantic similarity, shared entities and nearby times are associations: dots travel both ways, keeping their starting node's colour. Highlighted lines blend endpoint colours. Causal dots travel from cause to effect, including legacy enables/prevents links. Unknown relationships stay muted and static. Dots illustrate relationships, not live data transfer."
                        : "A wiki page links to another page. Dots and focused arrowheads travel from the linking page to the linked page, using the linking page's colour."
                )
                if graph.edges.contains(where: { !$0.directLink }) {
                    connectionLegend(
                        "Citations", dashed: true,
                        explanation:
                            "A page cites supporting evidence. Dots travel from the citing page to its evidence, using the citing page's colour. This does not mean the page created that evidence."
                    )
                }
            }.font(.caption2).padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }
    private func legendItem(_ title: String, kind: MemoryGraphNodeKind, factType: MemoryGraphFactType, count: Int)
        -> some View
    {
        let sample = MemoryGraphNode(
            id: MemoryEntryID(rawValue: "legend"), title: title, summary: "", kind: kind,
            incomingPageLinks: 0, outgoingPageLinks: 0, sourceCitationCount: 0, isHub: false, isOrphan: false,
            isDisconnected: false, position: MemoryGraphPosition(x: 0, y: 0), factType: factType)
        let explanation =
            "\(legendExplanation(kind: kind, factType: factType)) \(count) in the loaded preview. Zero means none are shown here, not that the type is disabled."
        return legendHelp(title: title, explanation: explanation) {
            HStack(spacing: 5) {
                nodeShape(sample, rect: CGRect(x: 0, y: 0, width: 10, height: 10)).fill(nodeColor(sample)).frame(
                    width: 10, height: 10)
                Text("\(title) \(count)").foregroundStyle(tokens.muted)
            }
        }
        .accessibilityLabel("\(count) \(title) nodes in this preview")
    }

    private func legendExplanation(kind: MemoryGraphNodeKind, factType: MemoryGraphFactType) -> String {
        if kind == .knowledge {
            return
                "Saved Hindsight mental models. Their citations point to supporting memories or other knowledge pages."
        }
        if kind == .source { return "Source documents cited by wiki pages." }
        if !graph.isHindsight { return "Wiki memory pages, connected by recorded links and source citations." }
        switch factType {
        case .world:
            return
                "Facts about the user, other people and the outside world, including preferences and human experiences."
        case .experience:
            return "Actions performed or lessons learned by the bank's AI assistant, not the human's experiences."
        case .observation: return "Insights Hindsight consolidated from retained facts."
        case .opinion: return "Opinion records reported by Hindsight, when present in this bank."
        case .unknown:
            return "Memories whose type is missing or not recognised. GOAT does not guess their classification."
        }
    }

    private func connectionLegend(_ title: String, dashed: Bool, explanation: String) -> some View {
        legendHelp(title: title, explanation: explanation) {
            HStack(spacing: 5) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 4))
                    path.addLine(to: CGPoint(x: 16, y: 4))
                }
                .stroke(tokens.muted, style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 3] : []))
                .frame(width: 16, height: 8)
                Text(title).foregroundStyle(tokens.muted)
            }
        }
    }

    private func legendHelp<Content: View>(
        title: String, explanation: String, @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            legendHelpID = title
        } label: {
            content().padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { legendHelpID = title } else if legendHelpID == title { legendHelpID = nil }
        }
        .anchorPreference(key: MapLegendHelpKey.self, value: .bounds) { bounds in
            legendHelpID == title ? [MapLegendHelpAnchor(title: title, explanation: explanation, bounds: bounds)] : []
        }
        .accessibilityLabel(title)
        .accessibilityHint(explanation)
    }

    private func activateMap() {
        isMapActive = true
    }
    private func deactivateMap() {
        isMapActive = false
    }
    private func zoom(by factor: CGFloat) {
        camera.scale(
            to: camera.zoom * factor, anchor: CGPoint(x: viewport.width / 2, y: viewport.height / 2), size: viewport)
    }
    private func focus(_ node: MemoryGraphNode) {
        selectedID = node.id
        camera = GraphCamera()
        let p = point(node.position, in: viewport)
        camera.move(to: CGSize(width: viewport.width / 2 - p.x, height: viewport.height / 2 - p.y), size: viewport)
    }
    private func point(_ position: MemoryGraphPosition, in size: CGSize) -> CGPoint {
        camera.project(position, size: size).point
    }

    private func node(at location: CGPoint, size: CGSize) -> MemoryGraphNode? {
        visibleNodes.filter {
            let p = camera.project($0.position, size: size).point
            return hypot(p.x - location.x, p.y - location.y) <= 13
        }.max { camera.project($0.position, size: size).depth < camera.project($1.position, size: size).depth }
    }

    private func nodeColor(_ node: MemoryGraphNode) -> Color {
        if node.kind == .knowledge { return tokens.accent2 }
        if node.kind == .source { return tokens.muted }
        switch node.factType {
        case .world: return tint
        case .experience: return tokens.accent2
        case .observation: return tokens.glow
        case .opinion: return tokens.accent
        case .unknown: return graph.isHindsight ? tokens.muted : tint
        }
    }

    private func nodeShape(_ node: MemoryGraphNode, rect: CGRect) -> Path {
        let sides: Int?
        if node.kind == .knowledge {
            sides = 6
        } else if node.factType == .experience {
            sides = 3
        } else if node.factType == .opinion {
            sides = 4
        } else {
            sides = nil
        }
        if let sides {
            var path = Path()
            for index in 0..<sides {
                let angle = Double(index) * .pi * 2 / Double(sides) - .pi / 2
                let p = CGPoint(x: rect.midX + cos(angle) * rect.width / 2, y: rect.midY + sin(angle) * rect.height / 2)
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            return path
        }
        return node.kind == .source || node.factType == .observation
            ? Path(roundedRect: rect, cornerRadius: 2) : Path(ellipseIn: rect)
    }

    private func connectorFlow(size: CGSize) -> some View {
        let nodes = Dictionary(uniqueKeysWithValues: visibleNodes.map { ($0.id, $0) })
        // Prepare projection and source colours outside the animation clock. Association pairs
        // consume two of the 24-dot budget, so dense graphs cannot double animation work.
        let paths = MemoryGraphFlow.preview(edges: graph.edges, visibleIDs: Set(nodes.keys), focus: focusedID)
            .compactMap { flow -> (CGPoint, CGPoint, Color)? in
                guard let source = nodes[flow.fromID], let target = nodes[flow.toID] else { return nil }
                return (point(source.position, in: size), point(target.position, in: size), nodeColor(source))
            }
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paths.isEmpty)) { timeline in
            Canvas { context, _ in
                for (index, endpoints) in paths.enumerated() {
                    let (start, end, color) = endpoints
                    let bend = min(24, hypot(end.x - start.x, end.y - start.y) * 0.08)
                    let control = CGPoint(x: (start.x + end.x) / 2 + bend, y: (start.y + end.y) / 2 - bend)
                    let phase = (timeline.date.timeIntervalSinceReferenceDate / 4 + Double(index) * 0.618)
                        .truncatingRemainder(dividingBy: 1)
                    let t = CGFloat(phase)
                    let u = 1 - t
                    let p = CGPoint(
                        x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                        y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
                    context.fill(
                        Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                        with: .color(color.opacity(0.12)))
                    context.fill(
                        Path(ellipseIn: CGRect(x: p.x - 1.6, y: p.y - 1.6, width: 3.2, height: 3.2)),
                        with: .color(color.opacity(0.85)))
                }
            }
        }
    }

    private func connectorShading(
        _ edge: MemoryGraphEdge, nodes: [MemoryEntryID: MemoryGraphNode], start: CGPoint, end: CGPoint,
        opacity: Double, highlighted: Bool
    ) -> GraphicsContext.Shading {
        guard highlighted, edge.relationship != .unknown,
            let source = nodes[edge.sourceID], let target = nodes[edge.targetID]
        else { return .color(tokens.muted.opacity(opacity)) }
        if edge.relationship.isAssociation {
            return .linearGradient(
                Gradient(colors: [nodeColor(source).opacity(opacity), nodeColor(target).opacity(opacity)]),
                startPoint: start, endPoint: end)
        }
        let origin = edge.relationship == .causedBy ? target : source
        return .color(nodeColor(origin).opacity(opacity))
    }

    private func render(in context: inout GraphicsContext, size: CGSize) {
        // Subtle fixed grid makes movement legible without moving or animating the background.
        for x in stride(from: 12.0, to: size.width, by: 24) {
            for y in stride(from: 12.0, to: size.height, by: 24) {
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)),
                    with: .color(tokens.muted.opacity(0.16)))
            }
        }
        let nodes = visibleNodes
        let projected = nodes.map { (node: $0, projection: camera.project($0.position, size: size)) }
        let points = Dictionary(uniqueKeysWithValues: projected.map { ($0.node.id, $0.projection.point) })
        let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let connected = neighborhood
        let matchIDs = Set(matches.map(\.id))
        let hasFocus = focusedID != nil
        for edge in graph.edges {
            guard let start = points[edge.sourceID], let end = points[edge.targetID] else { continue }
            let focused = edge.sourceID == focusedID || edge.targetID == focusedID
            var path = Path()
            path.move(to: start)
            let bend = min(24, hypot(end.x - start.x, end.y - start.y) * 0.08)
            path.addQuadCurve(
                to: end, control: CGPoint(x: (start.x + end.x) / 2 + bend, y: (start.y + end.y) / 2 - bend))
            context.stroke(
                path,
                with: connectorShading(
                    edge, nodes: nodesByID, start: start, end: end,
                    opacity: focused ? 0.75 : hasFocus ? 0.035 : graph.isHindsight ? 0.12 : 0.26,
                    highlighted: focused || isMapActive),
                style: StrokeStyle(lineWidth: focused ? 1.4 : 0.7, dash: edge.directLink ? [] : [3, 3]))
        }
        if !graph.isHindsight {
            for edge in graph.edges where edge.directLink && (focusedID == edge.sourceID || focusedID == edge.targetID)
            {
                guard let start = points[edge.sourceID], let end = points[edge.targetID] else { continue }
                let bend = min(24, hypot(end.x - start.x, end.y - start.y) * 0.08)
                let control = CGPoint(x: (start.x + end.x) / 2 + bend, y: (start.y + end.y) / 2 - bend)
                let angle = atan2(end.y - control.y, end.x - control.x)
                let tip = CGPoint(x: end.x - cos(angle) * 10, y: end.y - sin(angle) * 10)
                var arrow = Path()
                arrow.move(to: CGPoint(x: tip.x - cos(angle - 0.5) * 7, y: tip.y - sin(angle - 0.5) * 7))
                arrow.addLine(to: tip)
                arrow.addLine(to: CGPoint(x: tip.x - cos(angle + 0.5) * 7, y: tip.y - sin(angle + 0.5) * 7))
                context.stroke(
                    arrow,
                    with: connectorShading(
                        edge, nodes: nodesByID, start: start, end: end, opacity: 1, highlighted: true),
                    lineWidth: 1.2)
            }
        }
        var labelRects: [CGRect] = []
        let ranked = nodes.sorted {
            let lhs = (
                $0.id == focusedID ? 3 : matchIDs.contains($0.id) ? 2 : $0.kind == .knowledge ? 1 : 0, $0.pageDegree
            )
            let rhs = (
                $1.id == focusedID ? 3 : matchIDs.contains($1.id) ? 2 : $1.kind == .knowledge ? 1 : 0, $1.pageDegree
            )
            return lhs == rhs ? $0.id.rawValue < $1.id.rawValue : lhs > rhs
        }
        // Projection is O(N) per frame, never repeated by the depth sort's O(N log N) comparisons.
        for item in projected.sorted(by: { $0.projection.depth < $1.projection.depth }) {
            let node = item.node
            let p = item.projection.point
            let focused = node.id == focusedID
            let matched = matchIDs.contains(node.id)
            let muted = hasFocus && !connected.contains(node.id) || !query.isEmpty && !matched && !focused
            let color = nodeColor(node)
            let projection = item.projection
            let depthOpacity = min(1, max(0.4, 0.7 + projection.depth * 0.3))
            let radius: CGFloat =
                (focused ? 9 : node.kind == .knowledge ? 8 : node.isHub ? 6 : 4.5) * projection.perspective
            let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            let shape = nodeShape(node, rect: rect)
            if !muted {
                context.fill(
                    Path(ellipseIn: rect.insetBy(dx: -5, dy: -5)), with: .color(color.opacity(focused ? 0.2 : 0.07)))
            }
            context.fill(shape, with: .color(color.opacity(muted ? 0.18 : depthOpacity)))
            if focused || matched {
                context.stroke(
                    Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(tokens.ink.opacity(0.8)), lineWidth: 1)
            }
        }
        for node in ranked {
            guard let p = points[node.id] else { continue }
            let focused = node.id == focusedID
            let matched = matchIDs.contains(node.id)
            let muted = hasFocus && !connected.contains(node.id) || !query.isEmpty && !matched && !focused
            let radius: CGFloat =
                (focused ? 9 : node.kind == .knowledge ? 8 : node.isHub ? 6 : 4.5)
                * camera.project(node.position, size: size).perspective
            guard showLabels, !muted, labelRects.count < (expanded ? 18 : 8) || focused else { continue }
            let text = Text(String(node.title.prefix(expanded ? 36 : 23))).font(.caption2).foregroundColor(tokens.ink)
            let resolved = context.resolve(text)
            let measured = resolved.measure(in: CGSize(width: 220, height: 20))
            let label = CGRect(
                x: p.x - measured.width / 2 - 4, y: p.y + radius + 6, width: measured.width + 8,
                height: measured.height + 4)
            guard label.minX >= 3, label.maxX < size.width - 3, label.maxY < size.height - 3,
                !labelRects.contains(where: { $0.insetBy(dx: -5, dy: -3).intersects(label) })
            else { continue }
            labelRects.append(label)
            context.fill(Path(roundedRect: label, cornerRadius: 4), with: .color(tokens.bg.opacity(0.9)))
            context.draw(resolved, at: CGPoint(x: label.midX, y: label.midY))
        }
    }
}

private struct MapLegendHelpAnchor {
    let title: String
    let explanation: String
    let bounds: Anchor<CGRect>
}

private struct MapLegendHelpKey: PreferenceKey {
    static var defaultValue: [MapLegendHelpAnchor] { [] }
    static func reduce(value: inout [MapLegendHelpAnchor], nextValue: () -> [MapLegendHelpAnchor]) {
        value += nextValue()
    }
}
