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
        let health = await engine.health()
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
        for toolMode in [false, true] {
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
                var turns = session.messages.dropLast().map { ChatTurn(role: $0.role, text: $0.text) }
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
                    try await Task.sleep(for: .seconds(240))
                    task.cancel()
                }
                defer { timeout.cancel() }
                let result = try await task.value
                let stats = try XCTUnwrap(result.stats)
                let delivery = try XCTUnwrap(stats.delivery)
                active.stats = stats
                active.complete = true
                session.isStreaming = false
                print(
                    "THROUGHPUT_RESULT stats_open=\(inspector) tools=\(toolMode) model=\(model.id) "
                        + "server_tps=\(stats.generationTokensPerSecond ?? -1) server_ttft_s=\(stats.ttft ?? -1) "
                        + "first_output_s=\(delivery.firstOutputSeconds ?? -1) output_bytes=\(delivery.outputBytes) "
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
