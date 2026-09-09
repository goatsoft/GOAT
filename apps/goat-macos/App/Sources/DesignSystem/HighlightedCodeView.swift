import HighlightSwift
import SwiftUI

/// Read-only highlighted code, one component for every preview surface (in-chat fenced
/// blocks + the Paddock). Highlighting is highlight.js via HighlightSwift (runs in
/// JavaScriptCore - offline, no new dependency). An optional monospaced line-number
/// gutter rides alongside; both use the same font so rows line up without wrapping.
struct HighlightedCodeView: View {
    @Environment(AppModel.self) private var model
    nonisolated static let maximumHighlightedBytes = 256 * 1_024

    let code: String
    var fontSize: CGFloat = 12
    var showLineNumbers: Bool = false
    var language: String? = nil

    private var lineCount: Int {
        max(1, code.reduce(1) { $0 + ($1 == "\n" ? 1 : 0) } - (code.hasSuffix("\n") ? 1 : 0))
    }

    private var gutter: String {
        (1...lineCount).map(String.init).joined(separator: "\n")
    }

    private var permitsRichRendering: Bool {
        code.utf8.count <= Self.maximumHighlightedBytes
    }

    var body: some View {
        // Let a fence take the height its content needs in chat. Only long lines scroll; nesting
        // a vertical scroller inside the transcript made both reading and scrolling feel sluggish.
        ScrollView(.horizontal, showsIndicators: true) {
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
        }
    }
    @ViewBuilder
    private var highlightedText: some View {
        if let language = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !language.isEmpty {
            if language == "vue" {
                VueCodeText(code: code)
            } else {
                CodeText(code).highlightMode(.languageAlias(language))
            }
        } else {
            CodeText(code)
        }
    }

}
