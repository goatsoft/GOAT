import AppKit
import Bleet
import Caprine
import Foundation
import MarkdownUI
import Network
import SwiftUI
import WebKit
import XCTest

@testable import GOAT
@testable import JUDAS
@testable import Paddock

final class PaddockTests: XCTestCase {
    func testInitialDocumentAcceptsTheCanonicalBundleDirectoryOnly() throws {
        let app = URL(fileURLWithPath: "/Applications/GOAT.app/", isDirectory: true)
        let bundle = try XCTUnwrap(URL(string: "Contents/Resources/", relativeTo: app))
        let request = try XCTUnwrap(URL(string: bundle.absoluteString))
        XCTAssertEqual(
            PaddockNavigationPolicy.decide(
                url: request, userLink: false, mainFrame: true, offGrid: true, bundleURL: bundle), .allow)
        for path in ["private.html", "../private.html"] {
            let other = try XCTUnwrap(URL(string: path, relativeTo: request)).absoluteURL
            XCTAssertEqual(
                PaddockNavigationPolicy.decide(
                    url: other, userLink: false, mainFrame: true, offGrid: false, bundleURL: bundle), .cancel)
        }
    }

    func testNavigationKeepsScriptsAndCustomSchemesInsideBoundary() throws {
        let remote = try XCTUnwrap(URL(string: "https://example.com/"))
        let custom = try XCTUnwrap(URL(string: "goat://action"))
        let file = URL(fileURLWithPath: "/tmp/private.html")
        for url in [remote, custom, file] {
            XCTAssertEqual(
                PaddockNavigationPolicy.decide(
                    url: url, userLink: false, mainFrame: true, offGrid: false, bundleURL: nil), .cancel)
        }
        XCTAssertEqual(
            PaddockNavigationPolicy.decide(
                url: remote, userLink: true, mainFrame: true, offGrid: false, bundleURL: nil), .external)
        XCTAssertEqual(
            PaddockNavigationPolicy.decide(
                url: custom, userLink: true, mainFrame: true, offGrid: false, bundleURL: nil), .cancel)
        XCTAssertEqual(
            PaddockNavigationPolicy.decide(url: remote, userLink: true, mainFrame: true, offGrid: true, bundleURL: nil),
            .cancel)
        XCTAssertEqual(
            PaddockNavigationPolicy.decide(
                url: remote, userLink: false, mainFrame: false, offGrid: true, bundleURL: nil), .cancel)
    }

    func testOffGridLoopbackChecksWholeHost() throws {
        for host in ["localhost", "127.0.0.1"] {
            let local = try XCTUnwrap(URL(string: "http://\(host):8000/"))
            XCTAssertEqual(
                PaddockNavigationPolicy.decide(
                    url: local, userLink: false, mainFrame: false, offGrid: true, bundleURL: nil), .allow)
            let spoof = try XCTUnwrap(URL(string: "http://\(host).example.com/"))
            XCTAssertEqual(
                PaddockNavigationPolicy.decide(
                    url: spoof, userLink: false, mainFrame: false, offGrid: true, bundleURL: nil), .cancel)
        }
    }

    func testScrollbarThemeCannotInjectMarkup() {
        var theme = ThemeCatalog.midnight
        theme.muted = "</style><script>bad()</script>"
        theme.tint = "url(https://example.com/pixel)"
        let css = PaddockHTML.scrollbarStyle(theme: theme)
        XCTAssertFalse(css.contains("<script>"))
        XCTAssertFalse(css.contains("https:"))
        XCTAssertTrue(css.contains("#858595"))
    }

    func testHTMLCacheUpdatesScrollbarThemeWithoutChangingSource() async throws {
        let cache = PaddockDocumentCache()
        let artifact = PaddockArtifact(kind: .html, content: "<h1>Goats</h1>")
        var theme = ThemeCatalog.midnight
        theme.muted = "#123456"
        let first = await cache.prepare(artifact, theme: theme, dark: true)
        theme.muted = "#654321"
        let second = await cache.prepare(artifact, theme: theme, dark: true)
        XCTAssertTrue(first?.contains("#123456") == true)
        XCTAssertTrue(second?.contains("#654321") == true)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(artifact.content, "<h1>Goats</h1>")
    }

    func testMermaidSourceCannotBreakOutOfTextElement() {
        let html = PaddockHTML.mermaidShell("</pre><script>alert('bad')</script>", dark: false)
        XCTAssertFalse(html.contains("</pre><script>alert"))
        XCTAssertTrue(html.contains("&lt;/pre&gt;&lt;script&gt;"))
        XCTAssertTrue(html.contains("securityLevel: 'strict'"))
    }
}

@MainActor
final class PaddockWebRenderingTests: XCTestCase {
    func testPreviewRulesShareConcurrentCompilationAndPartitionBlockedPolicy() async throws {
        let cache = PreviewRuleCache()
        async let first = cache.rule(mode: .localNetworksOnly, offGrid: false)
        async let second = cache.rule(mode: .configured, offGrid: true)
        let (a, b) = try await (first, second)
        XCTAssertTrue(a === b)
        XCTAssertEqual(cache.compilationCount, 1)
        let blocked = try await cache.rule(mode: .blocked, offGrid: true)
        XCTAssertFalse(a === blocked)
        XCTAssertEqual(cache.compilationCount, 2)
        let unrestricted = try await cache.rule(mode: .configured, offGrid: false)
        XCTAssertNil(unrestricted)
        XCTAssertEqual(cache.compilationCount, 2)
    }

    func testSourceModeBlanksDocumentAndReusesOnlyTheWebViewShell() async throws {
        let html = "<p id='ready'>Preview</p>"
        let host = NSHostingView(rootView: WebPreview(html: html, offGrid: true))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        for _ in 0..<100 {
            if let web = findWebView(host),
                (try? await web.evaluateJavaScript("document.getElementById('ready') !== null") as? Bool) == true
            {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let original = try XCTUnwrap(findWebView(host))
        host.rootView = WebPreview(html: html, offGrid: true, isActive: false)
        for _ in 0..<100 {
            if (try? await original.evaluateJavaScript("document.title") as? String) == "Off-grid" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let hiddenTitle = try await original.evaluateJavaScript("document.title") as? String
        XCTAssertEqual(hiddenTitle, "Off-grid")
        host.rootView = WebPreview(html: html, offGrid: true, isActive: true)
        var restored = false
        for _ in 0..<100 {
            if (try? await original.evaluateJavaScript("document.getElementById('ready') !== null") as? Bool) == true {
                restored = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(restored)
        XCTAssertTrue(findWebView(host) === original)
        let priorMode = Judas.shared.mode
        defer { Judas.shared.setMode(priorMode) }
        Judas.shared.setMode(.blocked)
        for _ in 0..<100 {
            if (try? await original.evaluateJavaScript("document.title") as? String) == "Off-grid" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        host.rootView = WebPreview(html: "<p id='stale'>Must not reload</p>", offGrid: true)
        try await Task.sleep(for: .milliseconds(50))
        let stale = try await original.evaluateJavaScript("document.getElementById('stale') !== null") as? Bool
        XCTAssertEqual(stale, false)
    }

    func testJudasContentRulesCompileForEveryRestrictedMode() async throws {
        for mode in JudasMode.allCases {
            for offGrid in [false, true] {
                guard let rules = Judas.previewRules(mode: mode, offGrid: offGrid) else { continue }
                let compiled = try await WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: "goat.test.judas.\(mode.rawValue).\(offGrid)", encodedContentRuleList: rules)
                XCTAssertNotNil(compiled)
            }
        }
    }

    func testRestrictedHTMLDisablesArbitraryScriptsAndInstallsCSP() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(
            rootView: WebPreview(
                html: "<p id='ready'>Safe preview</p><script>document.body.dataset.executed='yes'</script>",
                offGrid: false, mode: .blocked
            ).frame(width: 400, height: 300))
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        var web: WKWebView?
        for _ in 0..<100 {
            if let candidate = findWebView(host),
                (try? await candidate.evaluateJavaScript("document.getElementById('ready') !== null") as? Bool) == true
            {
                web = candidate
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let view = try XCTUnwrap(web)
        XCTAssertFalse(view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        let executed = try await view.evaluateJavaScript("document.body.dataset.executed || 'no'") as? String
        XCTAssertEqual(executed, "no")
        let policy = try await view.evaluateJavaScript("document.querySelector('meta[http-equiv]').content") as? String
        XCTAssertTrue(policy?.contains("connect-src 'none'") == true)
    }

    func testJudasResourcePolicyControlsActualLoopbackImages() async throws {
        for mode in JudasMode.allCases {
            let fixture = try PreviewImageFixture()
            defer { fixture.stop() }
            let url = try await fixture.url()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(
                rootView: WebPreview(
                    html: "<img id='probe' src='\(url.absoluteString)'>", offGrid: false, mode: mode
                )
                .frame(width: 400, height: 300))
            window.contentView = host
            defer {
                window.contentView = nil
                window.close()
            }
            host.layoutSubtreeIfNeeded()
            var completed = false
            for _ in 0..<100 {
                if let web = findWebView(host),
                    (try? await web.evaluateJavaScript("document.getElementById('probe')?.complete === true") as? Bool)
                        == true
                {
                    completed = true
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(completed)
            XCTAssertEqual(fixture.requestCount, mode == .blocked ? 0 : 1)
        }
    }

    func testBundledMermaidRendersWithOffGridPolicy() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(
            rootView: WebPreview(
                html: PaddockHTML.mermaidShell("graph TD; A[Start] --> B[Done]", dark: false), offGrid: true,
                bundledScripts: true
            ).frame(width: 480, height: 320))
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        var rendered = false
        for _ in 0..<100 {
            if let web = findWebView(host),
                let value = try? await web.evaluateJavaScript("document.querySelector('.mermaid svg') !== null")
                    as? Bool, value
            {
                rendered = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(rendered, "Bundled Mermaid must render in the actual policy-gated web view")
        let oldWebView = try XCTUnwrap(findWebView(host))
        host.rootView = WebPreview(
            html: PaddockHTML.mermaidShell("graph TD; A[Start] --> B[Done]", dark: false), offGrid: false,
            bundledScripts: true
        ).frame(width: 480, height: 320)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<50 {
            if let current = findWebView(host), current !== oldWebView { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let replacement = try XCTUnwrap(findWebView(host))
        XCTAssertFalse(replacement === oldWebView, "A policy change must retire the previous document and web view")

    }

    private func findWebView(_ view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.compactMap { findWebView($0) }.first
    }
}

// Test-only loopback fixture. Mutable state is locked; Network objects are thread-safe.
private final class PreviewImageFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "goat.tests.preview-image")
    private let lock = NSLock()
    private var count = 0
    private var connections: [NWConnection] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] _, _, _, _ in
                self?.lock.withLock { self?.count += 1 }
                let reply = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
    }

    var requestCount: Int { lock.withLock { count } }

    func url() async throws -> URL {
        for _ in 0..<200 {
            if let port = listener.port, port.rawValue > 0 {
                return try XCTUnwrap(URL(string: "http://127.0.0.1:\(port.rawValue)/pixel"))
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw JudasError.denied
    }

    func stop() {
        listener.cancel()
        let open = lock.withLock { connections }
        for connection in open { connection.cancel() }
    }
}

final class ChatArtifactSyntaxTests: XCTestCase {
    func testFenceMetadataKeepsHTMLAndSVGPreviewable() {
        XCTAssertEqual(PaddockArtifact.kind(forFenceLanguage: "HTML title=goats.html"), .html)
        XCTAssertEqual(PaddockArtifact.kind(forFenceLanguage: "image/svg+xml"), .svg)
        XCTAssertEqual(PaddockArtifact.kind(forFenceLanguage: "swift"), .code(language: "swift"))
    }

    func testStandaloneDocumentGetsAFenceThatPreservesEmbeddedBackticks() {
        let html = "<!doctype html><html><body><pre>```swift\nlet goats = 7\n```</pre></body></html>"
        let normalized = GOATMarkdownSyntax.normalized(html)
        XCTAssertTrue(normalized.hasPrefix("````html\n"))
        XCTAssertTrue(normalized.contains(html))
        XCTAssertTrue(normalized.hasSuffix("\n````"))
        let existing = "Before\n```html\n<main>Goats</main>\n```\nAfter"
        XCTAssertEqual(GOATMarkdownSyntax.normalized(existing), existing)
    }
}

@MainActor final class ChatArtifactPreviewTests: XCTestCase {
    func testStreamingArtifactsStaySourceOnlyUntilTheResponseFinishes() async throws {
        for language in ["html", "svg"] {
            for fenced in [false, true] {
                let message = ChatMessage(role: .assistant)
                let host = NSHostingView(
                    rootView: MessageView(message: message, isLast: true, projectID: nil)
                        .environment(AppModel.shared))
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer {
                    window.contentView = nil
                    window.close()
                }
                let prefix = fenced ? "```\(language)\n" : ""
                let opening =
                    language == "html"
                    ? "<html><body><h1 id='stream-goat'>"
                    : "<svg xmlns='http://www.w3.org/2000/svg'><text id='stream-goat'>"
                let closing = language == "html" ? "</h1></body></html>" : "</text></svg>"
                let parseCount = await MarkdownRenderCache.shared.snapshot().parseCount
                for chunk in [prefix + opening + "Goat", " trails", closing + (fenced ? "\n```" : "")] {
                    message.appendStream(text: chunk, thinking: "")
                    for _ in 0..<40 {
                        host.layoutSubtreeIfNeeded()
                        if webView(in: host) != nil {
                            XCTFail("Streaming \(language), fenced=\(fenced), created a live preview")
                            return
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                let prepared = await MarkdownRenderCache.shared.snapshot().parseCount
                XCTAssertGreaterThanOrEqual(prepared - parseCount, 3, "Exercise successive rendered snapshots")

                message.complete = true
                var rendered = false
                for _ in 0..<150 {
                    host.layoutSubtreeIfNeeded()
                    if let web = webView(in: host),
                        (try? await web.evaluateJavaScript("document.getElementById('stream-goat')?.textContent")
                            as? String) == "Goat trails"
                    {
                        rendered = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(rendered, "Completed \(language), fenced=\(fenced), must render its preview")
            }
        }
    }

    func testHTMLFenceRendersAsAnInlinePaddockDocument() async throws {
        let source = "```html\n<main><h1 id='goats'>Goat Trails</h1></main>\n```"
        let host = NSHostingView(
            rootView:
                Markdown(source).goatMarkdownStyle(fontSize: 14).environment(AppModel.shared))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        var rendered = false
        for _ in 0..<150 {
            if let web = webView(in: host),
                (try? await web.evaluateJavaScript("document.getElementById('goats')?.textContent") as? String)
                    == "Goat Trails"
            {
                let width = try await web.evaluateJavaScript(
                    "getComputedStyle(document.documentElement).scrollbarWidth")
                XCTAssertEqual(width as? String, "thin")
                rendered = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(rendered, "HTML code fences must render through the inline Paddock host")
    }

    private func webView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.compactMap { webView(in: $0) }.first
    }
}
