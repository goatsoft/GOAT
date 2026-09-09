import Caprine
import Foundation

// MARK: - HTML shells

public enum PaddockHTML {
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func svgShell(_ svg: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"></head>
        <body style="margin:0;display:grid;place-items:center;min-height:100vh;background:transparent">
        \(svg)
        </body></html>
        """
    }

    public static func mermaidShell(_ code: String, dark: Bool, theme: ThemeSpec? = nil) -> String {
        let spec = theme ?? (dark ? ThemeCatalog.midnight : ThemeCatalog.light)
        let background = cssColor(spec.bg, fallback: dark ? "#0A0B14" : "#F5F6FA")
        let foreground = cssColor(spec.ink, fallback: dark ? "#E9ECF5" : "#1A1C26")
        let tint = cssColor(spec.tint, fallback: dark ? "#3AA0FF" : "#2563C8")
        let surface = cssColor(spec.surface, fallback: background)
        let variables: [String: Any] = [
            "darkMode": dark, "background": background, "primaryColor": surface,
            "primaryTextColor": foreground, "primaryBorderColor": tint,
            "lineColor": tint, "secondaryColor": surface, "tertiaryColor": background,
            "textColor": foreground, "fontFamily": "-apple-system, sans-serif",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: variables, options: [.sortedKeys])) ?? Data()
        let configuration = String(data: data, encoding: .utf8) ?? "{}"
        return """
                <!doctype html><html><head><meta charset="utf-8">
                <script src="mermaid.min.js"></script>
                <style>
                html,body{margin:0;min-height:100%;background:\(background);color:\(foreground);font-family:-apple-system}
                body{display:grid;place-items:center;padding:24px;box-sizing:border-box}
                .mermaid{max-width:100%;overflow:auto}
                </style>
                </head><body>
                <pre class="mermaid">
                \(escape(code))
                </pre>
                <script>
                window.addEventListener('load', async () => {
                  try {
                    mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', maxTextSize: 100000, maxEdges: 1000, suppressErrorRendering: true, theme: 'base', themeVariables: \(configuration) });
                    await mermaid.run({ nodes: document.querySelectorAll('.mermaid') });
                  } catch (error) {
                    document.body.replaceChildren();
                    const failure = document.createElement('p');
                    failure.textContent = 'Could not render this diagram. Open Source to inspect the Mermaid syntax.';
                    document.body.append(failure);
                  }
                });
                </script>
                </body></html>
            """
    }
    /// Presentation-only scrollbars. Source/copy/export retain the original artifact bytes.
    public static func scrollbarStyle(theme: ThemeSpec) -> String {
        let thumb = cssColor(theme.muted, fallback: "#858595")
        let hover = cssColor(theme.tint, fallback: "#3AA0FF")
        return """
            <style id="goat-preview-scrollbars">
            * { scrollbar-width: thin !important; scrollbar-color: \(thumb) transparent !important; }
            ::-webkit-scrollbar { width: 8px; height: 8px; }
            ::-webkit-scrollbar-track, ::-webkit-scrollbar-corner { background: transparent; }
            ::-webkit-scrollbar-thumb { background: \(thumb); border-radius: 8px; border: 2px solid transparent; background-clip: padding-box; }
            ::-webkit-scrollbar-thumb:hover { background-color: \(hover); }
            </style>
            """
    }

    /// Theme files are user data; only literal RGB colors may enter an HTML shell.
    private static func cssColor(_ value: String, fallback: String) -> String {
        guard value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else { return fallback }
        return value
    }
}
