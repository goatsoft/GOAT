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

private struct ComparisonLazyList: View {
    /// Bounds a reflow restore before later reader input can be fought.
    static let restoreBudget = Duration.milliseconds(400)
    let fixture: TranscriptComparisonFixture
    @State private var viewportSize = CGSize.zero
    @State private var visibleIDs: [String] = []
    @State private var reflowRevision = 0
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            list(proxy)
        }
    }

    private func list(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(fixture.rows) { row in
                    ComparisonSizedRow(row: row, fixture: fixture)
                        .id(row.id)
                }
            }
            .scrollTargetLayout()
        }
        // During a font or width reflow only, SwiftUI holds the reader's row by identity. A lazy stack that
        // keeps a content offset instead re-measures every row above the reader to find it again, which
        // costs the bytes above the viewport rather than the rows on screen (#85, #86). The binding is
        // read-only: SwiftUI never retains a target that could replay against later reader input.
        .scrollPosition(id: Binding(get: { fixture.reflowAnchorID }, set: { _ in }), anchor: .top)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .defaultScrollAnchor(fixture.following ? .bottom : .top, for: .sizeChanges)
        .onAppear {
            fixture.observeSwiftUIReader()
        }
        .task(id: fixture.structureRevision) {
            await fixture.sizing.prepareAhead(fixture.rows)
        }
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { ids in
            visibleIDs = ids
            fixture.updateSwiftUIVisibility(ids, viewportHeight: viewportSize.height)
            fixture.refreshReaderCapture()
        }
        // Lazy rows replace estimated heights as they mount near the end, so a single jump to the
        // estimated end falls short. While following, every content height change keeps the end in view.
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.height }) { old, new in
            guard fixture.following, old != new else { return }
            fixture.scrollReaderToLatest()
        }
        // Any reader movement, native or SwiftUI-driven, refreshes the captured anchor once rows mount.
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, _ in
            fixture.refreshReaderCapture(retries: 12)
        }
        .onScrollGeometryChange(for: CGSize.self, of: { $0.containerSize }) { old, new in
            viewportSize = new
            fixture.updateSwiftUIVisibility(visibleIDs, viewportHeight: new.height)
            if old == .zero {
                fixture.recordReaderGeometry(width: new.width, font: model.chatFontSize)
            } else if old.width != new.width {
                fixture.reflowPending = true
                reflowRevision += 1
            }
        }
        .onChange(of: model.chatFontSize) {
            fixture.reflowPending = true
            reflowRevision += 1
        }
        .task(id: reflowRevision) {
            let saved = fixture.capturedReader
            defer {
                // A cancelled font/width transaction must not advance the successor's key.
                if !Task.isCancelled {
                    fixture.recordReaderGeometry(width: viewportSize.width, font: model.chatFontSize)
                    fixture.reflowPending = false
                    fixture.reflowAnchorID = nil
                }
            }
            guard !fixture.following, let saved else {
                print(
                    "COMPARISON_REFLOW_RESTORE skipped following=\(fixture.following) saved=false \(fixture.captureDiagnostics)"
                )
                return
            }
            // Reflow changes every height above the reader, so the saved row may no longer be mounted
            // at the old clip origin. Bring it into the lazy stack by identity, then correct its pixel
            // offset from native geometry until it holds still for two consecutive frames. Each step is
            // a one-shot write; nothing is retained to replay against later input. The deadline keeps
            // the whole restore inside the reflow transaction on slow supported-OS runners.
            let deadline = ContinuousClock.now.advanced(by: Self.restoreBudget)
            var scrolledTo = 0
            var corrections = 0
            var settled = 0
            // The origin this restore last wrote. Any other movement is the reader's, and wins.
            // Baseline: a move between the reflow and this task's first step is reader input.
            var written: CGFloat? = fixture.readerOrigin
            var proxyPending = false
            while ContinuousClock.now < deadline, settled < 2 {
                await Task.yield()
                guard !Task.isCancelled else { return }
                if proxyPending {
                    proxyPending = false
                    written = fixture.readerOrigin
                } else if written == nil {
                    written = fixture.readerOrigin
                } else if let written, abs(fixture.readerOrigin - written) > 0.5 {
                    print("COMPARISON_REFLOW_RESTORE yielded_to_reader corrections=\(corrections)")
                    return
                }
                guard let target = fixture.readerRestoreOffset(id: saved.id, offset: saved.offset) else {
                    settled = 0
                    scrolledTo += 1
                    proxy.scrollTo(saved.id, anchor: .top)
                    proxyPending = true
                    try? await Task.sleep(for: .milliseconds(16))
                    continue
                }
                // The row is placed; release the identity hold before the native pixel correction so
                // SwiftUI cannot place the row's top edge again over it.
                if fixture.reflowAnchorID != nil {
                    fixture.reflowAnchorID = nil
                    written = nil
                    try? await Task.sleep(for: .milliseconds(16))
                    continue
                }
                if abs(target - fixture.readerOrigin) > 0.5 {
                    settled = 0
                    corrections += 1
                    fixture.scrollReader(to: target)
                    written = fixture.readerOrigin
                } else {
                    settled += 1
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
            print(
                "COMPARISON_REFLOW_RESTORE scroll_to=\(scrolledTo) corrections=\(corrections) settled=\(settled >= 2)"
            )
        }
        .onChange(of: fixture.latestRequest) {
            fixture.capturedReader = nil
            fixture.scrollReaderToLatest()
        }
        // Rows near the end replace estimates for a few frames after a jump, and a supported OS need not
        // report each document growth through scroll geometry. Settle the jump while still following.
        .task(id: fixture.latestRequest) {
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, fixture.following else { return }
                guard let gap = fixture.readerDistanceFromEnd, gap > 0.5 else { continue }
                fixture.scrollReaderToLatest()
            }
        }
        .onScrollPhaseChange { _, phase, context in
            if phase == .tracking || phase == .interacting { fixture.following = false }
            if phase == .idle {
                // Programmatic writes also settle through idle, sometimes with geometry from before the
                // write; the native clip is current, so it alone decides whether the reader is at the end.
                let geometry = context.geometry
                fixture.following =
                    fixture.readerDistanceFromEnd.map { $0 < 24 }
                    ?? (geometry.contentSize.height - geometry.visibleRect.maxY < 24)
            }
        }
    }
}

/// Lays out a row's content exactly near the viewport and reports a modelled height elsewhere, so a
/// width or font reflow measures the rows on screen and not every row above them (#85, #86).
/// Placement is unchanged: a placed row whose size was an estimate is measured exactly next frame.
struct ComparisonRowMeasure: Layout {
    nonisolated(unsafe) static var measurements = 0
    nonisolated(unsafe) static var estimates = 0
    nonisolated(unsafe) static var measuredIDs: Set<String> = []
    /// Main-thread time spent producing estimates and exact row layouts, for qualification logs.
    nonisolated(unsafe) static var estimateTime = Duration.zero
    nonisolated(unsafe) static var measureTime = Duration.zero
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
        let started = ContinuousClock.now
        if let estimate = MainActor.assumeIsolated({ sizing.estimate(row, width: width, font: font) }) {
            Self.estimates += 1
            Self.estimateTime += started.duration(to: .now)
            return CGSize(width: width, height: estimate)
        }
        Self.measurements += 1
        let size = subviews.first?.sizeThatFits(proposal) ?? .zero
        Self.measureTime += started.duration(to: .now)
        let height = size.height
        MainActor.assumeIsolated { sizing.measured(row, width: width, font: font, height: height) }
        Self.measuredIDs.insert(MainActor.assumeIsolated { row.id })
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        let row = row
        let sizing = sizing
        MainActor.assumeIsolated { sizing.placed(row) }
    }
}

/// Estimated row heights for the lazy candidate.
///
/// The estimate follows the text-reflow split used by DOM-free text measurement (Pretext with TanStack
/// Virtual): an expensive width-independent `prepare` (each paragraph's unwrapped advance, in em, and
/// its word count, cached per row content) and a cheap `layout` for any width and font (greedy-wrap
/// line counts at the paragraph's real measure, times the font's line height). The last exact height
/// calibrates it: the residual between that height and the model at the measured width and font is
/// the row's non-text chrome, carried to the new font in proportion (CSS `contain-intrinsic-size: auto`
/// keeps the last size; this keeps the last size's non-text part and remodels the text part).
///
/// Two learned corrections keep the model honest. A row measured before is scaled by the model's ratio
/// between the new and the measured geometry, so the row's own chrome and the model's bias cancel. A row
/// never measured uses the model times its content kind's running ratio of exact to modelled height,
/// fitted from every exact layout (UITableView and TanStack Virtual take a fixed estimate instead).
///
/// Rows inside the window (visible plus one viewport each side) are always exact, and outside a reflow
/// so is any row never measured: SwiftUI asks for those only as it creates them to show. A row in the
/// window that still holds an estimate is bumped to measure. The lazy stack keeps the rows on screen
/// in place when a row above them changes height (TanStack Virtual's scroll adjustment), so replacing an
/// estimate above the reader needs no native correction; qualification measures that it holds.
@MainActor final class ComparisonRowSizing {
    struct Paragraph {
        enum Kind { case prose, code }
        var kind: Kind
        /// Unwrapped advance at 1 pt, so any font size is a multiplication.
        var em: CGFloat
        var words: Int
        var scale: CGFloat
        var indent: CGFloat
    }
    struct Prepared {
        let key: Int
        let paragraphs: [Paragraph]
    }
    struct Measured {
        let key: Int
        let width: CGFloat
        let font: CGFloat
        let height: CGFloat
        let model: CGFloat
    }
    struct Flip {
        let exact: CGFloat
        let model: CGFloat
        let lastSize: CGFloat?
        let proportional: CGFloat?
    }

    /// Rows that must lay out exactly. Empty until the reader reports visibility.
    private(set) var window: Set<String> = []
    private var firstVisibleIndex: Int?
    private var measuredRows: [String: Measured] = [:]
    private var estimatedRows: [String: CGFloat] = [:]
    private var preparedRows: [String: Prepared] = [:]
    private var placedEstimates: Set<String> = []
    private var advanceTables: [String: [CGFloat]] = [:]
    var index: (String) -> Int? = { _ in nil }
    var holdsReader: () -> Bool = { false }
    private(set) var flips: [Flip] = []
    /// Estimates replaced above the first visible row outside a reflow.
    private(set) var replacedAbove = 0
    /// Running exact and modelled height per content kind.
    private var calibration: [Int: (exact: CGFloat, model: CGFloat)] = [:]
    private var family = ""
    private var codeLine: CGFloat = 0
    private var codeFontKey = ""

    func isEstimated(_ id: String) -> Bool { estimatedRows[id] != nil }

    /// Prepares row text ahead of the first reflow, a few rows per main-actor turn. Preparation is the
    /// width-independent half of the model; once done, an estimate is arithmetic.
    func prepareAhead(_ rows: [ComparisonRow]) async {
        for (offset, row) in rows.enumerated() {
            _ = prepare(row, key: contentKey(row))
            if offset % 16 == 15 { await Task.yield() }
        }
    }

    /// Returns rows that hold an estimate and have entered the window; the caller invalidates them.
    func updateWindow(_ ids: Set<String>, firstVisible: Int?) -> [String] {
        window = ids
        firstVisibleIndex = firstVisible
        return ids.filter { estimatedRows[$0] != nil }
    }

    func resetStatistics() {
        flips.removeAll()
        replacedAbove = 0
    }

    /// Fonts are looked up once per change, not per row.
    private func refreshFonts() {
        let model = AppModel.shared
        let chat = model.effectiveChatFontID
        if chat != family {
            family = chat
            lineHeights.removeAll()
            measuredRows.removeAll()
        }
        let codeKey = "\(model.effectiveCodeFontID):\(model.codeFontSize)"
        if codeKey != codeFontKey {
            codeFontKey = codeKey
            let font = ReadingFonts.nsFont(model.effectiveCodeFontID, size: model.codeFontSize, role: .code)
            codeLine = ceil(font.ascender - font.descender + font.leading)
        }
    }

    /// nil means lay the row out exactly.
    func estimate(_ row: ComparisonRow, width: CGFloat, font: CGFloat) -> CGFloat? {
        if window.isEmpty || window.contains(row.id) || placedEstimates.contains(row.id) { return nil }
        let measured = measuredRows[row.id]
        if measured == nil, !holdsReader() { return nil }
        let key = contentKey(row)
        if let measured, measured.key == key, abs(measured.width - width) < 0.5, measured.font == font {
            // Back at its measured geometry the row's exact height is known again.
            estimatedRows[row.id] = nil
            return measured.height
        }
        let value = modelEstimate(row, key: key, width: width, font: font)
        estimatedRows[row.id] = value
        return value
    }

    func measured(_ row: ComparisonRow, width: CGFloat, font: CGFloat, height: CGFloat) {
        let key = contentKey(row)
        refreshFonts()
        let model = modelHeight(prepare(row, key: key), width: width, font: font)
        let kind = kind(of: row)
        let fit = calibration[kind] ?? (0, 0)
        calibration[kind] = (fit.exact + height, fit.model + model)
        if let estimate = estimatedRows.removeValue(forKey: row.id) {
            let previous = measuredRows[row.id]
            // Baselines are only comparable for a row whose content has not changed since it was measured.
            let comparable = previous.flatMap { $0.key == key ? $0 : nil }
            flips.append(
                Flip(
                    exact: height, model: estimate, lastSize: comparable?.height,
                    proportional: comparable.map { proportionalEstimate($0, width: width, font: font) }))
            let above =
                !holdsReader() && firstVisibleIndex.map { first in index(row.id).map { $0 < first } ?? false } ?? false
            if above { replacedAbove += 1 }
        }
        placedEstimates.remove(row.id)
        measuredRows[row.id] = Measured(key: key, width: width, font: font, height: height, model: model)
    }

    /// A row SwiftUI placed with an estimate is about to be drawn; measure it next update.
    func placed(_ row: ComparisonRow) {
        guard estimatedRows[row.id] != nil, !placedEstimates.contains(row.id) else { return }
        placedEstimates.insert(row.id)
        Task { @MainActor in row.sizingEpoch += 1 }
    }

    private func contentKey(_ row: ComparisonRow) -> Int {
        var hasher = Hasher()
        hasher.combine(row.revision)
        hasher.combine(text(of: row)?.utf8.count ?? -1)
        return hasher.finalize()
    }

    // MARK: Model

    private func modelEstimate(_ row: ComparisonRow, key: Int, width: CGFloat, font: CGFloat) -> CGFloat {
        refreshFonts()
        let model = modelHeight(prepare(row, key: key), width: width, font: font)
        // A row whose content changed since its measurement (a streaming tail) has no comparable size.
        guard let measured = measuredRows[row.id], measured.key == key, measured.model > 0 else {
            let fit = calibration[kind(of: row)]
            let ratio = fit.map { $0.model > 0 ? $0.exact / $0.model : 1 } ?? 1
            return model * ratio
        }
        return measured.height * model / measured.model
    }

    /// Rows of one kind share chrome and markdown structure, so they share a calibration ratio.
    private func kind(of row: ComparisonRow) -> Int {
        switch row.content {
        case .message: 0
        case .markdown(_, let segment, _): segment.kind == .fencedCodePiece ? 2 : 1
        case .reasoning(let segment): segment.language != nil ? 4 : 3
        case .label: 5
        case .tools: 6
        }
    }

    /// The baseline the model is judged against: text area scales with font squared over measure.
    private func proportionalEstimate(_ measured: Measured, width: CGFloat, font: CGFloat) -> CGFloat {
        let oldMeasure = proseWidth(measured.width, font: measured.font)
        let newMeasure = proseWidth(width, font: font)
        let ratio = font / max(measured.font, 1)
        return Self.verticalPadding + (measured.height - Self.verticalPadding) * ratio * ratio * oldMeasure
            / max(newMeasure, 1)
    }

    static let verticalPadding: CGFloat = 12
    static let horizontalPadding: CGFloat = 32

    private func proseWidth(_ width: CGFloat, font: CGFloat) -> CGFloat {
        let measure = ReadingMeasure.prose(fontID: family, size: font)
        return max(1, min(width - Self.horizontalPadding, measure))
    }

    private var lineHeights: [CGFloat: CGFloat] = [:]
    private func lineHeight(_ size: CGFloat) -> CGFloat {
        if let cached = lineHeights[size] { return cached }
        let font = ReadingFonts.nsFont(family, size: size, role: .chat)
        // Natural line height plus the paragraph style's 0.15 em line spacing.
        let height = ceil(font.ascender - font.descender + font.leading) + 0.15 * size
        lineHeights[size] = height
        return height
    }

    func modelHeight(_ prepared: Prepared, width: CGFloat, font: CGFloat) -> CGFloat {
        let measure = proseWidth(width, font: font)
        let code = codeLine
        // Rows without text (tool groups) still grow with the font.
        guard !prepared.paragraphs.isEmpty else { return Self.verticalPadding + 6 * lineHeight(font) }
        var height = Self.verticalPadding
        var previousCode = false
        for paragraph in prepared.paragraphs {
            switch paragraph.kind {
            case .code:
                height += code
                previousCode = true
            case .prose:
                if previousCode { height += font }
                previousCode = false
                let size = font * paragraph.scale
                let available = max(size * 4, measure - paragraph.indent)
                let lines = Self.wrappedLines(
                    extent: paragraph.em * size, words: paragraph.words, width: available)
                // Paragraph blocks carry a 1 em bottom margin.
                height += CGFloat(lines) * lineHeight(size) + font
            }
        }
        if previousCode { height += font }
        return height
    }

    /// Greedy word wrap leaves, on average, half a word's advance unused at the end of each line.
    static func wrappedLines(extent: CGFloat, words: Int, width: CGFloat) -> Int {
        guard extent > width else { return 1 }
        let word = extent / CGFloat(max(words, 1))
        let usable = max(width * 0.5, width - min(word, width * 0.5) / 2)
        return Int((extent / usable).rounded(.up))
    }

    // MARK: Prepare

    private func text(of row: ComparisonRow) -> String? {
        switch row.content {
        case .message(let message): message.text
        case .markdown(_, let segment, _): segment.body
        case .reasoning(let segment): segment.text
        case .label(let label): label
        case .tools: nil
        }
    }

    private func prepare(_ row: ComparisonRow, key: Int) -> Prepared {
        if let prepared = preparedRows[row.id], prepared.key == key { return prepared }
        var allCode = false
        switch row.content {
        case .markdown(_, let segment, _): allCode = segment.kind == .fencedCodePiece
        case .reasoning(let segment): allCode = segment.language != nil
        default: break
        }
        let prepared = Prepared(key: key, paragraphs: paragraphs(text(of: row) ?? "", allCode: allCode))
        preparedRows[row.id] = prepared
        return prepared
    }

    /// Advances at 1 pt for ASCII in the chat font; other scripts use an em fraction.
    private func advances() -> [CGFloat] {
        refreshFonts()
        if let table = advanceTables[family] { return table }
        let font = ReadingFonts.nsFont(family, size: 100, role: .chat) as CTFont
        var characters = (0..<128).map { UniChar($0) }
        var glyphs = [CGGlyph](repeating: 0, count: 128)
        CTFontGetGlyphsForCharacters(font, &characters, &glyphs, 128)
        var sizes = [CGSize](repeating: .zero, count: 128)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &sizes, 128)
        let table = sizes.map { $0.width / 100 }
        advanceTables[family] = table
        return table
    }

    private func paragraphs(_ source: String, allCode: Bool) -> [Paragraph] {
        let table = advances()
        var result: [Paragraph] = []
        var current: Paragraph?
        var inFence = false
        func close() {
            if let paragraph = current { result.append(paragraph) }
            current = nil
        }
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if allCode || inFence {
                if !allCode, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    inFence = false
                    close()
                    continue
                }
                result.append(Paragraph(kind: .code, em: 0, words: 1, scale: 1, indent: 0))
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                close()
                inFence = true
                continue
            }
            if trimmed.isEmpty {
                close()
                continue
            }
            if trimmed.hasPrefix("|") {
                close()
                result.append(Paragraph(kind: .code, em: 0, words: 1, scale: 1, indent: 0))
                continue
            }
            var body = trimmed
            var scale: CGFloat = 1
            var indent: CGFloat = 0
            var starts = false
            if let hashes = Optional(body.prefix { $0 == "#" }.count), hashes > 0, hashes <= 6,
                body.dropFirst(hashes).first == " "
            {
                scale = [1.6, 1.35, 1.15, 1, 1, 1][hashes - 1]
                body = body.dropFirst(hashes + 1)
                starts = true
            } else if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
                body = body.dropFirst(2)
                indent = 24 + CGFloat(line.count - trimmed.count) * 4
                starts = true
            } else if let digits = Optional(body.prefix { $0.isNumber }.count), digits > 0,
                body.dropFirst(digits).hasPrefix(". ")
            {
                body = body.dropFirst(digits + 2)
                indent = 28
                starts = true
            } else if body.hasPrefix(">") {
                body = body.dropFirst().drop { $0 == " " }
                indent = 24
                starts = current?.indent != 24
            }
            if starts || current == nil {
                close()
                current = Paragraph(kind: .prose, em: 0, words: 0, scale: scale, indent: indent)
            } else {
                // A soft break joins the paragraph with a space.
                current?.em += table[32]
                current?.words += 1
            }
            let (em, words) = Self.extent(of: body, table: table)
            current?.em += em
            current?.words += words
            if scale != 1 { close() }
        }
        close()
        return result
    }

    /// Unwrapped advance of rendered text, skipping emphasis, code spans and link destinations.
    private static func extent(of text: Substring, table: [CGFloat]) -> (CGFloat, Int) {
        var em: CGFloat = 0
        var words = 1
        var skippingDestination = false
        var previous: UInt8 = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if skippingDestination {
                if value == 41 { skippingDestination = false }
                continue
            }
            if value < 128 {
                let byte = UInt8(value)
                switch byte {
                case 42, 96, 91: break  // * ` [
                case 93: break  // ]
                case 40 where previous == 93: skippingDestination = true  // ](
                case 32:
                    em += table[32]
                    if previous != 32 { words += 1 }
                default: em += table[Int(byte)]
                }
                previous = byte
            } else {
                // Wide East Asian scripts advance a full em; other scripts about Latin's average.
                em += (0x2E80...0xFFEF).contains(value) || value >= 0x1F000 ? 1 : 0.55
                if value >= 0x2E80 { words += 1 }
                previous = 0
            }
        }
        return (em, words)
    }
}

/// Observes the one row's sizing epoch, so only a row that replaces an estimate is invalidated.
struct ComparisonSizedRow: View {
    let row: ComparisonRow
    let fixture: TranscriptComparisonFixture
    @Environment(AppModel.self) private var model

    nonisolated(unsafe) static var bodies = 0

    var body: some View {
        let _ = Self.bodies += 1
        ComparisonRowMeasure(row: row, sizing: fixture.sizing, epoch: row.sizingEpoch, font: model.chatFontSize) {
            ComparisonRowView(row: row, fixture: fixture, recordsAppearance: false)
        }
    }
}
