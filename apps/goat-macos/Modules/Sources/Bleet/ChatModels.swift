import Foundation
import Inference
import Observation
import Persistence

/// ADR-0087 transcript entry kind: ordinary messages and folded compaction summaries.
public enum ChatMessageKind: String, Sendable, Equatable {
    case regular
    case compaction
}

/// One transcript entry. Mutable while streaming; `complete` seals it.
@MainActor
@Observable
public final class ChatMessage: Identifiable {
    public let id: UUID
    public let role: ChatTurn.Role
    public var text = ""
    public var thinking = ""
    /// O(1) identity for transcript following. Never derive cadence from full String counts.
    public private(set) var renderRevision: UInt64 = 0
    /// Incrementally maintained collapsed preview, avoiding a full thinking split per stream batch.
    public private(set) var thinkingTail = ""
    public var stats: GenStats?
    public private(set) var liveMetrics = LiveGenerationMetrics()
    public var error: String?
    public var complete = false
    public var attachmentPaths: [String] = []
    public var toolEvents: [ToolEventSnapshot] = []
    /// ADR-0087 message kind. A compaction row carries the folded summary in `text` and its
    /// metadata in `compaction`; the transcript shows it as a collapsible "Compacted N exchanges" row.
    public var kind: ChatMessageKind = .regular
    public var compaction: CompactionInfo?
    /// User feedback is persisted separately from the streamed message body.
    public var rating: Int?
    public var generationContext: GenerationContext?
    public var generationParameters: EffectiveGenerationParameters?
    public var generationLifecycle: String?
    public var generationSelectedEffort: String?
    public var generationFailureCategory: String?
    public var generationProvenance: GenerationProvenanceRecord?
    public var generationProvenanceUnavailable = false
    /// Session-local prompt-budget notice. It is UI metadata, never model-visible content.
    public var contextNotice: String?
    public let createdAt: Date

    // Thinking timing - session-local (not persisted); reloads show a plain "Thought".
    public var thinkingStartedAt: Date?
    public var thinkingEndedAt: Date?
    public var thinkingSeconds: Int? {
        guard let started = thinkingStartedAt else { return nil }
        let seconds = Int(((thinkingEndedAt ?? .now).timeIntervalSince(started)).rounded())
        return seconds > 0 ? seconds : nil
    }

    public init(role: ChatTurn.Role, id: UUID = UUID(), createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.createdAt = createdAt
    }

    public func appendStream(text textDelta: String, thinking thinkingDelta: String, toolInputBytes: Int = 0) {
        liveMetrics.append(bytes: textDelta.utf8.count + thinkingDelta.utf8.count + max(0, toolInputBytes), at: .now)
        guard !textDelta.isEmpty || !thinkingDelta.isEmpty else { return }
        if !thinkingDelta.isEmpty {
            thinking.append(contentsOf: thinkingDelta)
            updateThinkingTail(with: thinkingDelta)
        }
        if !textDelta.isEmpty {
            text.append(contentsOf: textDelta)
        }
        markRenderChanged()
    }

    public func restoreContent(text: String, thinking: String) {
        self.text = text
        self.thinking = thinking
        thinkingTail = Self.lastNonemptyThinkingLine(in: thinking)
        markRenderChanged()
    }

    public func markRenderChanged() {
        renderRevision &+= 1
    }

    private func updateThinkingTail(with delta: String) {
        // Only scan the prior 90-character tail plus this publication, never accumulated thought.
        let newest = Self.lastNonemptyThinkingLine(in: thinkingTail + delta)
        if !newest.isEmpty { thinkingTail = newest }
    }

    private static func lastNonemptyThinkingLine(in value: String) -> String {
        guard
            let line = value.split(whereSeparator: \.isNewline)
                .last(where: { $0.contains(where: { !$0.isWhitespace }) })
        else { return "" }
        return String(line.suffix(90))
    }
}

/// A chat and its settings. Messages load lazily on first selection.
@MainActor
@Observable
public final class ChatSession: Identifiable {
    public let id: UUID
    public var title = "New chat" {
        didSet { titleRevision &+= 1 }
    }
    public private(set) var titleRevision: UInt64 = 0
    public var hasDefaultTitle: Bool { title == "New chat" || title == "New Chat" }
    public var messages: [ChatMessage] = []
    public var effort: Effort
    public var modelID: String?
    public var projectID: UUID?
    public var pinned = false
    public var toolsEnabled = true
    public var disabledMCPServers: Set<String> = []
    public var isStreaming = false
    public var isLoadingMessages = false
    public var messagesLoaded = false
    public var messageLoadError: String?
    /// Context tokens in the last planned request or completed request+reply.
    public var lastContextTokens: Int?
    /// False when `lastContextTokens` is an estimate rather than server-reported.
    public var contextIsExact = false
    /// Window captured with the request, so switching models cannot relabel old usage.
    public var lastContextWindow: Int?
    /// False when the captured window is GOAT's conservative fallback rather than server metadata.
    public var contextWindowIsExact = false
    /// Capacity used for warning pressure. Preflight uses the input budget; completion uses the window.
    public var lastContextPressureLimit: Int?
    public var lastPromptWasTrimmed = false
    /// Ratio of the engine's exact `usage.prompt_tokens` to GOAT's raw estimate for this chat,
    /// learned per response and applied to the next plan (ADR-0085). Session-scoped; a fresh
    /// launch starts at 1.0 until the first exact usage arrives.
    public var contextCalibrationRatio: Double = 1.0
    public var contextCalibrationSamples = 0
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), effort: Effort, modelID: String?, projectID: UUID? = nil,
        createdAt: Date = .now, updatedAt: Date = .now
    ) {
        self.id = id
        self.effort = effort
        self.modelID = modelID
        self.projectID = projectID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func isMCPServerEnabled(_ name: String) -> Bool {
        toolsEnabled && !disabledMCPServers.contains(name)
    }

    public func setMCPServer(_ name: String, enabled: Bool, activeServerNames: [String]) {
        if enabled {
            if !toolsEnabled {
                disabledMCPServers.formUnion(activeServerNames)
                toolsEnabled = true
            }
            disabledMCPServers.remove(name)
        } else if toolsEnabled {
            disabledMCPServers.insert(name)
        }
    }
}
