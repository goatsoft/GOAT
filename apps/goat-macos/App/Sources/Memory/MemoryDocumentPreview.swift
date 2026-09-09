import MarkdownUI
import Memory
import SwiftUI

/// A read-only memory-document dialog. Internal wiki links stay inside this one preview, so
/// browsing a memory trail never produces a stack of modal windows.
struct MemoryDocumentPreview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let projectID: UUID?
    @State private var document: MemoryBrowserDocument
    @State private var backStack: [MemoryBrowserDocument] = []
    @State private var linkTargets: [String: MemoryEntryID] = [:]
    @State private var isNavigating = false
    @State private var navigationError: String?
    @State private var navigationTask: Task<Void, Never>?
    @State private var markdownID = UUID()

    init(document: MemoryBrowserDocument, projectID: UUID?) {
        self.projectID = projectID
        _document = State(initialValue: document)
    }

    var body: some View {
        GOATDialogShell(closeAction: { dismiss() }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    if !backStack.isEmpty {
                        Button {
                            goBack()
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .buttonStyle(SecondaryChipButtonStyle())
                        .accessibilityHint("Return to the previous memory document")
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Memory document", systemImage: "doc.text.magnifyingglass")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(document.entry.displayTitle)
                            .font(.title2.weight(.semibold))
                            .lineLimit(2)
                        Text(document.entry.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 12)
                    if isNavigating { GoatLoadingIndicator().controlSize(.small) }
                }
                .padding(20)
                .padding(.trailing, 28)

                Divider()

                ScrollView {
                    PreparedMarkdownView(
                        id: markdownID,
                        source: MemoryDocumentLinks.renderedMarkdown(
                            document.content, linkTargets: linkTargets),
                        fallbackFontSize: model.chatFontSize
                    ) { content in
                        Markdown(content)
                            .markdownImageProvider(BlockedMarkdownImageProvider())
                            .markdownInlineImageProvider(BlockedMarkdownInlineImageProvider())
                            .goatMarkdownStyle(fontSize: model.chatFontSize)
                            .environment(
                                \.openURL,
                                OpenURLAction { url in open(url) }
                            )
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            }
            .frame(minWidth: 620, minHeight: 500)
        }
        .accessibilityLabel("Memory document")
        .task(id: projectID) { await loadLinkTargets() }
        .alert("Couldn’t open memory document", isPresented: navigationErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(navigationError ?? "Unknown error")
        }
        .onDisappear {
            navigationTask?.cancel()
            navigationTask = nil
        }
    }

    private var navigationErrorPresented: Binding<Bool> {
        Binding(get: { navigationError != nil }, set: { if !$0 { navigationError = nil } })
    }

    private func loadLinkTargets() async {
        do {
            linkTargets = try await model.memory.browserLinkTargets(forProjectID: projectID)
        } catch {
            // A document remains readable when its optional link index cannot be loaded.
            linkTargets = [:]
        }
    }

    private func open(_ url: URL) -> OpenURLAction.Result {
        guard let target = MemoryDocumentLinks.target(for: url, in: linkTargets) else {
            return JudasLinks.open(url)
        }
        navigate(to: target)
        return .handled
    }

    private func navigate(to id: MemoryEntryID) {
        guard id != document.entry.id else { return }
        navigationTask?.cancel()
        isNavigating = true
        navigationTask = Task { @MainActor in
            defer { isNavigating = false }
            do {
                let next = try await model.memory.browserDocument(id, projectID: projectID)
                guard !Task.isCancelled else { return }
                backStack.append(document)
                document = next
                markdownID = UUID()
            } catch {
                guard !Task.isCancelled else { return }
                navigationError = error.localizedDescription
            }
        }
    }

    private func goBack() {
        navigationTask?.cancel()
        isNavigating = false
        if let previous = backStack.popLast() {
            document = previous
            markdownID = UUID()
        }
    }
}

/// Converts known `[[wiki-links]]` into normal Markdown links and resolves ordinary relative
/// Markdown links such as `(qwen-retrieval.md)`. Unknown and external links keep MarkdownUI's
/// default behaviour.
enum MemoryDocumentLinks {
    private static let scheme = "goat-memory"

    static func renderedMarkdown(_ content: String, linkTargets: [String: MemoryEntryID]) -> String {
        var result: [String] = []
        var inFence = false
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if isFence(line) {
                inFence.toggle()
                result.append(line)
            } else if inFence {
                result.append(line)
            } else {
                result.append(renderVisibleLine(line, linkTargets: linkTargets))
            }
        }
        return result.joined(separator: "\n")
    }

    static func target(for url: URL, in linkTargets: [String: MemoryEntryID]) -> MemoryEntryID? {
        if url.scheme?.lowercased() == scheme, url.host?.lowercased() == "entry" {
            let rawID = String(url.path.drop(while: { $0 == "/" })).removingPercentEncoding ?? url.path
            let target = MemoryEntryID(rawValue: rawID)
            return linkTargets.values.contains(target) ? target : nil
        }
        guard url.scheme == nil else { return nil }
        let path = url.path.removingPercentEncoding ?? url.path
        guard !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return linkTargets[name]
    }

    private static func destination(for target: MemoryEntryID) -> URL? {
        URL(string: "\(scheme)://entry/\(target.rawValue)")
    }

    /// The preview uses the same conservative relationship rule as the graph: examples in code
    /// are code, not navigation. This is deliberately a tiny recognizer rather than Markdown
    /// parsing or a renderer-dependent source rewrite.
    private static func renderVisibleLine(
        _ line: String,
        linkTargets: [String: MemoryEntryID]
    ) -> String {
        var result = ""
        var index = line.startIndex
        var inlineDelimiter: String?
        while index < line.endIndex {
            if line[index] == "`" {
                let delimiterStart = index
                while index < line.endIndex, line[index] == "`" { index = line.index(after: index) }
                let delimiter = String(line[delimiterStart..<index])
                if inlineDelimiter == delimiter {
                    inlineDelimiter = nil
                } else if inlineDelimiter == nil {
                    inlineDelimiter = delimiter
                }
                result += delimiter
                continue
            }
            guard inlineDelimiter == nil,
                line[index...].hasPrefix("[["),
                let close = line[line.index(index, offsetBy: 2)...].range(of: "]]"),
                index < close.lowerBound
            else {
                result.append(line[index])
                index = line.index(after: index)
                continue
            }
            let name = String(line[line.index(index, offsetBy: 2)..<close.lowerBound])
            if let target = linkTargets[name], let url = destination(for: target) {
                result += "[\(name)](\(url.absoluteString))"
            } else {
                result.append(contentsOf: line[index..<close.upperBound])
            }
            index = close.upperBound
        }
        return result
    }

    private static func isFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }
}
