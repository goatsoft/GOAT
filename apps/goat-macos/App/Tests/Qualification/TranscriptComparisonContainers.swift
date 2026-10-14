import AppKit
import Bleet
import Caprine
import SwiftUI

@testable import GOAT

/// Test-only flat SwiftUI candidate using production rows and a single native scroll writer.
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
                ComparisonLazyList(fixture: fixture)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// The candidate as Apple's lazy stack expects to be used (WWDC26 "Dive into lazy stacks and scrolling with
/// SwiftUI"). SwiftUI owns the scroll position: no native clip writes, no restore task, no identity hold
/// and no row size estimates of our own. The lazy stack estimates off-screen rows, keeps the topmost
/// visible row in place when sizes change, and corrects its offset as estimates resolve. Following uses the
/// bottom size-change anchor and one-shot `ScrollViewProxy.scrollTo`; visibility drives preparation.
///
/// No `scrollPosition` binding: a bound `ScrollPosition` keeps its last target and re-applies it after a
/// scroller drag or other direct clip move it was not told about (ADR-0097), and assigning an empty one
/// to clear the target scrolls to the top.
private struct ComparisonLazyList: View {
    let fixture: TranscriptComparisonFixture
    @State private var viewportHeight: CGFloat = 0
    @State private var visibleIDs: [String] = []
    @State private var atEnd = true
    @State private var endDistance: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            list(proxy)
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = fixture.rows.last?.id else { return }
        proxy.scrollTo(last, anchor: .bottom)
    }

    private func list(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // One subview per element, identified by the row's stable ID.
                ForEach(fixture.rows) { row in
                    ComparisonSizedRow(row: row, fixture: fixture)
                }
            }
            .scrollTargetLayout()
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .defaultScrollAnchor(fixture.following ? .bottom : .top, for: .sizeChanges)
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { ids in
            visibleIDs = ids
            fixture.updateSwiftUIVisibility(ids, viewportHeight: viewportHeight)
        }
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.containerSize.height }) { _, height in
            viewportHeight = height
            fixture.updateSwiftUIVisibility(visibleIDs, viewportHeight: height)
        }
        // Near the end the lazy stack has measured the rows on screen, so this distance is exact there.
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.height - $0.visibleRect.maxY }) {
            _, value in
            endDistance = value
            fixture.swiftUIEndDistance = value
            atEnd = value < 24
        }
        // Rows near the end replace their estimates as they mount, and the bottom size-change anchor alone
        // does not keep the end in view as rows are appended (976,507 pt behind after 2 MiB locally). While
        // following, each content height change keeps the end in view through SwiftUI's own position.
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.height }) { old, new in
            guard fixture.following, old != new else { return }
            scrollToEnd(proxy)
        }
        .onChange(of: fixture.latestRequest) {
            fixture.following = true
            scrollToEnd(proxy)
        }
        // A jump lands at the lazy stack's estimate of the end; rows there then replace their estimates.
        // Settle the jump for a few frames, each a one-shot scroll, while still following.
        .task(id: fixture.latestRequest) {
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, fixture.following else { return }
                if endDistance > 0.5 { scrollToEnd(proxy) }
            }
        }
        // Only the reader's own scrolling ends following; settling back at the end resumes it. A
        // programmatic jump can settle before its target rows mount, so idle never clears following.
        .onScrollPhaseChange { _, phase in
            if phase == .tracking || phase == .interacting { fixture.following = false }
            if phase == .idle, atEnd { fixture.following = true }
        }
    }
}

/// Lays a row out exactly near the viewport and reuses its last measured height elsewhere.
///
/// On a width or font change SwiftUI asks again for the size of every row it has measured before, which
/// costs the rows above the reader rather than the rows on screen (#85, #86). Outside the window (the
/// visible rows plus one viewport each side) a row reports its exact height when it has one for this
/// width and font, and otherwise its last measured height: the CSS `contain-intrinsic-size: auto` rule,
/// which on macOS 26 CI estimated replaced rows within 5.6% on average, against 24% for a text-reflow
/// model (#92). A row that enters the window, or is placed, while holding an estimate is invalidated
/// and measured exactly; the lazy stack keeps the rows on screen still when a row above them resizes.
/// During a reflow, a row never measured reports the average height of its kind, as the lazy stack
/// itself estimates; otherwise it is laid out.
struct ComparisonRowMeasure: Layout {
    nonisolated(unsafe) static var measurements = 0
    nonisolated(unsafe) static var estimates = 0
    nonisolated(unsafe) static var measuredIDs: Set<String> = []
    let row: ComparisonRow
    let sizing: ComparisonRowSizing
    /// Changes only when this row must replace an estimate; it invalidates SwiftUI's cached size.
    let epoch: Int
    let font: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let row = row
        let sizing = sizing
        let font = font
        guard let width = proposal.width else { return subviews.first?.sizeThatFits(proposal) ?? .zero }
        if let height = MainActor.assumeIsolated({ sizing.reuse(row, width: width, font: font) }) {
            Self.estimates += 1
            return CGSize(width: width, height: height)
        }
        Self.measurements += 1
        let size = subviews.first?.sizeThatFits(proposal) ?? .zero
        // Whole-point rows keep every row edge, and so every scroll offset the lazy stack derives from
        // them, on the pixel grid of a 1x display; half-point heights left the clip at half points there.
        let height = size.height.rounded(.up)
        MainActor.assumeIsolated { sizing.measured(row, width: width, font: font, height: height) }
        Self.measuredIDs.insert(MainActor.assumeIsolated { row.id })
        return CGSize(width: size.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        let row = row
        let sizing = sizing
        MainActor.assumeIsolated { sizing.placed(row) }
    }
}

@MainActor final class ComparisonRowSizing {
    private struct Measured {
        let revision: Int
        let width: CGFloat
        let font: CGFloat
        let height: CGFloat
    }
    /// Rows that must lay out exactly. Empty until the reader reports visibility.
    private(set) var window: Set<String> = []
    private var measuredRows: [String: Measured] = [:]
    /// Rows whose last reported size was a reused height or a kind average, not an exact layout.
    private var estimatedRows: Set<String> = []
    /// Running exact height per content kind, the lazy stack's own estimate for rows never measured.
    private var averages: [Int: (total: CGFloat, count: CGFloat)] = [:]
    /// The width and font rows were last proposed, and whether SwiftUI is re-laying out for a change
    /// of either (until the reader next reports visibility).
    private var geometry: (width: CGFloat, font: CGFloat)?
    private var reflowing = false
    private var placedEstimates: Set<String> = []

    /// Returns rows that hold an estimate and have entered the window; the caller invalidates them.
    func updateWindow(_ ids: Set<String>) -> [String] {
        window = ids
        reflowing = false
        return ids.filter { estimatedRows.contains($0) }
    }

    /// nil means lay the row out exactly.
    func reuse(_ row: ComparisonRow, width: CGFloat, font: CGFloat) -> CGFloat? {
        if let geometry, abs(geometry.width - width) > 0.5 || geometry.font != font { reflowing = true }
        geometry = (width, font)
        if window.isEmpty || window.contains(row.id) || placedEstimates.contains(row.id) { return nil }
        guard let measured = measuredRows[row.id] else {
            // During a reflow, a row never measured and not near the viewport is one SwiftUI places to
            // keep the reader's row still, not one it shows. Outside a reflow SwiftUI asks for a new
            // row only as it creates it to show, so that row is laid out.
            guard reflowing, let average = averages[Self.kind(of: row)], average.count > 0 else { return nil }
            estimatedRows.insert(row.id)
            return average.total / average.count
        }
        if measured.revision == row.revision, abs(measured.width - width) < 0.5, measured.font == font {
            estimatedRows.remove(row.id)
        } else {
            estimatedRows.insert(row.id)
        }
        return measured.height
    }

    func measured(_ row: ComparisonRow, width: CGFloat, font: CGFloat, height: CGFloat) {
        estimatedRows.remove(row.id)
        placedEstimates.remove(row.id)
        measuredRows[row.id] = Measured(revision: row.revision, width: width, font: font, height: height)
        let kind = Self.kind(of: row)
        let average = averages[kind] ?? (0, 0)
        averages[kind] = (average.total + height, average.count + 1)
    }

    private static func kind(of row: ComparisonRow) -> Int {
        switch row.content {
        case .message: 0
        case .markdown: 1
        case .reasoning: 2
        case .label: 3
        case .tools: 4
        }
    }

    /// A row SwiftUI placed with a reused height is about to be drawn; measure it next update.
    func placed(_ row: ComparisonRow) {
        guard estimatedRows.contains(row.id), !placedEstimates.contains(row.id) else { return }
        placedEstimates.insert(row.id)
        Task { @MainActor in row.sizingEpoch += 1 }
    }
}

/// Observes the one row's sizing epoch, so only a row that replaces an estimate is invalidated.
struct ComparisonSizedRow: View {
    let row: ComparisonRow
    let fixture: TranscriptComparisonFixture
    @Environment(AppModel.self) private var model

    var body: some View {
        ComparisonRowMeasure(row: row, sizing: fixture.sizing, epoch: row.sizingEpoch, font: model.chatFontSize) {
            ComparisonRowView(row: row, fixture: fixture, recordsAppearance: false)
        }
    }
}
