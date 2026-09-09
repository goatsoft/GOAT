import Foundation

/// Built-in engine defaults for Settings: endpoint, description, model management and
/// metadata discovery (ADR-0017, ADR-0020). Generation uses the configured `EngineRequestStyle`.
public struct EnginePreset: Identifiable, Hashable, Sendable {
    /// How the user adds or removes this engine's models.
    public enum ModelManagement: Hashable, Sendable {
        /// A native app to open, if installed at `bundlePath` (e.g. oMLX).
        case app(bundlePath: String, label: String)
        /// A shell command, shown as a copyable hint (e.g. `ollama pull <model>`).
        case command(String)
        /// MTPLX can be managed by its native app when GOAT targets the same Mac. Remote servers
        /// are deliberately managed on their host: a browser link cannot safely forward GOAT's
        /// saved bearer key to the dashboard.
        case mtplx(bundlePath: String)
        /// Nothing in-app: models are chosen when the server is launched.
        case none
    }

    public let id: String
    public let name: String
    /// Root URL the server listens on; `nil` for `custom` (the user types their own).
    public let url: String?
    public let blurb: String
    public let management: ModelManagement
    public let recommended: Bool

    public init(
        id: String, name: String, url: String?, blurb: String,
        management: ModelManagement, recommended: Bool = false
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.blurb = blurb
        self.management = management
        self.recommended = recommended
    }

    /// The label for the app-management case; `nil` for command/none.
    public var appLabel: String? {
        if case .app(_, let label) = management { return label }
        return nil
    }

    /// Selects only documented, metadata-only provider probes. Custom endpoints stay generic.
    public var metadataDialect: EngineMetadataDialect {
        switch id {
        case "lmstudio": .lmStudio
        case "ollama": .ollama
        case "llamacpp": .llamaCpp
        default: .generic
        }
    }

    /// Conventional endpoints are scoped by provider so discovery cannot attach a
    /// provider-specific metadata adapter to an unrelated service on another port.
    public var conventionalDiscoveryURLs: [String] {
        switch id {
        case "omlx", "vmlx":
            ["http://127.0.0.1:8000", "http://127.0.0.1:8001"]
        case "mtplx":
            ["http://127.0.0.1:8000"]
        case "ollama":
            ["http://127.0.0.1:11434"]
        case "lmstudio":
            ["http://127.0.0.1:1234"]
        case "llamacpp":
            ["http://127.0.0.1:8080"]
        default:
            [
                "http://127.0.0.1:8000", "http://127.0.0.1:8001",
                "http://127.0.0.1:11434",
            ]
        }
    }
}

extension EnginePreset {
    public static let all: [EnginePreset] = [
        EnginePreset(
            id: "omlx", name: "oMLX", url: "http://127.0.0.1:8000",
            blurb: "Local MLX inference for Apple Silicon.",
            management: .app(bundlePath: "/Applications/oMLX.app", label: "Manage Models in oMLX…"),
            recommended: true),
        EnginePreset(
            id: "vmlx", name: "vMLX", url: "http://127.0.0.1:8000",
            blurb: "MLX server on the same port family as oMLX.",
            management: .app(bundlePath: "/Applications/vMLX.app", label: "Manage Models in vMLX…")),
        EnginePreset(
            id: "mtplx", name: "MTPLX", url: "http://127.0.0.1:8000",
            blurb: "MTP-accelerated MLX inference for Apple Silicon.",
            management: .mtplx(bundlePath: "/Applications/MTPLX.app")),
        EnginePreset(
            id: "ollama", name: "Ollama", url: "http://127.0.0.1:11434",
            blurb: "OpenAI-compatible on :11434. Pull models from the CLI.",
            management: .command("ollama pull <model>")),
        EnginePreset(
            id: "lmstudio", name: "LM Studio", url: "http://127.0.0.1:1234",
            blurb: "Start its local server, then point GOAT here.",
            management: .app(bundlePath: "/Applications/LM Studio.app", label: "Open LM Studio…")),
        EnginePreset(
            id: "llamacpp", name: "llama.cpp server", url: "http://127.0.0.1:8080",
            blurb: "Run llama-server with your GGUF model.",
            management: .command("llama-server -m <model.gguf> --port 8080")),
        .custom,
    ]

    /// The catch-all: any OpenAI-compatible endpoint, URL typed by hand.
    public static let custom = EnginePreset(
        id: "custom", name: "Custom…", url: nil,
        blurb: "Any local server speaking the OpenAI chat-completions dialect.",
        management: .none)

    public static var recommended: EnginePreset { all.first { $0.recommended } ?? custom }

    /// The preset for `id`, falling back to the recommended one when unknown/nil.
    public static func with(id: String?) -> EnginePreset {
        all.first { $0.id == id } ?? recommended
    }
}
