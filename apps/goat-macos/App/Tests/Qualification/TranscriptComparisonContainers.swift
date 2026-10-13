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
    let fixture: TranscriptComparisonFixture
    @State private var viewportSize = CGSize.zero
    @State private var visibleIDs: [String] = []
    @State private var reflowRevision = 0
    @Environment(AppModel.self) private var model

    var body: some View {
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
            guard !fixture.following, let saved else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard let target = fixture.readerRestoreOffset(id: saved.id, offset: saved.offset) else { return }
            fixture.scrollReader(to: target)
        }
        .onChange(of: fixture.latestRequest) {
            fixture.capturedReader = nil
            fixture.scrollReaderToLatest()
        }
        .onScrollPhaseChange { _, phase, context in
            if phase == .tracking || phase == .interacting { fixture.following = false }
            if phase == .idle {
                let geometry = context.geometry
                fixture.following = geometry.contentSize.height - geometry.visibleRect.maxY < 24
            }
        }
    }
}
