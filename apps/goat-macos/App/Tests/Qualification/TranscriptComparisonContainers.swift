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

    func makeCoordinator() -> Coordinator { Coordinator(fixture) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
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
        context.coordinator.observe(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        // Track the SwiftUI container width so resize invalidates offscreen height estimates too.
        let proposedWidth = fixture.viewportWidth
        context.coordinator.update(table, width: min(proposedWidth, scroll.contentSize.width), model: model)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
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
        var queued = false
        var generation = -1
        var latestRequest = -1
        var width: CGFloat = 0
        var typography = ""
        var observers: [NSObjectProtocol] = []

        init(_ fixture: TranscriptComparisonFixture) { self.fixture = fixture }
        func stop() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
        }

        func observe(_ scroll: NSScrollView) {
            scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.recordFrames() }
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
            let identifier = NSUserInterfaceItemIdentifier("row")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? Cell) ?? Cell()
            cell.identifier = identifier
            configure(cell, row: row)
            return cell
        }
        func configure(_ cell: Cell, row: ComparisonRow) {
            let content = AnyView(
                ComparisonRowView(row: row, fixture: fixture, reportsSwiftUIFrame: false) { [weak self] height in
                    self?.scheduleHeight(height, id: row.id)
                }.id(row.id).goatPresentation().environment(AppModel.shared))
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
                y = max(0, table.bounds.height - scroll.contentSize.height)
            } else if let anchor, let index = indices[anchor.0] {
                y = table.rect(ofRow: index).minY + anchor.1
            } else {
                return
            }
            scroll.contentView.scroll(
                to: NSPoint(x: 0, y: max(0, min(y, table.bounds.height - scroll.contentSize.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func update(_ table: NSTableView, width newWidth: CGFloat, model: AppModel) {
            let nextTypography =
                "\(model.chatFontSize):\(model.codeFontSize):\(model.effectiveChatFontID):\(model.effectiveCodeFontID)"
            let resized = abs(newWidth - width) > 0.5 || typography != nextTypography
            let saved = anchor(table)
            if resized {
                width = newWidth
                typography = nextTypography
                heights.removeAll()
            }
            if generation != fixture.generation {
                let oldCount = rows.count
                rows = fixture.rows
                if rows.count < oldCount { indices.removeAll() }
                for index in (rows.count < oldCount ? 0 : oldCount)..<rows.count {
                    indices[rows[index].id] = index
                }
                generation = fixture.generation
                if oldCount == 0 || rows.count < oldCount {
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
            if resized, !rows.isEmpty {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: rows.indices))
                }
            }
            if latestRequest != fixture.latestRequest {
                latestRequest = fixture.latestRequest
                restore(nil, table: table)
            }
            restore(saved, table: table)
            recordFrames()
        }

        func scheduleHeight(_ height: CGFloat, id: String) {
            let height = ceil(height)
            guard height > 0, abs((heights[id] ?? 0) - height) > 0.5 else { return }
            pendingHeights[id] = height
            guard !queued else { return }
            queued = true
            // Leave delegate/view-update callbacks before mutating table geometry.
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, let table = self.table else { return }
                self.queued = false
                let saved = self.anchor(table)
                let updates = self.pendingHeights
                self.pendingHeights.removeAll()
                var changed = IndexSet()
                for (id, height) in updates {
                    guard let index = self.indices[id] else { continue }
                    self.heights[id] = height
                    changed.insert(index)
                }
                // The prototype's height cache has an explicit cap, independent of view reuse.
                if self.heights.count > 4096 {
                    self.heights = self.heights.filter { self.fixture.visible.contains($0.key) }
                }
                self.fixture.heightUpdates += changed.count
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                table.noteHeightOfRows(withIndexesChanged: changed)
                table.layoutSubtreeIfNeeded()
                self.restore(saved, table: table)
                NSAnimationContext.endGrouping()
                self.recordFrames()
            }
        }
    }

    @MainActor final class Cell: NSTableCellView { var host: NSHostingView<AnyView>? }
}
