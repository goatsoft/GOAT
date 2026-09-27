import AppKit
import Bleet
import Caprine
import SwiftUI

@testable import GOAT

/// Two test-only containers, identical row model, renderer, cache and surrounding controls.
struct TranscriptComparisonSurface: View {
    let fixture: TranscriptComparisonFixture
    let backend: String
    @Environment(AppModel.self) private var model
    @State private var inspector = false

    var body: some View {
        @Bindable var fixture = fixture
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                Text("Comparison: \(backend)")
                Picker("Theme", selection: $model.themeID) {
                    ForEach(ThemeCatalog.builtins) { Text($0.name).tag($0.id) }
                }.frame(width: 150)
                Stepper("Font \(Int(model.chatFontSize))", value: $model.chatFontSize, in: 10...28)
                Toggle("Inspector", isOn: $inspector)
                Button("Latest") {
                    fixture.following = true
                    fixture.latestRequest += 1
                }
                Button("Finish") { fixture.finished = true }
            }.padding(8)
            Text(fixture.status).font(.caption)
            HStack(spacing: 0) {
                Group {
                    if backend == "swiftui" {
                        ComparisonLazyList(fixture: fixture)
                    } else {
                        ComparisonNativeList(fixture: fixture)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if inspector {
                    VStack {
                        Text("Synthetic inspector")
                        Spacer()
                    }.frame(width: 280)
                }
            }
            TextField("Type while streaming", text: $fixture.composer).padding(12)
        }
        .background(model.theme.tokens.bg)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { fixture.viewportWidth = $0 }
        .goatPresentation()
    }
}

private struct ComparisonLazyList: View {
    let fixture: TranscriptComparisonFixture
    @State private var position = ScrollPosition(idType: String.self)
    @State private var placed = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(fixture.rows) { row in
                    ComparisonRowView(row: row, fixture: fixture)
                        .id(row.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition($position)
        .defaultScrollAnchor(placed ? nil : .bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .defaultScrollAnchor(fixture.following ? .bottom : .top, for: .sizeChanges)
        .onAppear {
            position.scrollTo(edge: .bottom)
            placed = true
        }
        .onChange(of: fixture.generation) {
            if fixture.following { position.scrollTo(edge: .bottom) }
        }
        .onChange(of: fixture.latestRequest) { position.scrollTo(edge: .bottom) }
        .onScrollPhaseChange { _, phase, context in
            if phase == .tracking || phase == .interacting { fixture.following = false }
            if phase == .idle {
                let geometry = context.geometry
                fixture.following = geometry.contentSize.height - geometry.visibleRect.maxY < 24
            }
        }
    }
}

private struct ComparisonNativeList: NSViewRepresentable {
    let fixture: TranscriptComparisonFixture
    @Environment(AppModel.self) private var model
    @Environment(\.self) private var environment

    func makeCoordinator() -> Coordinator { Coordinator(fixture) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = MeasuredScrollView()
        scroll.hasVerticalScroller = true
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript"))
        table.addTableColumn(column)
        table.headerView = nil
        table.autoresizingMask = [.width]
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        scroll.documentView = table
        scroll.drawsBackground = false
        context.coordinator.table = table
        scroll.prepareForDisplay = { [weak coordinator = context.coordinator] in coordinator?.measureNearby() }
        context.coordinator.fixture.sampleFrames = { [weak coordinator = context.coordinator] in
            coordinator?.recordFrames()
        }
        context.coordinator.observe(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        // Track the SwiftUI container width so resize invalidates offscreen height estimates too.
        let proposedWidth = fixture.viewportWidth
        context.coordinator.environment = environment
        context.coordinator.update(table, width: min(proposedWidth, scroll.contentSize.width), model: model)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        (view as? MeasuredScrollView)?.prepareForDisplay = nil
        coordinator.stop()
        if let table = view.documentView as? NSTableView {
            table.delegate = nil
            table.dataSource = nil
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let fixture: TranscriptComparisonFixture
        weak var table: NSTableView?
        var rows: [ComparisonRow] = []
        var indices: [String: Int] = [:]
        var heights: [String: CGFloat] = [:]
        var pendingHeights: [String: CGFloat] = [:]
        var updating = false
        struct HeightKey: Hashable {
            let id: String
            let revision: Int
            let preparation: UInt64
            let width: CGFloat
            let typography: String
        }
        var measuredHeights: [HeightKey: CGFloat] = [:]
        var measurementOrder: [HeightKey] = []
        var measurementHost: NSHostingView<MeasurementRoot>?
        var measurementCount = 0
        var retainedRows: [String: ComparisonRow] = [:]
        var generation = -1
        var structureRevision = -1
        var appearance = ""
        var latestRequest = -1
        var width: CGFloat = 0
        var typography = ""
        var environment = EnvironmentValues()
        var observers: [NSObjectProtocol] = []

        init(_ fixture: TranscriptComparisonFixture) { self.fixture = fixture }
        func stop() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            fixture.sampleFrames = nil
            measurementHost = nil
            for row in retainedRows.values {
                row.prepared = nil
                row.preparedRevision = -1
            }
            retainedRows.removeAll()
        }

        func observe(_ scroll: NSScrollView) {
            scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        // A bounds notification can arrive inside NSTableView's own row creation.
                        // Request the pre-display pass; never re-enter its data source here.
                        self?.table?.enclosingScrollView?.needsDisplay = true
                    }
                })
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.fixture.following = false
                    }
                })
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let table = self.table else { return }
                        self.fixture.following = table.bounds.height - table.visibleRect.maxY < 24
                    }
                })
        }

        func recordFrames() {
            guard let table, let root = table.window?.contentView else { return }
            let range = table.rows(in: table.visibleRect)
            guard range.location != NSNotFound else { return }
            var frames: [String: CGRect] = [:]
            for index in range.location..<min(rows.count, range.location + range.length) {
                let frame = table.convert(table.rect(ofRow: index), to: root)
                frames[rows[index].id] = CGRect(
                    x: frame.minX, y: root.isFlipped ? frame.minY : root.bounds.height - frame.maxY, width: frame.width,
                    height: frame.height)
            }
            fixture.frames = frames
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            heights[rows[row].id] ?? estimate(rows[row])
        }
        func estimate(_ row: ComparisonRow) -> CGFloat {
            switch row.content {
            case .label: 32
            case .tools: 160
            case .message: 100
            case .reasoning(let segment): max(48, CGFloat(segment.text.count / 80) * 20)
            case .markdown(_, let segment, _): max(64, CGFloat(segment.body.count / 80) * 20)
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
            let row = rows[index]
            let kind: String
            switch row.content {
            case .label: kind = "label"
            case .tools: kind = "tools"
            case .message: kind = "message"
            case .reasoning: kind = "reasoning"
            case .markdown: kind = "markdown"
            }
            let identifier = NSUserInterfaceItemIdentifier(kind)
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? Cell) ?? Cell()
            cell.identifier = identifier
            configure(cell, row: row)
            return cell
        }
        func configure(_ cell: Cell, row: ComparisonRow) {
            let revision = row.revision
            let fonts = typography
            let content = CellRoot(row: row, fixture: fixture, environment: environment) { [weak self] size in
                guard let self, self.typography == fonts, row.revision == revision,
                    abs(size.width - self.width) <= 0.5
                else { return }
                self.scheduleHeight(size.height, id: row.id)
            }
            if let host = cell.host {
                host.rootView = content
            } else {
                let host = NSHostingView(rootView: content)
                host.sizingOptions = []
                host.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(host)
                NSLayoutConstraint.activate([
                    host.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                    host.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                    host.topAnchor.constraint(equalTo: cell.topAnchor),
                    host.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
                ])
                cell.host = host
            }
        }

        func anchor(_ table: NSTableView) -> (String, CGFloat)? {
            let index = table.row(at: NSPoint(x: 0, y: table.visibleRect.minY + 1))
            guard rows.indices.contains(index) else { return nil }
            return (rows[index].id, table.visibleRect.minY - table.rect(ofRow: index).minY)
        }
        func restore(_ anchor: (String, CGFloat)?, table: NSTableView) {
            guard let scroll = table.enclosingScrollView else { return }
            let y: CGFloat
            if fixture.following {
                table.layoutSubtreeIfNeeded()
                y = max(0, table.bounds.height - scroll.contentSize.height)
            } else if let anchor, let index = indices[anchor.0] {
                y = table.rect(ofRow: index).minY + anchor.1
            } else {
                return
            }
            let target = max(0, min(y, table.bounds.height - scroll.contentSize.height))
            guard abs(scroll.contentView.bounds.minY - target) > 0.01 else { return }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        /// Compensate only the geometry delta above the reader. Preserve any intervening input.
        func correctAnchor(_ id: String?, previousY: CGFloat?, table: NSTableView) {
            guard let id, let previousY, let index = indices[id], let scroll = table.enclosingScrollView else { return }
            table.layoutSubtreeIfNeeded()
            let delta = table.rect(ofRow: index).minY - previousY
            guard abs(delta) > 0.01 else { return }
            let origin = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + delta))
            fixture.compensatedScroll += scroll.contentView.bounds.minY - origin.y
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func update(_ table: NSTableView, width newWidth: CGFloat, model: AppModel) {
            let nextTypography =
                "\(model.chatFontSize):\(model.codeFontSize):\(model.effectiveChatFontID):\(model.effectiveCodeFontID)"
            let resized = abs(newWidth - width) > 0.5 || typography != nextTypography
            guard !updating else { return }
            updating = true
            defer { updating = false }
            let saved = anchor(table)
            let previousAnchorY = saved.flatMap { indices[$0.0] }.map { table.rect(ofRow: $0).minY }
            let changedGeneration = generation != fixture.generation
            if resized {
                // Preserve offscreen geometry as a provisional width-scaled estimate. Exact
                // measurements are keyed by width and typography and survive round trips.
                let ratio = width > 0 && newWidth > 0 ? width / newWidth : 1
                heights = heights.mapValues { max(1, $0 * ratio) }
                width = max(1, newWidth)
                typography = nextTypography
                pendingHeights.removeAll()
            }
            let nextAppearance = "\(model.themeID):\(environment.colorScheme)"
            let appearanceChanged = nextAppearance != appearance
            appearance = nextAppearance
            if generation != fixture.generation {
                let oldCount = rows.count
                let reordered = structureRevision != fixture.structureRevision && oldCount > 0
                let oldIDs = reordered ? rows.map(\.id) : []
                rows = fixture.rows
                structureRevision = fixture.structureRevision
                if reordered {
                    let difference = rows.map(\.id).difference(from: oldIDs)
                    indices = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
                    var removed = IndexSet()
                    var inserted = IndexSet()
                    for change in difference {
                        switch change {
                        case .remove(let index, _, _): removed.insert(index)
                        case .insert(let index, _, _): inserted.insert(index)
                        }
                    }
                    table.beginUpdates()
                    table.removeRows(at: removed, withAnimation: [])
                    table.insertRows(at: inserted, withAnimation: [])
                    table.endUpdates()
                }
                if rows.count < oldCount { indices.removeAll() }
                for index in (rows.count < oldCount ? 0 : oldCount)..<rows.count {
                    indices[rows[index].id] = index
                }
                generation = fixture.generation
                if reordered {
                    // Applied above using stable row identities.
                } else if oldCount == 0 || rows.count < oldCount {
                    table.reloadData()
                } else {
                    if rows.count > oldCount {
                        table.insertRows(at: IndexSet(integersIn: oldCount..<rows.count), withAnimation: [])
                    }
                    for index in fixture.lastChanged where index < oldCount {
                        if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? Cell {
                            configure(cell, row: rows[index])
                        }
                    }
                }
            }
            if resized || appearanceChanged {
                let visible = table.rows(in: table.visibleRect)
                if visible.location != NSNotFound {
                    for index in visible.location..<min(rows.count, visible.location + visible.length) {
                        if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? Cell {
                            configure(cell, row: rows[index])
                        }
                    }
                }
            }
            if resized, !rows.isEmpty {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: rows.indices))
                }
            }
            // Measure visible and overscan rows before committing the new document geometry.
            measureNearbyRows(table)
            let jumped = latestRequest != fixture.latestRequest
            latestRequest = fixture.latestRequest
            if fixture.following, jumped || resized || changedGeneration {
                restore(nil, table: table)
            } else if resized || changedGeneration {
                correctAnchor(saved?.0, previousY: previousAnchorY, table: table)
            }
            recordFrames()
        }

        func scheduleHeight(_ height: CGFloat, id: String) {
            let height = ceil(height)
            guard height > 0, abs((heights[id] ?? 0) - height) > 0.5 else { return }
            pendingHeights[id] = height
            // SwiftUI can report during table layout. Do not mutate the table from its delegate
            // callbacks or dispatch a later-turn correction. Flush at the pre-display boundary.
            table?.enclosingScrollView?.needsDisplay = true
        }

        func measureNearby() {
            guard !updating, let table, width > 0 else { return }
            updating = true
            defer { updating = false }
            let saved = anchor(table)
            let previousY = saved.flatMap { indices[$0.0] }.map { table.rect(ofRow: $0).minY }
            measureNearbyRows(table)
            if fixture.following {
                restore(nil, table: table)
            } else {
                correctAnchor(saved?.0, previousY: previousY, table: table)
            }
        }

        func measureNearbyRows(_ table: NSTableView) {
            guard !rows.isEmpty, width > 0 else { return }
            let visible = table.visibleRect
            let overscan = visible.insetBy(dx: 0, dy: -visible.height)
            let range = table.rows(in: overscan)
            guard range.location != NSNotFound else { return }
            var updates = pendingHeights
            pendingHeights.removeAll()
            let candidates = range.location..<min(rows.count, range.location + range.length)
            let retained = Set(candidates.map { rows[$0].id })
            for (id, row) in retainedRows where !retained.contains(id) {
                row.prepared = nil
                row.preparedRevision = -1
                retainedRows[id] = nil
            }
            for index in candidates { retainedRows[rows[index].id] = rows[index] }
            let visibleRows = table.rows(in: visible)
            let visibleIndices =
                visibleRows.location == NSNotFound
                ? 0..<0 : visibleRows.location..<(visibleRows.location + visibleRows.length)
            let ordered =
                candidates.filter { visibleIndices.contains($0) } + candidates.filter { !visibleIndices.contains($0) }
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(8))
            for index in ordered {
                // Visible rows are mandatory before draw; overscan shares an 8 ms preparation budget.
                if !visibleIndices.contains(index), ContinuousClock.now >= deadline { break }
                let row = rows[index]
                let key = HeightKey(
                    id: row.id, revision: row.revision,
                    preparation: row.preparedRevision == row.revision ? row.prepared?.preparationID ?? 0 : 0,
                    width: width, typography: typography)
                let height: CGFloat
                if let known = measuredHeights[key] {
                    height = known
                } else {
                    let root = MeasurementRoot(row: row, fixture: fixture, environment: environment, width: width)
                    let host: NSHostingView<MeasurementRoot>
                    if let measurementHost {
                        host = measurementHost
                        host.rootView = root
                    } else {
                        host = NSHostingView(rootView: root)
                        host.sizingOptions = []
                        measurementHost = host
                    }
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 1)
                    host.layoutSubtreeIfNeeded()
                    height = max(1, ceil(host.fittingSize.height))
                    measuredHeights[key] = height
                    measurementOrder.append(key)
                    measurementCount += 1
                }
                // A live host can capture async image/code state unavailable to the sizing host.
                // Its reported height wins for this pass, then becomes the same keyed measurement.
                if let reported = updates[row.id] {
                    measuredHeights[key] = reported
                } else {
                    updates[row.id] = height
                }
            }
            if measurementOrder.count > 4096 {
                for key in measurementOrder.prefix(measurementOrder.count - 4096) { measuredHeights[key] = nil }
                measurementOrder.removeFirst(measurementOrder.count - 4096)
            }
            var changed = IndexSet()
            for (id, height) in updates {
                guard let index = indices[id], abs((heights[id] ?? estimate(rows[index])) - height) > 0.5 else {
                    continue
                }
                heights[id] = height
                changed.insert(index)
            }
            guard !changed.isEmpty else { return }
            fixture.heightUpdates += changed.count
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                table.noteHeightOfRows(withIndexesChanged: changed)
            }
            table.layoutSubtreeIfNeeded()
        }
    }

    /// AppKit calls this before drawing descendants. Geometry corrections are committed here,
    /// rather than a Task that can yield past presentation. Bounds changes also prepare overscan.
    @MainActor final class MeasuredScrollView: NSScrollView {
        var prepareForDisplay: (() -> Void)?
        override func viewWillDraw() {
            prepareForDisplay?()
            super.viewWillDraw()
        }
    }

    struct MeasurementRoot: View {
        let row: ComparisonRow
        let fixture: TranscriptComparisonFixture
        let environment: EnvironmentValues
        let width: CGFloat
        var body: some View {
            ComparisonRowView(
                row: row, fixture: fixture, reportsSwiftUIFrame: false,
                preparesMarkdown: false, recordsVisibility: false
            )
            .id(row.id)
            .environment(\.self, environment)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Keep a concrete root and inherit the window's resolved environment. PresentationStyle belongs
    /// to the window, not every cell. A new row identity intentionally resets row-local disclosure
    /// and prepared-content state; updates to the same row preserve it.
    struct CellRoot: View {
        let row: ComparisonRow
        let fixture: TranscriptComparisonFixture
        let environment: EnvironmentValues
        let measured: (CGSize) -> Void

        var body: some View {
            ComparisonRowView(row: row, fixture: fixture, reportsSwiftUIFrame: false, measured: measured)
                .id(row.id)
                .environment(\.self, environment)
        }
    }

    @MainActor final class Cell: NSTableCellView { var host: NSHostingView<CellRoot>? }
}
