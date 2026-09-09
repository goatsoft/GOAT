import Foundation

/// Something the goat made that deserves better than a code fence.
public struct PaddockArtifact: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case html
        case svg
        case mermaid
        case markdown
        case code(language: String)

        public var label: String {
            switch self {
            case .html: "HTML"
            case .svg: "SVG"
            case .mermaid: "Mermaid"
            case .markdown: "Markdown"
            case .code(let language): language.isEmpty ? "Code" : language
            }
        }

        public var fileExtension: String {
            switch self {
            case .html: "html"
            case .svg: "svg"
            case .mermaid: "mmd"
            case .markdown: "md"
            case .code(let language):
                switch language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "swift": "swift"
                case "python", "py": "py"
                case "javascript", "js": "js"
                case "typescript", "ts": "ts"
                case "tsx": "tsx"
                case "jsx": "jsx"
                case "vue": "vue"
                case "json": "json"
                case "shell", "bash", "zsh", "sh": "sh"
                case "yaml", "yml": "yml"
                case "rust": "rs"
                case "go": "go"
                case "c": "c"
                case "cpp", "c++": "cpp"
                case "css": "css"
                default: "txt"
                }
            }
        }
    }

    public init(id: UUID = UUID(), kind: Kind, content: String) {
        self.id = id
        self.kind = kind
        self.content = content
    }

    public let id: UUID
    public let kind: Kind
    public let content: String

    public var isPreviewable: Bool {
        switch kind {
        case .code: false
        case .html, .svg, .mermaid, .markdown: true
        }
    }

    public var suggestedFilename: String { "goat-artifact.\(kind.fileExtension)" }

    public static func kind(forFenceLanguage language: String?) -> Kind {
        let label = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let token = label.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return switch token.lowercased() {
        case "html", "htm", "text/html": .html
        case "svg", "image/svg+xml": .svg
        case "mermaid": .mermaid
        case "markdown", "md": .markdown
        default: .code(language: language ?? "")
        }
    }
}
