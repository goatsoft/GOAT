import AppKit
import SwiftUI
import Testing

@testable import GOAT

@MainActor private final class ColumnMeasurementProbe {
    var widths: [CGFloat?] = []
    weak var view: NSView?
}

@MainActor private func columnFixture(width: CGFloat, height: CGFloat, probe: ColumnMeasurementProbe) -> some View {
    AssistantRowLayout {
        Color.clear.frame(width: 32, height: 20)
        ColumnDocument(height: height, probe: probe)
    }
    .frame(width: width)
}

private struct ColumnDocument: NSViewRepresentable {
    let height: CGFloat
    let probe: ColumnMeasurementProbe

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        probe.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        probe.widths.append(proposal.width)
        return CGSize(width: proposal.width ?? 300, height: height)
    }
}
extension AppTests.Bleet {
    @Suite struct AssistantRowLayoutTests {

        @Test @MainActor func assistantColumnsMeasureTheDocumentAtItsAvailableWidthAndReflow() async throws {
            let probe = ColumnMeasurementProbe()
            let host = NSHostingView(rootView: columnFixture(width: 500, height: 100, probe: probe))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer {
                window.contentView = nil
                window.close()
            }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            #expect(!probe.widths.isEmpty)
            #expect(probe.widths.allSatisfy { $0 == 418 })
            #expect(probe.view?.frame.height == 100)

            probe.widths.removeAll()
            host.rootView = columnFixture(width: 320, height: 180, probe: probe)
            window.setContentSize(NSSize(width: 320, height: 400))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            #expect(probe.widths.contains(238))
            #expect(probe.widths.allSatisfy { $0 == 238 || $0 == 418 })
            #expect(probe.view?.frame.height == 180)
        }

        @Test @MainActor func assistantRowLayoutUpdatesHeightWhenDocumentHeightGrowsAtConstantWidth() async throws {
            let probe = ColumnMeasurementProbe()
            let host = NSHostingView(rootView: columnFixture(width: 500, height: 60, probe: probe))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer {
                window.contentView = nil
                window.close()
            }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            #expect(probe.view?.frame.height == 60)

            // When document height expands (e.g. streaming or parts loaded), layout must update immediately.
            host.rootView = columnFixture(width: 500, height: 1200, probe: probe)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            #expect(probe.view?.frame.height == 1200)
        }
    }
}
