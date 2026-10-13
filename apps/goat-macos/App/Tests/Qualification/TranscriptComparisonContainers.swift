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
                    ComparisonRowView(row: row, fixture: fixture, recordsAppearance: false)
                        .id(row.id)
                }
            }
            .scrollTargetLayout()
        }
        .defaultScrollAnchor(.bottom, for: .alignment)
        .defaultScrollAnchor(fixture.following ? .bottom : .top, for: .sizeChanges)
        .onAppear {
            fixture.observeSwiftUIReader()
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
        .onScrollGeometryChange(for: CGSize.self, of: { $0.containerSize }) { old, new in
            viewportSize = new
            fixture.updateSwiftUIVisibility(visibleIDs, viewportHeight: new.height)
            if old == .zero {
                fixture.recordReaderGeometry(width: new.width, font: model.chatFontSize)
            } else if old.width != new.width {
                reflowRevision += 1
            }
        }
        .onChange(of: model.chatFontSize) { reflowRevision += 1 }
        .task(id: reflowRevision) {
            let saved = fixture.capturedReader
            defer {
                // A cancelled font/width transaction must not advance the successor's key.
                if !Task.isCancelled {
                    fixture.recordReaderGeometry(width: viewportSize.width, font: model.chatFontSize)
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
            var written: CGFloat?
            while ContinuousClock.now < deadline, settled < 2 {
                await Task.yield()
                guard !Task.isCancelled else { return }
                if let written, abs(fixture.readerOrigin - written) > 0.5 {
                    print("COMPARISON_REFLOW_RESTORE yielded_to_reader corrections=\(corrections)")
                    return
                }
                guard let target = fixture.readerRestoreOffset(id: saved.id, offset: saved.offset) else {
                    settled = 0
                    scrolledTo += 1
                    proxy.scrollTo(saved.id, anchor: .top)
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
