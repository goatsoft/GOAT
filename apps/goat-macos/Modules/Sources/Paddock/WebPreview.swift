import AppKit
import JUDAS
import SwiftUI
import WebKit
import os.signpost

// MARK: - Sandboxed web preview (viewer, not a browser - ADR-0010)

/// Ephemeral WKWebView for artifact previews. With `offGrid` on, a content rule list
/// blocks every request except local content (ADR-0015) - bundled assets like
/// mermaid.min.js still load, so rendering works with the network yanked.
/// Source mode blanks the document but keeps this artifact's web view shell for reuse.
/// A policy change replaces the web view, so an old online document cannot keep running
/// while the off-grid rule list compiles for its replacement.
public struct WebPreview: View {
    public let html: String
    public var offGrid = false
    public var mode: JudasMode = .configured
    public var bundledScripts = false
    public var isActive = true
    public var onContentHeight: (@MainActor (CGFloat) -> Void)?
    public var onSnapshot: (@MainActor (NSImage) -> Void)?

    public init(
        html: String, offGrid: Bool = false, mode: JudasMode = .configured,
        bundledScripts: Bool = false, isActive: Bool = true,
        onContentHeight: (@MainActor (CGFloat) -> Void)? = nil,
        onSnapshot: (@MainActor (NSImage) -> Void)? = nil
    ) {
        self.html = html
        self.offGrid = offGrid
        self.mode = mode
        self.bundledScripts = bundledScripts
        self.isActive = isActive
        self.onContentHeight = onContentHeight
        self.onSnapshot = onSnapshot
    }

    public var body: some View {
        WebPreviewContent(
            html: html, offGrid: offGrid, mode: mode, bundledScripts: bundledScripts, isActive: isActive,
            onContentHeight: onContentHeight, onSnapshot: onSnapshot
        )
        .id("\(offGrid)-\(mode.rawValue)-\(bundledScripts)")
    }
}

private struct WebPreviewContent: NSViewRepresentable {
    let mode: JudasMode
    let bundledScripts: Bool
    let html: String
    let isActive: Bool
    var offGrid = false
    let onContentHeight: (@MainActor (CGFloat) -> Void)?
    let onSnapshot: (@MainActor (NSImage) -> Void)?

    init(
        html: String, offGrid: Bool, mode: JudasMode, bundledScripts: Bool, isActive: Bool,
        onContentHeight: (@MainActor (CGFloat) -> Void)?, onSnapshot: (@MainActor (NSImage) -> Void)?
    ) {
        self.html = html
        self.offGrid = offGrid
        self.mode = mode
        self.bundledScripts = bundledScripts
        self.isActive = isActive
        self.onContentHeight = onContentHeight
        self.onSnapshot = onSnapshot
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var revoked = false
        var active = false
        private static let log = OSLog(subsystem: "dev.leet.goat", category: .pointsOfInterest)
        var lastHTML: String?
        var lastOffGrid: Bool?
        var generation: UInt64 = 0
        var policyTask: Task<Void, Never>?
        var offGridRule: WKContentRuleList?
        var cancellation: JudasRegistration?
        var documentNavigation: WKNavigation?
        var onContentHeight: (@MainActor (CGFloat) -> Void)?
        var onSnapshot: (@MainActor (NSImage) -> Void)?

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = action.request.url else {
                decisionHandler(.cancel)
                return
            }
            let decision = PaddockNavigationPolicy.decide(
                url: url, userLink: action.navigationType == .linkActivated,
                mainFrame: action.targetFrame?.isMainFrame ?? true,
                offGrid: lastOffGrid ?? true, bundleURL: Bundle.main.resourceURL)
            let web = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            let permitted =
                !web || (decision != .cancel && Judas.shared.authorizePreview(url, offGrid: lastOffGrid ?? true))
            if web && decision == .cancel { Judas.shared.record(.preview, .denied, url: url) }
            guard permitted else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(decision == .allow ? .allow : .cancel)
            if decision == .external { NSWorkspace.shared.open(url) }
        }

        func revoke(_ view: WKWebView) {
            revoked = true
            documentNavigation = nil
            generation &+= 1
            policyTask?.cancel()
            policyTask = nil
            view.stopLoading()
            view.loadHTMLString(WebPreviewContent.blankPage, baseURL: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            os_signpost(.event, log: Self.log, name: "PreviewNavigationFinished")
            guard active, !revoked, let documentNavigation, navigation === documentNavigation else { return }
            let currentGeneration = generation
            if onContentHeight != nil {
                // Only read geometry. Preview content cannot supply code to this expression.
                webView.evaluateJavaScript(
                    """
                    (() => {
                      const body = document.body;
                      if (!body) return 0;
                      const top = body.getBoundingClientRect().top;
                      return Math.max(1, ...Array.from(body.children)
                        .filter(e => !['SCRIPT', 'STYLE'].includes(e.tagName))
                        .map(e => e.getBoundingClientRect().bottom - top));
                    })()
                    """
                ) { [weak self] value, _ in
                    guard let self, self.active, !self.revoked, self.generation == currentGeneration,
                        let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0
                    else { return }
                    self.onContentHeight?(CGFloat(number.doubleValue))
                }
            }
            if onSnapshot != nil {
                webView.takeSnapshot(with: nil) { [weak self] image, _ in
                    guard let self, self.active, !self.revoked, self.generation == currentGeneration,
                        let image
                    else { return }
                    self.onSnapshot?(image)
                }
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            showFailure(in: webView)
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            showFailure(in: webView)
        }

        private func showFailure(in view: WKWebView) {
            view.loadHTMLString(
                "<p style='font-family:-apple-system'>Preview unavailable. Use Reload to try again, or open Source.</p>",
                baseURL: nil)
        }
    }

    private static let blankPage = "<!doctype html><meta charset=\"utf-8\"><title>Off-grid</title>"

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript =
            (mode == .configured && !offGrid) || bundledScripts
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.cancellation = JudasRegistration { [weak view, weak coordinator = context.coordinator] in
            Task { @MainActor in
                guard let view else { return }
                coordinator?.revoke(view)
            }
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onContentHeight = onContentHeight
        context.coordinator.onSnapshot = onSnapshot
        guard !context.coordinator.revoked else { return }
        guard isActive else {
            if context.coordinator.active {
                context.coordinator.active = false
                context.coordinator.generation &+= 1
                context.coordinator.policyTask?.cancel()
                context.coordinator.policyTask = nil
                context.coordinator.lastHTML = nil
                view.stopLoading()
                view.loadHTMLString(Self.blankPage, baseURL: nil)
            }
            return
        }
        context.coordinator.active = true
        guard context.coordinator.lastHTML != html || context.coordinator.lastOffGrid != offGrid
        else { return }
        context.coordinator.generation &+= 1
        let generation = context.coordinator.generation
        context.coordinator.policyTask?.cancel()
        context.coordinator.policyTask = nil
        context.coordinator.lastHTML = html
        context.coordinator.lastOffGrid = offGrid
        let html = Judas.previewCSP(mode: mode, offGrid: offGrid, bundledScripts: bundledScripts) + self.html
        Judas.shared.recordPreviewPolicy(offGrid: offGrid, bundledScripts: bundledScripts)
        if Judas.previewRules(mode: mode, offGrid: offGrid) != nil {
            // Retire the old document while policy is prepared. Shared compiled rules never
            // retain web views, documents, cookies or connection permissions.
            view.stopLoading()
            view.configuration.userContentController.removeAllContentRuleLists()
            view.loadHTMLString(Self.blankPage, baseURL: nil)
            if let list = context.coordinator.offGridRule {
                view.configuration.userContentController.add(list)
                context.coordinator.documentNavigation = view.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
                return
            }

            context.coordinator.policyTask = Task { @MainActor [weak view, weak coordinator = context.coordinator] in
                let list = try? await PreviewRuleCache.shared.rule(mode: mode, offGrid: offGrid)
                guard
                    !Task.isCancelled,
                    let view,
                    let coordinator,
                    coordinator.generation == generation,
                    coordinator.lastOffGrid == offGrid,
                    coordinator.lastHTML == self.html
                else { return }
                coordinator.policyTask = nil
                if let list {
                    coordinator.offGridRule = list
                    view.configuration.userContentController.removeAllContentRuleLists()
                    view.configuration.userContentController.add(list)
                    coordinator.documentNavigation = view.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
                } else {
                    // If the policy can't compile, fail closed: show nothing rather than leak.
                    view.loadHTMLString(
                        "<p style=\"font-family:-apple-system;color:gray\">Off-grid policy unavailable - preview disabled.</p>",
                        baseURL: nil)
                }
            }
        } else {
            view.stopLoading()
            view.configuration.userContentController.removeAllContentRuleLists()
            context.coordinator.documentNavigation = view.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.revoke(view)
        coordinator.cancellation = nil
        view.navigationDelegate = nil
        view.uiDelegate = nil
        // Keep rules installed until WebKit releases the retired document and view.
    }
}
