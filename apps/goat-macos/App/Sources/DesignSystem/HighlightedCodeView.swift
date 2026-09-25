import AppKit
import Caprine
import SwiftUI

private struct CodeScrollGeometry: Equatable, Sendable {
    var offset: CGFloat = 0
    var contentWidth: CGFloat = 0
    var containerWidth: CGFloat = 0

    var canScroll: Bool {
        contentWidth > containerWidth + 1
    }
}

/// Suppresses AppKit's native scroller bar so it does not conflict with Caprine-themed indicators,
/// even when the system preference "Show scroll bars: Always" is active.
private final class ScrollerDisablingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                self?.disableScroller()
            }
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil {
            DispatchQueue.main.async { [weak self] in
                self?.disableScroller()
            }
        }
    }

    func disableScroller() {
        guard let sv = enclosingScrollView else { return }
        if sv.hasHorizontalScroller {
            sv.hasHorizontalScroller = false
        }
        if sv.horizontalScroller != nil {
            sv.horizontalScroller = nil
        }
    }
}

private struct HideSystemScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerDisablingView {
        ScrollerDisablingView()
    }

    func updateNSView(_ nsView: ScrollerDisablingView, context: Context) {
        nsView.disableScroller()
    }
}

/// Read-only highlighted code, one component for every preview surface (in-chat fenced
/// blocks + the Paddock). Highlighting is pure Swift via HighlightKit (offline, no JavaScriptCore).
/// An optional monospaced line-number gutter rides alongside; both use the same font so
/// rows line up without wrapping. When word wrap is enabled, line numbers are suppressed so
/// multi-line wrapped visual rows do not misalign with single-line gutter numbers.
struct HighlightedCodeView: View {
    @Environment(AppModel.self) private var model
    nonisolated static let maximumHighlightedBytes = 256 * 1_024

    let code: String
    var fontSize: CGFloat = 12
    var showLineNumbers: Bool = false
    var language: String? = nil
    var isStreaming = false
    var showsIndicators: Bool = false
    var wordWrap: Bool = false
    var externalHover: Bool = false

    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var scrollGeometry = CodeScrollGeometry()
    @State private var internalHover = false
    @State private var isScrollerHovered = false

    private var isHovered: Bool {
        externalHover || internalHover
    }

    private var lineCount: Int {
        HighlightCache.shared.lineCount(for: code)
    }

    private var gutter: String {
        (1...lineCount).map(String.init).joined(separator: "\n")
    }

    private var permitsRichRendering: Bool {
        code.utf8.count <= Self.maximumHighlightedBytes
    }

    var body: some View {
        if wordWrap {
            wrappedContent
        } else {
            scrollingContent
        }
    }

    private var wrappedContent: some View {
        Group {
            if permitsRichRendering {
                highlightedText
                    .font(Font(ReadingFonts.nsFont(model.effectiveCodeFontID, size: fontSize, role: .code)))
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(code)
                    .font(Font(ReadingFonts.nsFont(model.effectiveCodeFontID, size: fontSize, role: .code)))
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scrollingContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                if showLineNumbers && permitsRichRendering {
                    Text(gutter)
                        .font(Font(ReadingFonts.nsFont(model.effectiveCodeFontID, size: fontSize, role: .code)))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.disabled)
                        .accessibilityHidden(true)
                }
                if permitsRichRendering {
                    highlightedText
                        .font(Font(ReadingFonts.nsFont(model.effectiveCodeFontID, size: fontSize, role: .code)))
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                } else {
                    Text(code)
                        .font(Font(ReadingFonts.nsFont(model.effectiveCodeFontID, size: fontSize, role: .code)))
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 1, alignment: .leading)
            .background(HideSystemScroller())
        }
        .scrollPosition($scrollPosition)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CodeScrollGeometry.self) { geo in
            CodeScrollGeometry(
                offset: geo.contentOffset.x,
                contentWidth: geo.contentSize.width,
                containerWidth: geo.containerSize.width
            )
        } action: { _, new in
            scrollGeometry = new
        }
        .overlay(alignment: .bottom) {
            if scrollGeometry.canScroll {
                themedScrollbar
                    .opacity(showsIndicators || isHovered ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .onHover { internalHover = $0 }
    }

    private var themedScrollbar: some View {
        GeometryReader { proxy in
            let inset = Caprine.Activity.inset
            let trackWidth = max(10, proxy.size.width - inset * 2)
            let maxOffset = max(1, scrollGeometry.contentWidth - scrollGeometry.containerWidth)
            let scrollRatio = min(max(0, scrollGeometry.offset / maxOffset), 1)
            let thumbWidth = max(
                24, min(trackWidth, trackWidth * (scrollGeometry.containerWidth / max(1, scrollGeometry.contentWidth))))
            let availableTrack = max(0, trackWidth - thumbWidth)
            let thumbOffset = availableTrack * scrollRatio
            let barHeight: CGFloat = isScrollerHovered ? 6 : 4

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.clear)
                    .frame(width: trackWidth, height: 8)

                Capsule()
                    .fill(model.theme.tokens.muted.opacity(isScrollerHovered ? 0.75 : 0.45))
                    .frame(width: thumbWidth, height: barHeight)
                    .offset(x: thumbOffset)
            }
            .frame(height: 8)
            .offset(x: inset, y: max(0, proxy.size.height - 8))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard availableTrack > 0 else { return }
                        let locationX = gesture.location.x - (thumbWidth / 2)
                        let ratio = min(max(0, locationX / availableTrack), 1)
                        scrollPosition.scrollTo(x: ratio * maxOffset)
                    }
            )
            .onHover { isScrollerHovered = $0 }
        }
        .frame(height: 8)
        .allowsHitTesting(showsIndicators || isHovered)
    }

    @ViewBuilder
    private var highlightedText: some View {
        if let language = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !language.isEmpty {
            if language == "vue" {
                VueCodeText(code: code)
            } else {
                PreparedCodeText(code: code, language: language, isStreaming: isStreaming)
            }
        } else {
            PreparedCodeText(code: code, language: nil, isStreaming: isStreaming)
        }
    }
}
