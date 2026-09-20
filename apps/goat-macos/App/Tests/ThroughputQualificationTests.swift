import AppKit
import Bleet
import Foundation
import Herd
import Inference
import Persistence
import SwiftUI
import XCTest

@testable import GOAT
@testable import Shepherd

/// Opt-in synthetic workload for #38. Never reads a user transcript or executes returned tools.
/// Run with the Mac unlocked and the test window visible to qualify rendering and Stats sampling.
final class ThroughputQualificationTests: XCTestCase {
    @MainActor func testLiveDeliveryWithStatsOpenAndClosed() async throws {
        guard ProcessInfo.processInfo.environment["GOAT_LIVE_THROUGHPUT"] == "1" else {
            throw XCTSkip("Set GOAT_LIVE_THROUGHPUT=1 to use the saved engine with synthetic content")
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".goat/config")
        let config = try XCTUnwrap(try EngineStore.load(from: directory.appendingPathComponent("engines.json")))
        let profile = try XCTUnwrap(config.engines.first { $0.id == config.active })
        let credentials = try JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: directory.appendingPathComponent("credentials.json")))
        let engine = OpenAICompatEngine(
            config: EngineConfig(
                baseURL: try XCTUnwrap(URL(string: profile.url)), apiKey: credentials["engine.\(profile.id).apiKey"],
                metadataDialect: profile.preset.metadataDialect, requestStyle: profile.requestStyle))
        // A new test host may trigger the normal macOS Local Network prompt. Give the
        // owner time to accept it before diagnosing engine connectivity.
        var health = await engine.health()
        let connectionDeadline = ContinuousClock.now.advanced(by: .seconds(60))
        while !health.isOK, ContinuousClock.now < connectionDeadline {
            if case .authRequired = health { break }
            try await Task.sleep(for: .seconds(2))
            health = await engine.health()
        }
        let model = try XCTUnwrap(health.models.first { $0.id == "Qwen3.8-27B-MLX-4bit" })
        let status = await engine.runtimeStatus()
        print("THROUGHPUT_ENGINE", status?.version ?? "unknown", "active", status?.activeRequests ?? -1)
        let identity = ModelIdentity(engineProfileID: profile.id, modelID: model.id)
        let compatibility = ModelCompatibilityResolver.resolve(
            identity: identity, familyProfile: ModelFamilyRegistry.profile(for: model.id),
            generationSettingsOwner: profile.generationSettingsOwner)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goat-throughput-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ChatDatabase(path: root.appendingPathComponent("probe.sqlite").path)
        // Keep rendering load constant while varying request context independently. Use 20
        // repeats for the full-context stress case; the default still sends 24 coding turns.
        let promptRepeats = min(
            20, max(1, Int(ProcessInfo.processInfo.environment["GOAT_THROUGHPUT_PROMPT_REPEATS"] ?? "4") ?? 4))
        let toolModes =
            ProcessInfo.processInfo.environment["GOAT_THROUGHPUT_TOOL_ONLY"] == "1" ? [true] : [false, true]
        for toolMode in toolModes {
            for inspector in [false, true] {
                let session = ChatSession(effort: .trot, modelID: model.id)
                session.messagesLoaded = true
                session.messages = (0..<24).map { index in
                    let message = ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant)
                    message.restoreContent(
                        text: "Synthetic coding review \(index)\n" + String(repeating: Self.fixture, count: 20),
                        thinking: "Review the function and verify its output.")
                    message.complete = true
                    return message
                }
                let active = ChatMessage(role: .assistant)
                session.messages.append(active)
                session.isStreaming = true
                try await database.save(AppModel.shared.record(for: session))
                for (position, message) in session.messages.enumerated() {
                    try await database.save(AppModel.shared.record(for: message, in: session, position: position))
                }
                let window = NSWindow(
                    contentRect: NSRect(x: 80, y: 80, width: 1040, height: 760),
                    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(
                    rootView: HStack {
                        ChatTranscriptView(session: session).frame(width: 700)
                        if inspector { ScrollView { NerdStatsView(session: session) }.frame(width: 300) }
                    }.environment(AppModel.shared))
                window.makeKeyAndOrderFront(nil)
                defer {
                    window.contentView = nil
                    window.close()
                }
                try await Task.sleep(for: .seconds(2))
                var turns = session.messages.dropLast().enumerated().map { index, message in
                    ChatTurn(
                        role: message.role,
                        text: "Synthetic coding review \(index)\n"
                            + String(repeating: Self.fixture, count: promptRepeats))
                }
                turns.append(
                    ChatTurn(
                        role: .user,
                        text: toolMode
                            ? "Call report_result once with a short summary of the code review."
                            : "Summarize the code review in one short paragraph."))
                let request = GenerationRequest(
                    model: model.id, turns: turns, effort: .trot, maxTokens: toolMode ? 1024 : 512,
                    tools: toolMode
                        ? [
                            ToolSpec(
                                name: "report_result", description: "Report a synthetic code review; no side effects.",
                                parametersJSON:
                                    #"{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"]}"#
                            )
                        ] : [],
                    modelCapabilities: model.capabilities, compatibility: compatibility)
                let worker = ShepherdGenerationWorker(engine: engine, maxStreamRetries: 0)
                let requestStarted = Date.now
                let task = Task {
                    try await worker.stream(request) { update in
                        active.appendStream(
                            text: update.text, thinking: update.thinking, toolInputBytes: update.toolInputBytes)
                        if update.shouldCheckpoint {
                            do {
                                try await database.checkpointMessage(
                                    id: active.id.uuidString, text: active.text, thinking: active.thinking)
                            } catch {
                                XCTFail("Disposable checkpoint failed: \(error)")
                                return false
                            }
                        }
                        return true
                    }
                }
                let timeout = Task {
                    // At the observed shared-server rates, a 1024-token tool response can
                    // legitimately exceed four minutes after prompt processing.
                    try await Task.sleep(for: .seconds(toolMode ? 420 : 240))
                    task.cancel()
                }
                defer { timeout.cancel() }
                let result: ShepherdStreamResult
                do {
                    result = try await task.value
                } catch {
                    print(
                        "THROUGHPUT_INCOMPLETE stats_open=\(inspector) tools=\(toolMode) prompt_repeats=\(promptRepeats) received_bytes=\(active.liveMetrics.bytes) first_publication_s=\(active.liveMetrics.startedAt?.timeIntervalSince(requestStarted) ?? -1) received_estimate_tps=\(active.liveMetrics.tokensPerSecond(at: .now) ?? -1)"
                    )
                    throw error
                }
                let stats = try XCTUnwrap(result.stats)
                let delivery = try XCTUnwrap(stats.delivery)
                active.stats = stats
                active.complete = true
                session.isStreaming = false
                print(
                    "THROUGHPUT_RESULT stats_open=\(inspector) tools=\(toolMode) model=\(model.id) "
                        + "prompt_tokens=\(stats.promptTokens ?? -1) prompt_repeats=\(promptRepeats) server_tps=\(stats.generationTokensPerSecond ?? -1) server_ttft_s=\(stats.ttft ?? -1) "
                        + "first_output_s=\(delivery.firstOutputSeconds ?? -1) output_bytes=\(delivery.outputBytes) "
                        + "cached_tokens=\(stats.cachedPromptTokens ?? -1) prompt_s=\(delivery.serverPromptSeconds ?? -1) model_load_s=\(delivery.serverModelLoadSeconds ?? -1) "
                        + "events=\(delivery.outputEvents) max_gap_s=\(delivery.maximumOutputGap) "
                        + "max_publication_s=\(delivery.maximumPublicationSeconds) publications=\(delivery.publicationCount) "
                        + "duration_s=\(stats.duration) tools_received=\(result.toolCalls.count)")
                if toolMode {
                    XCTAssertFalse(
                        result.toolCalls.isEmpty, "Tool-buffering qualification requires an actual tool call")
                }
                XCTAssertGreaterThan(delivery.outputBytes, 0)
                XCTAssertGreaterThan(delivery.publicationCount, 0)
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static let fixture = """
        ```typescript
        export function doubled(value: number): number { return value * 2; }
        ```
        Verify empty inputs, type boundaries and test coverage before changing the implementation.

        """
}
