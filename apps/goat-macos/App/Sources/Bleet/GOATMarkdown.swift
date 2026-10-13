import Caprine
import MarkdownUI
import SwiftUI

/// Small, safe additions around MarkdownUI's native GitHub-Flavoured Markdown renderer.
/// HTML documents become explicit artifacts, rendered only through the restricted Paddock host.
enum GOATMarkdownSyntax {
    /// MarkdownUI already supports GFM. GitHub Alerts are a GitHub presentation extension, so
    /// retain their meaning in portable Markdown and give the resulting quote a first-class look.
    /// Only a whole document (or a reply's first segment) can be an artifact: a later segment that
    /// starts with `<svg` is an HTML block of the reply, as it is when the reply renders whole.
    static func normalized(_ source: String, detectsArtifacts: Bool = true) -> String {
        let trimmed = detectsArtifacts ? source.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let lower = trimmed.lowercased()
        let language: String?
        if !detectsArtifacts {
            language = nil
        } else if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") {
            language = "html"
        } else if lower.hasPrefix("<svg") {
            language = "svg"
        } else {
            language = nil
        }
        if let language {
            // An artifact may itself contain Markdown fences. Keep its source intact.
            let longestRun = trimmed.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
            let fence = String(repeating: "`", count: max(3, longestRun + 1))
            return "\(fence)\(language)\n\(source)\n\(fence)"
        }
        return mathSourceFallback(source).replacingOccurrences(
            of: #"(?m)^>\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*"#,
            with: "> **$1**  ",
            options: .regularExpression)
    }

    /// Display math is selectable source until a typesetter is adopted. Keep its delimiters and
    /// backslashes intact, and never reinterpret math-looking lines inside existing code fences.
    static func mathSourceFallback(_ source: String) -> String {
        guard source.contains("$$") || source.contains("\\[") else { return source }
        var output: [String] = []
        var codeFence: (Character, Int)?
        var math: [String] = []
        var closing: String?
        func flushMath() {
            let body = math.joined(separator: "\n")
            let longest = body.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
            let fence = String(repeating: "`", count: max(3, longest + 1))
            output.append("\(fence)math\n\(body)\n\(fence)")
            math.removeAll(keepingCapacity: true)
            closing = nil
        }
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if let end = closing {
                math.append(raw)
                if trimmed == end { flushMath() }
                continue
            }
            let indentation = line.prefix { $0 == " " }.count
            if indentation <= 3, line.first != "\t", let marker = trimmed.first,
                marker == "`" || marker == "~"
            {
                let count = trimmed.prefix { $0 == marker }.count
                if let existing = codeFence {
                    if marker == existing.0, count >= existing.1, trimmed.dropFirst(count).allSatisfy(\.isWhitespace) {
                        codeFence = nil
                    }
                } else if count >= 3 {
                    codeFence = (marker, count)
                }
                output.append(raw)
            } else if codeFence == nil, indentation <= 3, line.first != "\t", trimmed == "$$" || trimmed == "\\[" {
                math = [raw]
                closing = trimmed == "$$" ? "$$" : "\\]"
            } else {
                output.append(raw)
            }
        }
        if closing != nil { flushMath() }
        return output.joined(separator: "\n")
    }
}

extension View {
    /// Shared reader treatment for chat, Paddock, and memory documents: GFM plus a clear
    /// callout treatment for GitHub Alert syntax and ordinary quotes.
    func goatMarkdownStyle(
        fontSize: CGFloat, isStreaming: Bool = false, synchronousSpacing: Bool = true
    ) -> some View {
        modifier(
            GoatMarkdownStyle(
                fontSize: fontSize, isStreaming: isStreaming, synchronousSpacing: synchronousSpacing))
    }
}

private struct GoatMarkdownStyle: ViewModifier {
    let fontSize: CGFloat
    let isStreaming: Bool
    let synchronousSpacing: Bool
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let measure = ReadingMeasure.prose(fontID: model.effectiveChatFontID, size: fontSize)
        content.markdownTextStyle(\.text) {
            FontSize(fontSize)
            FontFamily(ReadingFonts.family(model.effectiveChatFontID, role: .chat))
        }
        .markdownTextStyle(\.code) {
            FontFamily(ReadingFonts.family(model.effectiveCodeFontID, role: .code))
            FontFamilyVariant(.normal)
            FontSize(model.codeFontSize)
        }
        .markdownBlockStyle(\.codeBlock) { configuration in
            CodeBlockView(configuration: configuration, isStreaming: isStreaming)
        }
        .markdownBlockStyle(\.listItem) { configuration in
            configuration.label.labelStyle(MarkdownListLabelStyle())
        }
        .markdownTextStyle(\.link) { ForegroundColor(model.theme.tokens.tint) }
        .markdownBlockStyle(\.table) { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: true, vertical: true)
                    .markdownTableBorderStyle(.init(color: model.theme.tokens.muted.opacity(0.35)))
                    .markdownTableBackgroundStyle(
                        .alternatingRows(model.theme.tokens.surface, model.theme.tokens.tint.opacity(0.05)))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Table")
            .markdownMargin(top: .zero, bottom: .em(1))
        }
        .markdownBlockStyle(\.tableCell) { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 { FontWeight(.semibold) }
                }
                .padding(Caprine.Activity.spacing)
                .accessibilityAddTraits(configuration.row == 0 ? .isHeader : [])
        }
        // MarkdownUI's basic paragraph, capped at the reading measure; code and tables may run wider
        // (#60 D3, DESIGN.md §4).
        .markdownBlockStyle(\.paragraph) { configuration in
            BoundedWidthLayout(maximumWidth: measure) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.15))
            }
            .markdownMargin(top: .zero, bottom: .em(1))
        }
        .markdownBlockStyle(\.blockquote) { configuration in
            BoundedWidthLayout(maximumWidth: measure) {
                configuration.label
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(model.theme.tokens.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(model.theme.tokens.tint)
                            .frame(width: 3)
                    }
            }
            .markdownTextStyle { ForegroundColor(.primary) }
        }
        .modifier(GoatMarkdownBlockSpacing(synchronous: synchronousSpacing))
    }
}

/// A list item's body may contain whole paragraphs, nested lists and code scrollers.
/// Native Label baseline alignment recursively measures that entire tree. Lay out the
/// marker and body directly so each item measures its body once per width proposal.
private struct MarkdownListLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        MarkdownListLayout {
            configuration.icon
            configuration.title
        }
    }
}

private struct MarkdownListLayout: Layout {
    private let spacing: CGFloat = 8

    struct Cache {
        var marker: CGSize?
        var sizes: [CGFloat?: CGSize] = [:]
    }

    // SwiftUI recreates this cache when the layout or its children change, including
    // highlighted text and font changes. Width proposals can repeat within one update.
    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        if let size = cache.sizes[proposal.width] { return size }
        let marker = cache.marker ?? subviews[0].sizeThatFits(.unspecified)
        cache.marker = marker
        let bodyWidth = proposal.width.map { max(0, $0 - marker.width - spacing) }
        let body = subviews[1].sizeThatFits(ProposedViewSize(width: bodyWidth, height: nil))
        let size = CGSize(width: marker.width + spacing + body.width, height: max(marker.height, body.height))
        // Bound transient proposals during continuous window resizing.
        if cache.sizes.count >= 8 { cache.sizes.removeAll(keepingCapacity: true) }
        cache.sizes[proposal.width] = size
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard subviews.count == 2 else { return }
        let marker = cache.marker ?? subviews[0].sizeThatFits(.unspecified)
        cache.marker = marker
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(marker))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + marker.width + spacing, y: bounds.minY), anchor: .topLeading,
            proposal: ProposedViewSize(width: max(0, bounds.width - marker.width - spacing), height: nil))
    }
}

/// The stock path provides an independent reference for theme/policy consistency checks.
private struct GoatMarkdownBlockSpacing: ViewModifier {
    let synchronous: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if synchronous {
            content.markdownBlockSpacing(MarkdownSegmentSpacing.blockSpacing)
        } else {
            content
        }
    }
}
