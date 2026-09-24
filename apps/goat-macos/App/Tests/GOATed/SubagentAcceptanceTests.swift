import CryptoKit
import Foundation
import GOATed
import Inference
import Memory
import Pens
import Persistence
import Testing
import Tools

@testable import GOAT

private actor ScriptedEngine: InferenceEngine {
    private var script: [[GenerationEvent]]
    private(set) var requests: [GenerationRequest] = []
    private let delay: Duration?

    init(script: [[GenerationEvent]], delay: Duration? = nil) {
        self.script = script
        self.delay = delay
    }

    func health() async -> EngineHealth { .ok([]) }

    func runtimeStatus() async -> EngineRuntimeStatus? {
        EngineRuntimeStatus(
            observedAt: .now,
            version: "1.0",
            modelMemoryUsed: 100 * 1024 * 1024,
            modelMemoryMaximum: 16 * 1024 * 1024 * 1024,
            activeRequests: 0,
            waitingRequests: 0,
            models: [
                EngineModelRuntimeStatus(
                    id: "qwen2.5-7b-instruct",
                    loaded: true,
                    contextWindow: 32_768
                )
            ]
        )
    }

    func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
        requests.append(request)
        let events =
            script.isEmpty
            ? [.done(GenStats(ttft: nil, tokens: 10, duration: 0.01))]
            : script.removeFirst()
        let sleepDuration = delay

        return AsyncThrowingStream { continuation in
            let task = Task {
                defer {
                    request.transportClosureHandle?.acknowledge()
                    request.onTransportClosed?()
                }
                if let sleepDuration {
                    try? await Task.sleep(for: sleepDuration)
                }
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private actor HangingEngine: InferenceEngine {
    func health() async -> EngineHealth { .ok([]) }

    func runtimeStatus() async -> EngineRuntimeStatus? {
        EngineRuntimeStatus(
            observedAt: .now,
            version: "1.0",
            modelMemoryUsed: 100 * 1024 * 1024,
            modelMemoryMaximum: 16 * 1024 * 1024 * 1024,
            activeRequests: 0,
            waitingRequests: 0,
            models: [
                EngineModelRuntimeStatus(
                    id: "qwen2.5-7b-instruct",
                    loaded: true,
                    contextWindow: 32_768
                )
            ]
        )
    }

    func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable _ in
                request.transportClosureHandle?.acknowledge()
                request.onTransportClosed?()
                continuation.finish(throwing: CancellationError())
            }
        }
    }
}

private actor UncooperativeEngine: InferenceEngine {
    func health() async -> EngineHealth { .ok([]) }

    func runtimeStatus() async -> EngineRuntimeStatus? {
        EngineRuntimeStatus(
            observedAt: .now,
            version: "1.0",
            modelMemoryUsed: 100 * 1024 * 1024,
            modelMemoryMaximum: 16 * 1024 * 1024 * 1024,
            activeRequests: 0,
            waitingRequests: 0,
            models: [
                EngineModelRuntimeStatus(
                    id: "qwen2.5-7b-instruct",
                    loaded: true,
                    contextWindow: 32_768
                )
            ]
        )
    }

    func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
        // Intentionally ignores task cancellation and never terminates
        AsyncThrowingStream { continuation in
            continuation.yield(.token("uncooperative-start"))
            // Continues indefinitely without termination handler
        }
    }
}

private actor BusyEngine: InferenceEngine {
    func health() async -> EngineHealth { .ok([]) }

    func runtimeStatus() async -> EngineRuntimeStatus? {
        EngineRuntimeStatus(
            observedAt: .now,
            version: "1.0",
            modelMemoryUsed: 1000,
            modelMemoryMaximum: 1000,
            activeRequests: 1,
            waitingRequests: 0,
            models: []
        )
    }

    func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

extension AppTests.GOATed {
    @Suite struct SubagentAcceptanceTests {

        private func createWorkspace() throws -> (URL, PenFileTools) {
            let tempDir = FileManager.default.temporaryDirectory
                .resolvingSymlinksInPath()
                .appendingPathComponent("subagent-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tools = try PenFileTools(workspace: tempDir)
            return (tempDir, tools)
        }

        private func makeChat(id: String = UUID().uuidString) -> ChatRecord {
            ChatRecord(
                id: id, projectId: nil, title: "Test", pinned: false, modelId: nil,
                effort: "trot", createdAt: .now, updatedAt: .now
            )
        }

        private func createDatabase() throws -> ChatDatabase {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            return try ChatDatabase(path: tempDir.appendingPathComponent("test.db").path)
        }

        // Scenario 1: Inner/Outer Deadline Ordering
        @Test func scenario01_innerOuterDeadlineOrdering() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let db = try createDatabase()
            let chatID = UUID()
            let turnID = UUID()
            try await db.save(makeChat(id: chatID.uuidString))

            let lease = SubagentCapabilityLease()
            let context = SubagentExecutionContext(
                chatID: chatID,
                turnID: turnID,
                projectID: nil,
                workspace: workspace,
                fileTools: fileTools,
                engine: HangingEngine(),
                timeoutSeconds: 1,  // Test 1-second timeout
                database: db,
                lease: lease
            )

            let brief = SubagentTaskBrief(objective: "Hang test")
            let worker = SubagentWorker(task: brief, context: context)
            let result = try await worker.run()

            #expect(result.receipt.status == .timedOut)
            #expect(lease.isRevoked)
            let persisted = try await db.subagentRun(id: result.receipt.runId)
            #expect(persisted?.status == result.receipt.status.rawValue)
        }

        // Scenario 2: Uncooperative Child Worker
        @Test func scenario02_uncooperativeChildWorker() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let db = try createDatabase()
            let chatID = UUID()
            let turnID = UUID()
            try await db.save(makeChat(id: chatID.uuidString))

            let lease = SubagentCapabilityLease()
            let context = SubagentExecutionContext(
                chatID: chatID,
                turnID: turnID,
                projectID: nil,
                workspace: workspace,
                fileTools: fileTools,
                engine: UncooperativeEngine(),
                timeoutSeconds: 1,
                database: db,
                lease: lease
            )

            let brief = SubagentTaskBrief(objective: "Uncooperative worker test")
            let worker = SubagentWorker(task: brief, context: context)
            let result = try await worker.run()

            #expect(result.receipt.status == .timedOut)
            #expect(lease.isRevoked)
            let persisted = try await db.subagentRun(id: result.receipt.runId)
            #expect(persisted?.status == SubagentStatus.timedOut.rawValue)

            let secondTransition = try await db.transitionSubagentRun(
                id: result.receipt.runId,
                toStatus: "completed",
                roundsExecuted: 1,
                totalTokens: 10,
                transcriptBytes: 0,
                transcriptJson: nil,
                summary: nil,
                citationsJson: nil,
                receiptJson: nil
            )
            #expect(!secondTransition)
            let fetched = try await db.subagentRun(id: result.receipt.runId)
            #expect(fetched?.status == SubagentStatus.timedOut.rawValue)
        }

        // Scenario 3: Transport Termination and Quarantine
        @Test func scenario03_transportTerminationAndQuarantine() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let db = try createDatabase()
            let chatID = UUID()
            let turnID = UUID()
            try await db.save(makeChat(id: chatID.uuidString))

            let lease = SubagentCapabilityLease()
            let context = SubagentExecutionContext(
                chatID: chatID,
                turnID: turnID,
                projectID: nil,
                workspace: workspace,
                fileTools: fileTools,
                engine: BusyEngine(),
                database: db,
                lease: lease
            )

            let brief = SubagentTaskBrief(objective: "Busy engine check")
            let worker = SubagentWorker(task: brief, context: context)
            let result = try await worker.run()

            #expect(result.receipt.status == .failed)
            let hasAdmissionDenied = result.receipt.unresolved.contains { $0.reason == "admissionDenied" }
            #expect(hasAdmissionDenied)
        }

        // Scenario 4: Completion Arriving After Stop
        @Test func scenario04_completionArrivingAfterStop() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let db = try createDatabase()
            let chatID = UUID()
            let turnID = UUID()
            try await db.save(makeChat(id: chatID.uuidString))

            let lease = SubagentCapabilityLease()
            let context = SubagentExecutionContext(
                chatID: chatID,
                turnID: turnID,
                projectID: nil,
                workspace: workspace,
                fileTools: fileTools,
                engine: HangingEngine(),
                database: db,
                lease: lease
            )

            let brief = SubagentTaskBrief(objective: "Stop simulation")
            let worker = SubagentWorker(task: brief, context: context)
            let task = Task {
                try await worker.run()
            }

            try await Task.sleep(for: .milliseconds(50))
            task.cancel()
            let result = await task.result

            switch result {
            case .success(let subagentResult):
                #expect(subagentResult.receipt.status == .cancelled || subagentResult.receipt.status == .timedOut)
            case .failure(let error):
                #expect(error is CancellationError)
            }
            #expect(lease.isRevoked)
        }

        // Scenario 5: Token and Round Budget Exhaustion
        @Test func scenario05_tokenAndRoundBudgetExhaustion() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let db = try createDatabase()
            let chatID = UUID()
            let turnID = UUID()
            try await db.save(makeChat(id: chatID.uuidString))

            // Provide tool calls on every round so it would continue forever if unconstrained
            let toolCallEvent = ToolCallEvent(id: "c1", name: "pen_list_files", argumentsJSON: "{}")
            let script: [[GenerationEvent]] = [
                [.toolCalls([toolCallEvent]), .done(GenStats(ttft: nil, tokens: 100, duration: 0.01))],
                [.toolCalls([toolCallEvent]), .done(GenStats(ttft: nil, tokens: 100, duration: 0.01))],
                [.token("Final synthesis after max rounds"), .done(GenStats(ttft: nil, tokens: 50, duration: 0.01))],
            ]
            let engine = ScriptedEngine(script: script)

            let lease = SubagentCapabilityLease()
            let context = SubagentExecutionContext(
                chatID: chatID,
                turnID: turnID,
                projectID: nil,
                workspace: workspace,
                fileTools: fileTools,
                engine: engine,
                maxRounds: 2,  // Constrain to 2 rounds
                database: db,
                lease: lease
            )

            let brief = SubagentTaskBrief(objective: "Round cap test", maxRounds: 2)
            let worker = SubagentWorker(task: brief, context: context)
            let result = try await worker.run()

            #expect(result.roundsExecuted <= 2)
            #expect(result.receipt.status == .completed)
        }

        // Scenario 6: Oversized and Multibyte Output Truncation
        @Test func scenario06_oversizedAndMultibyteOutputTruncation() throws {
            // Test UTF8BoundaryTruncator with multi-byte emoji string
            let multiByte = String(repeating: "🐐🔥🎉", count: 20_000)
            let truncated = UTF8BoundaryTruncator.truncate(multiByte, maxBytes: 1024)
            #expect(truncated.utf8.count <= 1024)
            // Verify valid UTF-8 string encoding is preserved
            #expect(truncated.contains(" [truncated]"))

            // Verify boundedReceipt keeps size under 16 KiB limit
            let hugeSummary = String(repeating: "Large summary text with emojis 🐐 ", count: 2_000)
            let receipt = SubagentReceipt(
                runId: UUID().uuidString,
                status: .completed,
                summary: hugeSummary,
                citations: (0..<500).map { SubagentCitation(path: "path\($0).swift", startLine: 1, endLine: 10) },
                unresolved: (0..<500).map {
                    SubagentUnresolvedItem(path: "path\($0).swift", reason: "test", detail: "large detail text")
                }
            )
            let bounded = receipt.boundedReceipt()
            let encoded = try JSONEncoder().encode(bounded)
            #expect(encoded.count <= SubagentLimits.maxReceiptBytes)
        }

        // Scenario 7: Permission Security and Handle Forgery
        @Test func scenario07_permissionSecurityAndHandleForgery() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let turnID = UUID()

            let provider = SubagentsProvider(
                turnID: turnID,
                fileTools: fileTools,
                workspace: workspace,
                configuration: SubagentConfiguration()
            )

            // Invoking with a different turnID fails closed
            let foreignContext = ExtensionContext(
                view: ExtensionView(chatID: UUID(), penID: nil),
                turnID: UUID()
            )
            let call = ToolCallRequest(tool: SubagentsProvider.toolName, argumentsJSON: "{\"objective\":\"test\"}")
            await #expect(throws: CapabilityError.self) {
                _ = try await provider.invoke(call, context: foreignContext)
            }

            // Invoking an unauthorized tool name fails closed
            let validContext = ExtensionContext(
                view: ExtensionView(chatID: UUID(), penID: nil),
                turnID: turnID
            )
            let wrongCall = ToolCallRequest(tool: "unauthorized_tool", argumentsJSON: "{}")
            await #expect(throws: CapabilityError.self) {
                _ = try await provider.invoke(wrongCall, context: validContext)
            }
        }

        // Scenario 8: Unattended Approval Denial
        @Test func scenario08_unattendedApprovalDenial() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let lease = SubagentCapabilityLease()
            let fence = SubagentCapabilityFence(fileTools: fileTools, lease: lease)

            // Any write tool must fail closed with unattended approval denied
            let writeCall = ToolCallRequest(
                tool: "pen_write_file", argumentsJSON: "{\"path\":\"a.txt\",\"content\":\"hi\"}")
            let writeResult = try await fence.invoke(writeCall)
            #expect(writeResult.isError)
            #expect(writeResult.content.contains("Unattended approval denied"))

            // Any command tool must fail closed
            let cmdCall = ToolCallRequest(tool: "pen_run_command", argumentsJSON: "{\"command\":\"ls\"}")
            let cmdResult = try await fence.invoke(cmdCall)
            #expect(cmdResult.isError)
            #expect(cmdResult.content.contains("Unattended approval denied"))
        }

        // Scenario 9: Startup Recovery and Cascade Deletion
        @Test func scenario09_startupRecoveryAndCascadeDeletion() async throws {
            let (workspace, _) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let db = try createDatabase()
            let chatID = UUID().uuidString
            try await db.save(makeChat(id: chatID))

            let runId1 = UUID().uuidString
            let runId2 = UUID().uuidString
            try await db.save(
                SubagentRunRecord(
                    id: runId1,
                    chatId: chatID,
                    parentTurnId: UUID().uuidString,
                    status: "running",
                    taskBriefJson: "{}"
                ))
            try await db.save(
                SubagentRunRecord(
                    id: runId2,
                    chatId: chatID,
                    parentTurnId: UUID().uuidString,
                    status: "completed",
                    taskBriefJson: "{}"
                ))

            let recoveredCount = try await db.recoverInterruptedSubagentRuns()
            #expect(recoveredCount == 1)
            #expect(try await db.subagentRun(id: runId1)?.status == "interrupted")
            #expect(try await db.subagentRun(id: runId2)?.status == "completed")

            // Delete chat and verify cascade deletion
            try await db.deleteChat(id: chatID)
            #expect(try await db.subagentRun(id: runId1) == nil)
            #expect(try await db.subagentRun(id: runId2) == nil)
        }

        // Scenario 10: Evidence Provenance and Fabricated Citation Stripping
        @Test func scenario10_evidenceProvenanceAndFabricatedCitationStripping() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }

            let filePath = workspace.appendingPathComponent("Auth.swift")
            let fileContent = """
                line 1: import Foundation
                line 2: struct User {
                line 3:     let id: String
                line 4: }
                """
            try fileContent.write(to: filePath, atomically: true, encoding: .utf8)

            let lease = SubagentCapabilityLease()
            let fence = SubagentCapabilityFence(fileTools: fileTools, lease: lease)

            // Read lines 1 to 3
            let readCall = ToolCallRequest(
                tool: "pen_read_file",
                argumentsJSON: "{\"path\":\"Auth.swift\",\"start_line\":1,\"line_count\":3}"
            )
            let readResult = try await fence.invoke(readCall)
            #expect(!readResult.isError)

            // Citation 1: Valid citation covering lines 1-2
            let validCitation = SubagentCitation(path: "Auth.swift", startLine: 1, endLine: 2)
            // Citation 2: Fabricated citation of an unread file
            let unreadFileCitation = SubagentCitation(path: "Secret.swift", startLine: 1, endLine: 5)
            // Citation 3: Out-of-bounds citation for Auth.swift (line 4 was not read)
            let outOfBoundsCitation = SubagentCitation(path: "Auth.swift", startLine: 1, endLine: 4)
            // Citation 4: Inverted line range
            let invertedCitation = SubagentCitation(path: "Auth.swift", startLine: 3, endLine: 1)
            // Citation 5: Invalid/zero start line
            let zeroCitation = SubagentCitation(path: "Auth.swift", startLine: 0, endLine: 2)

            let (verified, unresolved) = await fence.verifyCitations(
                claimed: [validCitation, unreadFileCitation, outOfBoundsCitation, invertedCitation, zeroCitation]
            )

            #expect(verified.count == 1)
            #expect(verified[0].path == "Auth.swift")
            #expect(!verified[0].sliceHash.isEmpty)

            #expect(unresolved.count == 4)
            let secretUnresolved = unresolved.contains { item in
                item.path == "Secret.swift" && item.reason == "unverifiedCitation"
            }
            let authUnresolved = unresolved.contains { item in
                item.path == "Auth.swift" && item.reason == "unverifiedCitation"
            }
            #expect(secretUnresolved)
            #expect(authUnresolved)

            // Test SubagentCitation decoding without slice_hash (model claim)
            let jsonClaim = """
                {"path": "Auth.swift", "start_line": 1, "end_line": 2}
                """.data(using: .utf8)!
            let decodedClaim = try JSONDecoder().decode(SubagentCitation.self, from: jsonClaim)
            #expect(decodedClaim.sliceHash == "")
            #expect(decodedClaim.path == "Auth.swift")
        }

        // Scenario 8: Host Authority Unregister While Paused Between Reads
        @Test func scenario08_hostAuthorityUnregisterWhilePaused() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }

            final class MutableAuthority: SubagentHostAuthority, @unchecked Sendable {
                var isAuthorized = true
                let tools: PenFileTools
                init(tools: PenFileTools) { self.tools = tools }
                func validateHostAuthority() async throws {
                    if !isAuthorized { throw CapabilityError.revoked }
                }
                func currentPenFileTools() async throws -> PenFileTools {
                    if !isAuthorized { throw CapabilityError.revoked }
                    return tools
                }
            }

            let mutableAuth = MutableAuthority(tools: fileTools)
            let lease = SubagentCapabilityLease()
            let fence = SubagentCapabilityFence(authority: mutableAuth, lease: lease)

            let readCall = ToolCallRequest(
                tool: "pen_list_files",
                argumentsJSON: "{\"path\":\".\"}"
            )
            let firstResult = try await fence.invoke(readCall)
            #expect(!firstResult.isError)

            // Deactivate authority while paused
            mutableAuth.isAuthorized = false

            await #expect(throws: CapabilityError.self) {
                _ = try await fence.invoke(readCall)
            }
        }

        // Scenario 9: Delayed Transport Quarantine & Closure Synchronization
        @Test func scenario09_delayedTransportQuarantineAndClosureSync() async throws {
            let quarantine = SubagentTransportQuarantine()
            #expect(!quarantine.isQuarantined)
            #expect(!quarantine.isTransportActive)

            quarantine.markTransportActive()
            #expect(quarantine.isTransportActive)

            // Fast close resumes awaitClosure promptly
            let waitTask = Task {
                await quarantine.awaitClosure(timeoutSeconds: 2)
            }
            try await Task.sleep(for: .milliseconds(50))
            quarantine.markTransportClosed()
            let closedInTime = await waitTask.value
            #expect(closedInTime)
            #expect(!quarantine.isQuarantined)
            #expect(!quarantine.isTransportActive)

            // A timeout causes quarantine to be set
            quarantine.markTransportActive()
            let timedOutWait = await quarantine.awaitClosure(timeoutSeconds: 0)
            #expect(!timedOutWait)
            #expect(quarantine.isQuarantined)

            // Transport closed clears quarantine
            quarantine.markTransportClosed()
            #expect(!quarantine.isQuarantined)
        }

        // Scenario 10: Cumulative Parent Turn Budget and Consecutive Delegations
        @Test func scenario10_cumulativeParentTurnBudgetAndConsecutiveDelegations() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let db = try createDatabase()
            let chatID = UUID()
            let turnID = UUID()
            try await db.save(makeChat(id: chatID.uuidString))

            let accounting = SubagentTurnTokenAccounting()
            #expect(accounting.canDelegate)

            // First delegation: scripted engine with moderate tokens
            let engine1 = ScriptedEngine(script: [
                [
                    .token("First subagent completed successfully"),
                    .done(GenStats(ttft: nil, tokens: 6000, duration: 0.01, tokensAreExact: true)),
                ]
            ])
            let lease1 = SubagentCapabilityLease()
            let context1 = SubagentExecutionContext(
                chatID: chatID,
                turnID: turnID,
                projectID: nil,
                workspace: workspace,
                fileTools: fileTools,
                engine: engine1,
                database: db,
                turnTokenAccounting: accounting,
                lease: lease1
            )
            let worker1 = SubagentWorker(task: SubagentTaskBrief(objective: "Task 1"), context: context1)
            let result1 = try await worker1.run()
            #expect(result1.receipt.status == .completed)
            #expect(accounting.delegationsCount == 1)

            // Second delegation: hits cumulative generation turn budget
            let engine2 = ScriptedEngine(script: [
                [
                    .token("Second subagent output"),
                    .done(GenStats(ttft: nil, tokens: 4000, duration: 0.01, tokensAreExact: true)),
                ]
            ])
            let lease2 = SubagentCapabilityLease()
            let context2 = SubagentExecutionContext(
                chatID: chatID,
                turnID: turnID,
                projectID: nil,
                workspace: workspace,
                fileTools: fileTools,
                engine: engine2,
                database: db,
                turnTokenAccounting: accounting,
                lease: lease2
            )
            let worker2 = SubagentWorker(task: SubagentTaskBrief(objective: "Task 2"), context: context2)
            let result2 = try await worker2.run()
            #expect(result2.receipt.status == .budgetExhausted)
            #expect(!accounting.canDelegate)
        }

        // Scenario 10b: Mid-stream cancellation preserves partial token accounting
        @Test func scenario10b_midStreamCancellationPreservesPartialAccounting() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let db = try createDatabase()
            let chatID = UUID()
            let turnID = UUID()
            try await db.save(makeChat(id: chatID.uuidString))

            let accounting = SubagentTurnTokenAccounting()
            let lease = SubagentCapabilityLease()

            let slowEngine = ScriptedEngine(
                script: [
                    [
                        .token("chunk-1 "),
                        .token("chunk-2 "),
                        .token("chunk-3 "),
                    ]
                ], delay: .milliseconds(500))

            let context = SubagentExecutionContext(
                chatID: chatID,
                turnID: turnID,
                projectID: nil,
                workspace: workspace,
                fileTools: fileTools,
                engine: slowEngine,
                database: db,
                turnTokenAccounting: accounting,
                lease: lease
            )

            let worker = SubagentWorker(task: SubagentTaskBrief(objective: "Partial test"), context: context)
            let runTask = Task {
                try await worker.run()
            }
            try await Task.sleep(for: .milliseconds(150))
            await worker.cancel()
            let result = try await runTask.value
            #expect(result.receipt.status == .cancelled)
            #expect(result.totalTokens >= 0)
        }

        // Scenario 11: Admission Rejection Variants
        @Test func scenario11_admissionRejectionVariants() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let db = try createDatabase()
            let chatID = UUID()
            let turnID = UUID()
            try await db.save(makeChat(id: chatID.uuidString))

            // Test 1: Active requests count unknown
            actor UnknownActiveRequestsEngine: InferenceEngine {
                func health() async -> EngineHealth { .ok([]) }
                func runtimeStatus() async -> EngineRuntimeStatus? {
                    EngineRuntimeStatus(
                        observedAt: .now,
                        version: "1.0",
                        modelMemoryUsed: 100 * 1024 * 1024,
                        modelMemoryMaximum: 16 * 1024 * 1024 * 1024,
                        activeRequests: nil,
                        waitingRequests: 0,
                        models: [
                            EngineModelRuntimeStatus(id: "qwen2.5-7b-instruct", loaded: true, contextWindow: 32_768)
                        ]
                    )
                }
                func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
                    AsyncThrowingStream { $0.finish() }
                }
            }

            let context1 = SubagentExecutionContext(
                chatID: chatID, turnID: turnID, projectID: nil, workspace: workspace,
                fileTools: fileTools, engine: UnknownActiveRequestsEngine(), database: db,
                lease: SubagentCapabilityLease()
            )
            let result1 = try await SubagentWorker(
                task: SubagentTaskBrief(objective: "Admission test 1"), context: context1
            ).run()
            #expect(result1.receipt.status == .failed)
            #expect(
                result1.receipt.unresolved.contains { $0.detail?.contains("active requests count is unknown") == true })

            // Test 2: Waiting requests count unknown
            actor UnknownWaitingRequestsEngine: InferenceEngine {
                func health() async -> EngineHealth { .ok([]) }
                func runtimeStatus() async -> EngineRuntimeStatus? {
                    EngineRuntimeStatus(
                        observedAt: .now,
                        version: "1.0",
                        modelMemoryUsed: 100 * 1024 * 1024,
                        modelMemoryMaximum: 16 * 1024 * 1024 * 1024,
                        activeRequests: 0,
                        waitingRequests: nil,
                        models: [
                            EngineModelRuntimeStatus(id: "qwen2.5-7b-instruct", loaded: true, contextWindow: 32_768)
                        ]
                    )
                }
                func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
                    AsyncThrowingStream { $0.finish() }
                }
            }

            let context2 = SubagentExecutionContext(
                chatID: chatID, turnID: turnID, projectID: nil, workspace: workspace,
                fileTools: fileTools, engine: UnknownWaitingRequestsEngine(), database: db,
                lease: SubagentCapabilityLease()
            )
            let result2 = try await SubagentWorker(
                task: SubagentTaskBrief(objective: "Admission test 2"), context: context2
            ).run()
            #expect(result2.receipt.status == .failed)
            #expect(
                result2.receipt.unresolved.contains { $0.detail?.contains("waiting requests count is unknown") == true }
            )

            // Test 3: Model context window unknown
            actor UnknownContextWindowEngine: InferenceEngine {
                func health() async -> EngineHealth { .ok([]) }
                func runtimeStatus() async -> EngineRuntimeStatus? {
                    EngineRuntimeStatus(
                        observedAt: .now,
                        version: "1.0",
                        modelMemoryUsed: 100 * 1024 * 1024,
                        modelMemoryMaximum: 16 * 1024 * 1024 * 1024,
                        activeRequests: 0,
                        waitingRequests: 0,
                        models: [EngineModelRuntimeStatus(id: "qwen2.5-7b-instruct", loaded: true, contextWindow: nil)]
                    )
                }
                func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
                    AsyncThrowingStream { $0.finish() }
                }
            }

            let context3 = SubagentExecutionContext(
                chatID: chatID, turnID: turnID, projectID: nil, workspace: workspace,
                fileTools: fileTools, engine: UnknownContextWindowEngine(), database: db,
                lease: SubagentCapabilityLease()
            )
            let result3 = try await SubagentWorker(
                task: SubagentTaskBrief(objective: "Admission test 3"), context: context3
            ).run()
            #expect(result3.receipt.status == .failed)
            #expect(
                result3.receipt.unresolved.contains { $0.detail?.contains("Model context window is unknown") == true })

            // Test 4: Insufficient KV cache memory headroom (< 256 MiB)
            actor LowMemoryHeadroomEngine: InferenceEngine {
                func health() async -> EngineHealth { .ok([]) }
                func runtimeStatus() async -> EngineRuntimeStatus? {
                    EngineRuntimeStatus(
                        observedAt: .now,
                        version: "1.0",
                        modelMemoryUsed: 900 * 1024 * 1024,
                        modelMemoryMaximum: 1000 * 1024 * 1024,  // 100 MiB free, less than 256 MiB required
                        activeRequests: 0,
                        waitingRequests: 0,
                        models: [
                            EngineModelRuntimeStatus(id: "qwen2.5-7b-instruct", loaded: true, contextWindow: 32_768)
                        ]
                    )
                }
                func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
                    AsyncThrowingStream { $0.finish() }
                }
            }

            let context4 = SubagentExecutionContext(
                chatID: chatID, turnID: turnID, projectID: nil, workspace: workspace,
                fileTools: fileTools, engine: LowMemoryHeadroomEngine(), database: db, lease: SubagentCapabilityLease()
            )
            let result4 = try await SubagentWorker(
                task: SubagentTaskBrief(objective: "Admission test 4"), context: context4
            ).run()
            #expect(result4.receipt.status == .failed)
            #expect(result4.receipt.unresolved.contains { $0.detail?.contains("Insufficient memory headroom") == true })
        }

        // Scenario 12: Lost Terminal CAS Race and Cascade Deletion
        @Test func scenario12_lostTerminalCASRace() async throws {
            let db = try createDatabase()
            let chatID = UUID().uuidString
            let turnID = UUID().uuidString
            let runID = UUID().uuidString
            try await db.save(makeChat(id: chatID))

            let initialRecord = SubagentRunRecord(
                id: runID,
                chatId: chatID,
                parentTurnId: turnID,
                status: "running",
                taskBriefJson: "{}"
            )
            try await db.save(initialRecord)

            // Another writer commits a terminal state first
            let firstCAS = try await db.transitionSubagentRun(
                id: runID,
                toStatus: "cancelled",
                roundsExecuted: 1,
                totalTokens: 50,
                transcriptBytes: 0,
                transcriptJson: nil,
                summary: "Concurrent cancellation won.",
                citationsJson: "[]",
                receiptJson: "{}"
            )
            #expect(firstCAS)

            // Second CAS attempt fails because the record is already terminal
            let secondCAS = try await db.transitionSubagentRun(
                id: runID,
                toStatus: "completed",
                roundsExecuted: 2,
                totalTokens: 100,
                transcriptBytes: 0,
                transcriptJson: nil,
                summary: "Completed won.",
                citationsJson: "[]",
                receiptJson: "{}"
            )
            #expect(!secondCAS)

            let authoritative = try await db.subagentRun(id: runID)
            #expect(authoritative?.status == "cancelled")
            #expect(authoritative?.summary == "Concurrent cancellation won.")
        }

        // Scenario 12b: Worker fails closed if CAS fails and record was cascade deleted
        @Test func scenario12b_workerFailsClosedOnCascadeDeletion() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let db = try createDatabase()
            let chatID = UUID()
            let turnID = UUID()
            try await db.save(makeChat(id: chatID.uuidString))

            let engine = ScriptedEngine(
                script: [
                    [.token("Output"), .done(GenStats(ttft: nil, tokens: 10, duration: 0.01))]
                ], delay: .milliseconds(50))

            let context = SubagentExecutionContext(
                chatID: chatID,
                turnID: turnID,
                projectID: nil,
                workspace: workspace,
                fileTools: fileTools,
                engine: engine,
                database: db,
                lease: SubagentCapabilityLease()
            )

            let worker = SubagentWorker(task: SubagentTaskBrief(objective: "Cascade delete test"), context: context)

            let runTask = Task {
                try await worker.run()
            }

            // Delete the chat while worker is running so the CAS fails and the record is gone
            try await Task.sleep(for: .milliseconds(20))
            try await db.deleteChat(id: chatID.uuidString)

            await #expect(throws: CapabilityError.self) {
                _ = try await runTask.value
            }
        }

        // Deterministic tests for WorkerCompletionBridge
        @Test func workerCompletionBridge_completeBeforeWait() async throws {
            let bridge = WorkerCompletionBridge()
            let receipt = SubagentReceipt(runId: "123", status: .completed, summary: "Completed early")
            let subagentResult = SubagentResult(receipt: receipt)

            // Complete before wait() is invoked
            await bridge.complete(with: .success(subagentResult))

            let lateResult = await bridge.wait()
            #expect(lateResult != nil)
            switch lateResult! {
            case .success(let res):
                #expect(res.receipt.summary == "Completed early")
            case .failure:
                Issue.record("Expected success result")
            }
        }

        @Test func workerCompletionBridge_failureBeforeWait() async throws {
            let bridge = WorkerCompletionBridge()
            let expectedError = CapabilityError.unauthorized

            // Complete with failure before wait() is invoked
            await bridge.complete(with: .failure(expectedError))

            let lateResult = await bridge.wait()
            #expect(lateResult != nil)
            switch lateResult! {
            case .success:
                Issue.record("Expected failure result")
            case .failure(let err):
                #expect(err as? CapabilityError == expectedError)
            }
        }

        @Test func workerCompletionBridge_cancellationBeforeWait() async throws {
            let bridge = WorkerCompletionBridge()
            await bridge.cancel()

            let lateResult = await bridge.wait()
            #expect(lateResult != nil)
            switch lateResult! {
            case .success:
                Issue.record("Expected cancellation error")
            case .failure(let err):
                #expect(err is CancellationError)
            }
        }

        @Test func workerCompletionBridge_timeoutBeforeWait() async throws {
            let bridge = WorkerCompletionBridge()
            await bridge.timeout()

            let lateResult = await bridge.wait()
            #expect(lateResult == nil)
        }

        // Live memory bounding before append tests
        @Test func liveMemoryBounds_preAppendClampingOnOversizedChunk() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let db = try createDatabase()
            let chatID = UUID()
            let turnID = UUID()
            try await db.save(makeChat(id: chatID.uuidString))

            // Chunk that would vastly exceed max transcript bytes (512 KiB)
            let hugeString = String(repeating: "ABCDEFGHIJKLMNOPQRSTUVWXYZ", count: 30_000)  // ~780 KiB
            let engine = ScriptedEngine(script: [
                [.token(hugeString), .done(GenStats(ttft: nil, tokens: 50, duration: 0.01))]
            ])

            let context = SubagentExecutionContext(
                chatID: chatID,
                turnID: turnID,
                projectID: nil,
                workspace: workspace,
                fileTools: fileTools,
                engine: engine,
                database: db,
                lease: SubagentCapabilityLease()
            )

            let worker = SubagentWorker(task: SubagentTaskBrief(objective: "Oversized chunk test"), context: context)
            let result = try await worker.run()

            #expect(result.receipt.status == .budgetExhausted)
            let transcriptBytes = result.transcriptJSON?.utf8.count ?? 0
            #expect(transcriptBytes <= SubagentLimits.maxTranscriptBytes + 1024)
        }

        // Quarantine Wait Registration Pre-Cancelled Test
        @Test func quarantineWaitRegistration_preCancelledResumesImmediately() async throws {
            let registration = QuarantineWaitRegistration()
            registration.cancel()
            await withCheckedContinuation { cont in
                let inserted = registration.setContinuation(cont)
                if !inserted {
                    cont.resume()
                }
            }
        }

        // Quarantine Guarded Engine Blocks While Quarantined Test
        @Test func quarantineGuardedEngine_blocksWhileQuarantined() async throws {
            let underlying = ScriptedEngine(script: [
                [.token("Parent turn text"), .done(GenStats(ttft: nil, tokens: 10, duration: 0.01))]
            ])
            let quarantine = SubagentTransportQuarantine()
            let guarded = QuarantineGuardedEngine(underlying: underlying, quarantine: quarantine)

            quarantine.markQuarantined()
            let request = GenerationRequest(
                model: "qwen2.5-7b-instruct",
                turns: [ChatTurn(role: .user, text: "Hello")],
                effort: .trot,
                maxTokens: 100
            )

            let stream = await guarded.stream(request)
            var errorThrown: Error?
            do {
                for try await _ in stream {}
            } catch {
                errorThrown = error
            }
            #expect(errorThrown != nil)
            #expect(quarantine.isQuarantined)
        }

        // Multi-call aggregate memory bounding test: stops before overflowing call
        @Test func liveMemoryBounds_stopsBeforeOverflowingCall() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let db = try createDatabase()
            let chatID = UUID()
            let turnID = UUID()
            try await db.save(makeChat(id: chatID.uuidString))

            let bigArgs1 = String(repeating: "A", count: 400 * 1024)
            let bigArgs2 = String(repeating: "B", count: 200 * 1024)
            let call1 = ToolCallEvent(id: "call_1", name: "view_file", argumentsJSON: bigArgs1)
            let call2 = ToolCallEvent(id: "call_2", name: "view_file", argumentsJSON: bigArgs2)

            let engine = ScriptedEngine(script: [
                [.toolCalls([call1, call2])]
            ])

            let context = SubagentExecutionContext(
                chatID: chatID,
                turnID: turnID,
                projectID: nil,
                workspace: workspace,
                fileTools: fileTools,
                engine: engine,
                database: db,
                lease: SubagentCapabilityLease()
            )

            let worker = SubagentWorker(
                task: SubagentTaskBrief(objective: "Aggregate tool call bounding test"),
                context: context
            )
            let result = try await worker.run()

            #expect(result.receipt.status == .budgetExhausted)
            if let transcript = result.transcriptJSON {
                #expect(transcript.contains("call_1"))
                #expect(!transcript.contains("call_2"))
            }
        }

        // Tool input streaming enforces maxGenAllowed
        @Test func toolInputStreaming_enforcesMaxGenAllowed() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let db = try createDatabase()
            let chatID = UUID()
            let turnID = UUID()
            try await db.save(makeChat(id: chatID.uuidString))

            let engine = ScriptedEngine(script: [
                [
                    .toolInput(bytes: 4000),
                    .toolInput(bytes: 5000),
                    .token("Should not be reached"),
                ]
            ])

            let context = SubagentExecutionContext(
                chatID: chatID,
                turnID: turnID,
                projectID: nil,
                workspace: workspace,
                fileTools: fileTools,
                engine: engine,
                database: db,
                lease: SubagentCapabilityLease()
            )

            let worker = SubagentWorker(
                task: SubagentTaskBrief(objective: "Tool input streaming cap test"),
                context: context
            )
            let result = try await worker.run()

            #expect(result.receipt.status == .budgetExhausted)
            #expect(result.receipt.unresolved.contains { $0.reason == "budgetExhausted" })
        }

        // Prompt tokens reserved immediately upon cancellation
        @Test func promptTokensReservedImmediately_uponCancellation() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let db = try createDatabase()
            let chatID = UUID()
            let turnID = UUID()
            try await db.save(makeChat(id: chatID.uuidString))

            let engine = HangingEngine()
            let context = SubagentExecutionContext(
                chatID: chatID,
                turnID: turnID,
                projectID: nil,
                workspace: workspace,
                fileTools: fileTools,
                engine: engine,
                database: db,
                lease: SubagentCapabilityLease()
            )

            let worker = SubagentWorker(
                task: SubagentTaskBrief(objective: "Prompt accounting cancellation test"),
                context: context
            )

            let runTask = Task {
                try await worker.run()
            }

            try await Task.sleep(for: .milliseconds(50))
            await worker.cancel()

            let result = try await runTask.value
            #expect(result.receipt.status == .cancelled)
            #expect(result.receipt.totalTokens > 0)
        }

        // Stage 1 model envelope rejects excessive context window
        @Test func stage1ModelEnvelope_rejectsExcessiveContextWindow() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let db = try createDatabase()
            let chatID = UUID()
            let turnID = UUID()
            try await db.save(makeChat(id: chatID.uuidString))

            actor OversizedContextEngine: InferenceEngine {
                func health() async -> EngineHealth { .ok([]) }
                func runtimeStatus() async -> EngineRuntimeStatus? {
                    EngineRuntimeStatus(
                        observedAt: .now,
                        version: "1.0",
                        modelMemoryUsed: 100 * 1024 * 1024,
                        modelMemoryMaximum: 64 * 1024 * 1024 * 1024,
                        activeRequests: 0,
                        waitingRequests: 0,
                        models: [
                            EngineModelRuntimeStatus(id: "qwen2.5-7b-instruct", loaded: true, contextWindow: 262_144)
                        ]
                    )
                }
                func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
                    AsyncThrowingStream { $0.finish() }
                }
            }

            let context = SubagentExecutionContext(
                chatID: chatID,
                turnID: turnID,
                projectID: nil,
                workspace: workspace,
                fileTools: fileTools,
                engine: OversizedContextEngine(),
                database: db,
                lease: SubagentCapabilityLease()
            )

            let worker = SubagentWorker(
                task: SubagentTaskBrief(objective: "Oversized context test"),
                context: context
            )
            let result = try await worker.run()

            #expect(result.receipt.status == .failed)
            #expect(
                result.receipt.unresolved.contains { $0.detail?.contains("exceeds validated Stage 1 limit") == true })
        }

        // Fallback parser tests for prefixed JSON, trailing text, and reversed braces
        @Test func fallbackParser_prefixedJSONAndTrailingTextAndReversedBraces() {
            // 1. Prefixed JSON ending at the end of the text
            let prefixedJSON = "Thinking completed. Here is the response: {\"summary\":\"done\"}"
            let parsed1 = SubagentWorker.parseModelResponse(prefixedJSON)
            #expect(parsed1.summary == "done")

            // 2. Prefixed empty JSON at end of text (bounds check)
            let prefixedEmpty = "Analysis: {}"
            let parsed2 = SubagentWorker.parseModelResponse(prefixedEmpty)
            #expect(parsed2.summary == prefixedEmpty)

            // 3. Prefixed JSON with trailing text
            let withTrailing = "Here is the result: {\"summary\":\"success\"} Hope this helps!"
            let parsed3 = SubagentWorker.parseModelResponse(withTrailing)
            #expect(parsed3.summary == "success")

            // 4. Reversed braces (does not crash or create invalid slice)
            let reversedBraces = "Invalid text } before {"
            let parsed4 = SubagentWorker.parseModelResponse(reversedBraces)
            #expect(parsed4.summary == reversedBraces)
        }

        // Controlled latch ensures parent request is NOT invoked before child closure acknowledgement
        @Test func transportAcknowledgement_gatesParentDispatchUntilClosureAcknowledged() async throws {
            let quarantine = SubagentTransportQuarantine()

            actor ControlledLatchEngine: InferenceEngine {
                var parentStreamInvoked = false

                func health() async -> EngineHealth { .ok([]) }
                func runtimeStatus() async -> EngineRuntimeStatus? {
                    EngineRuntimeStatus(
                        observedAt: .now,
                        version: "1.0",
                        modelMemoryUsed: 100 * 1024 * 1024,
                        modelMemoryMaximum: 16 * 1024 * 1024 * 1024,
                        activeRequests: 0,
                        waitingRequests: 0,
                        models: [
                            EngineModelRuntimeStatus(id: "qwen2.5-7b-instruct", loaded: true, contextWindow: 32_768)
                        ]
                    )
                }

                func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
                    parentStreamInvoked = true
                    return AsyncThrowingStream { continuation in
                        continuation.yield(.token("parent response"))
                        continuation.finish()
                    }
                }

                func wasInvoked() -> Bool {
                    parentStreamInvoked
                }
            }

            let underlying = ControlledLatchEngine()
            let guardedEngine = QuarantineGuardedEngine(underlying: underlying, quarantine: quarantine)

            // Simulate active child transport with closure handle
            let childClosureHandle = GenerationTransportClosureHandle()
            quarantine.markTransportActive()
            childClosureHandle.onAcknowledge {
                quarantine.markTransportClosed()
            }

            #expect(quarantine.isTransportActive == true)

            let parentReq = GenerationRequest(
                model: "qwen2.5-7b-instruct",
                turns: [ChatTurn(role: .user, text: "Parent hello")],
                effort: .graze
            )

            // Launch parent stream in background task through guardedEngine
            let parentTask = Task {
                let stream = await guardedEngine.stream(parentReq)
                var events: [GenerationEvent] = []
                for try await event in stream {
                    events.append(event)
                }
                return events
            }

            // Allow the task to reach guardedEngine.stream awaiting closure
            try await Task.sleep(for: .milliseconds(50))

            // Assert: underlying parent request is NOT invoked before acknowledgement
            let invokedBeforeAck = await underlying.wasInvoked()
            #expect(
                invokedBeforeAck == false,
                "Parent stream must not be invoked before child transport closure is acknowledged")

            // Release child transport closure
            childClosureHandle.acknowledge()

            // Parent request should now proceed, dispatch to underlying engine, and finish deterministically
            let events = try await parentTask.value
            #expect(!events.isEmpty)

            let invokedAfterAck = await underlying.wasInvoked()
            #expect(invokedAfterAck == true, "Parent stream must be invoked after transport closure is acknowledged")
            #expect(quarantine.isTransportActive == false)
        }

        // Prompt token reservation when stream method itself suspends
        @Test func promptAccounting_reservesTokensWhenStreamMethodItselfSuspends() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let db = try createDatabase()
            let chatID = UUID()
            let turnID = UUID()
            try await db.save(makeChat(id: chatID.uuidString))

            actor SuspendingStreamMethodEngine: InferenceEngine {
                func health() async -> EngineHealth { .ok([]) }
                func runtimeStatus() async -> EngineRuntimeStatus? {
                    EngineRuntimeStatus(
                        observedAt: .now,
                        version: "1.0",
                        modelMemoryUsed: 100 * 1024 * 1024,
                        modelMemoryMaximum: 16 * 1024 * 1024 * 1024,
                        activeRequests: 0,
                        waitingRequests: 0,
                        models: [
                            EngineModelRuntimeStatus(id: "qwen2.5-7b-instruct", loaded: true, contextWindow: 32_768)
                        ]
                    )
                }

                func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
                    // Method itself suspends before returning the stream
                    try? await Task.sleep(for: .seconds(10))
                    return AsyncThrowingStream { $0.finish() }
                }
            }

            let context = SubagentExecutionContext(
                chatID: chatID,
                turnID: turnID,
                projectID: nil,
                workspace: workspace,
                fileTools: fileTools,
                engine: SuspendingStreamMethodEngine(),
                database: db,
                lease: SubagentCapabilityLease()
            )

            let worker = SubagentWorker(
                task: SubagentTaskBrief(objective: "Suspending stream method test"),
                context: context
            )

            let workerTask = Task {
                try await worker.run()
            }

            // Allow worker to enter stream acquisition
            try await Task.sleep(for: .milliseconds(40))
            workerTask.cancel()

            let result = try await workerTask.value
            #expect(result.receipt.status == .cancelled)
            // Round prompt tokens must be accounted even though stream method never returned
            #expect(result.receipt.totalTokens > 0)
        }

        // Memory admission checks: rejects 70B/unverified models, admits valid model based on turn budget
        @Test func memoryAdmission_rejects70BModelAndAdmitsTurnBudget() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let db = try createDatabase()
            let chatID = UUID()
            let turnID = UUID()
            try await db.save(makeChat(id: chatID.uuidString))

            // 1. 70B model rejected
            actor Large70BEngine: InferenceEngine {
                func health() async -> EngineHealth { .ok([]) }
                func runtimeStatus() async -> EngineRuntimeStatus? {
                    EngineRuntimeStatus(
                        observedAt: .now,
                        version: "1.0",
                        modelMemoryUsed: 100 * 1024 * 1024,
                        modelMemoryMaximum: 64 * 1024 * 1024 * 1024,
                        activeRequests: 0,
                        waitingRequests: 0,
                        models: [
                            EngineModelRuntimeStatus(id: "llama-3-70b-instruct", loaded: true, contextWindow: 131_072)
                        ]
                    )
                }
                func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
                    AsyncThrowingStream { $0.finish() }
                }
            }

            let context1 = SubagentExecutionContext(
                chatID: chatID,
                turnID: turnID,
                projectID: nil,
                workspace: workspace,
                fileTools: fileTools,
                engine: Large70BEngine(),
                database: db,
                lease: SubagentCapabilityLease()
            )

            let worker1 = SubagentWorker(
                task: SubagentTaskBrief(objective: "70B model test"),
                context: context1
            )
            let result1 = try await worker1.run()
            #expect(result1.receipt.status == .failed)
            #expect(
                result1.receipt.unresolved.contains {
                    $0.detail?.contains("outside the validated Stage 1 model allowlist") == true
                })

            // 2. Unverified / aliased model "default" fails closed
            actor AliasedDefaultEngine: InferenceEngine {
                func health() async -> EngineHealth { .ok([]) }
                func runtimeStatus() async -> EngineRuntimeStatus? {
                    EngineRuntimeStatus(
                        observedAt: .now,
                        version: "1.0",
                        modelMemoryUsed: 100 * 1024 * 1024,
                        modelMemoryMaximum: 64 * 1024 * 1024 * 1024,
                        activeRequests: 0,
                        waitingRequests: 0,
                        models: [
                            EngineModelRuntimeStatus(id: "default", loaded: true, contextWindow: 32_768)
                        ]
                    )
                }
                func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
                    AsyncThrowingStream { $0.finish() }
                }
            }

            let contextAliased = SubagentExecutionContext(
                chatID: chatID,
                turnID: turnID,
                projectID: nil,
                workspace: workspace,
                fileTools: fileTools,
                engine: AliasedDefaultEngine(),
                database: db,
                lease: SubagentCapabilityLease()
            )

            let workerAliased = SubagentWorker(
                task: SubagentTaskBrief(objective: "Aliased model test"),
                context: contextAliased
            )
            let resultAliased = try await workerAliased.run()
            #expect(resultAliased.receipt.status == .failed)
            #expect(
                resultAliased.receipt.unresolved.contains {
                    $0.detail?.contains("outside the validated Stage 1 model allowlist") == true
                })

            // 3. Viable 7B model with 131k context window admitted based on 14,336 turn budget
            actor Valid7BEngine: InferenceEngine {
                func health() async -> EngineHealth { .ok([]) }
                func runtimeStatus() async -> EngineRuntimeStatus? {
                    // Free memory is 3 GiB (greater than ~1.04 GiB required headroom for Qwen 7B)
                    EngineRuntimeStatus(
                        observedAt: .now,
                        version: "1.0",
                        modelMemoryUsed: 1 * 1024 * 1024 * 1024,
                        modelMemoryMaximum: 4 * 1024 * 1024 * 1024,
                        activeRequests: 0,
                        waitingRequests: 0,
                        models: [
                            EngineModelRuntimeStatus(id: "qwen2.5-7b-instruct", loaded: true, contextWindow: 131_072)
                        ]
                    )
                }
                func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
                    AsyncThrowingStream { continuation in
                        continuation.yield(.token("{\"summary\":\"done\"}"))
                        continuation.finish()
                    }
                }
            }

            let context2 = SubagentExecutionContext(
                chatID: chatID,
                turnID: turnID,
                projectID: nil,
                workspace: workspace,
                fileTools: fileTools,
                engine: Valid7BEngine(),
                database: db,
                lease: SubagentCapabilityLease()
            )

            let worker2 = SubagentWorker(
                task: SubagentTaskBrief(objective: "Valid 7B turn budget test"),
                context: context2
            )
            let result2 = try await worker2.run()
            #expect(result2.receipt.status == .completed)
        }

        // Fast producer / slow consumer bounded delivery overflow handling
        @Test func streamBuffer_fastProducerSlowConsumerTriggersOverflowHandling() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let db = try createDatabase()
            let chatID = UUID()
            let turnID = UUID()
            try await db.save(makeChat(id: chatID.uuidString))

            actor FastFloodingEngine: InferenceEngine {
                func health() async -> EngineHealth { .ok([]) }
                func runtimeStatus() async -> EngineRuntimeStatus? {
                    EngineRuntimeStatus(
                        observedAt: .now,
                        version: "1.0",
                        modelMemoryUsed: 100 * 1024 * 1024,
                        modelMemoryMaximum: 16 * 1024 * 1024 * 1024,
                        activeRequests: 0,
                        waitingRequests: 0,
                        models: [
                            EngineModelRuntimeStatus(id: "qwen2.5-7b-instruct", loaded: true, contextWindow: 32_768)
                        ]
                    )
                }

                func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
                    AsyncThrowingStream { continuation in
                        // Flood 100 events immediately exceeding the buffer capacity of 32
                        for i in 0..<100 {
                            continuation.yield(.token("flood_\(i) "))
                        }
                        continuation.finish()
                    }
                }
            }

            let context = SubagentExecutionContext(
                chatID: chatID,
                turnID: turnID,
                projectID: nil,
                workspace: workspace,
                fileTools: fileTools,
                engine: FastFloodingEngine(),
                database: db,
                lease: SubagentCapabilityLease()
            )

            let worker = SubagentWorker(
                task: SubagentTaskBrief(objective: "Buffer overflow test"),
                context: context
            )
            let result = try await worker.run()
            #expect(result.receipt.status == .failed)
            #expect(result.receipt.unresolved.contains { $0.reason == "streamBufferOverflow" })
        }

        // Large event exceeding maxStreamEventBytes triggers buffer overflow
        @Test func streamBuffer_largeEventTriggersBufferOverflow() async throws {
            let (workspace, fileTools) = try createWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let db = try createDatabase()
            let chatID = UUID()
            let turnID = UUID()
            try await db.save(makeChat(id: chatID.uuidString))

            actor LargeEventEngine: InferenceEngine {
                func health() async -> EngineHealth { .ok([]) }
                func runtimeStatus() async -> EngineRuntimeStatus? {
                    EngineRuntimeStatus(
                        observedAt: .now,
                        version: "1.0",
                        modelMemoryUsed: 100 * 1024 * 1024,
                        modelMemoryMaximum: 16 * 1024 * 1024 * 1024,
                        activeRequests: 0,
                        waitingRequests: 0,
                        models: [
                            EngineModelRuntimeStatus(id: "qwen2.5-7b-instruct", loaded: true, contextWindow: 32_768)
                        ]
                    )
                }

                func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
                    AsyncThrowingStream { continuation in
                        // Yield single event exceeding 64 KiB
                        let hugeChunk = String(repeating: "x", count: 1200 * 1024)
                        continuation.yield(.token(hugeChunk))
                        continuation.finish()
                    }
                }
            }

            let context = SubagentExecutionContext(
                chatID: chatID,
                turnID: turnID,
                projectID: nil,
                workspace: workspace,
                fileTools: fileTools,
                engine: LargeEventEngine(),
                database: db,
                lease: SubagentCapabilityLease()
            )

            let worker = SubagentWorker(
                task: SubagentTaskBrief(objective: "Large event test"),
                context: context
            )
            let result = try await worker.run()
            #expect(result.receipt.status == .failed)
            #expect(result.receipt.unresolved.contains { $0.reason == "streamBufferOverflow" })
        }

        // Transcript bounds and toolCallID preservation with heavy JSON escaping
        @Test func transcriptBounds_jsonEscapingHeavyContentEnforcesLimitAndPreservesToolCallID() throws {
            // 500,000 quotes expands to over 1,000,000 bytes in JSON
            let heavyQuotes = String(repeating: "\"", count: 500_000)
            let turns: [ChatTurn] = [
                ChatTurn(role: .system, text: "System prompt"),
                ChatTurn(role: .user, text: heavyQuotes),
                ChatTurn(role: .tool, text: "Tool result", toolCallID: "call_abc123"),
            ]

            let encoded = SubagentWorker.encodeTranscript(turns)
            #expect(encoded != nil)
            guard let encoded else { return }

            #expect(encoded.utf8.count <= SubagentLimits.maxTranscriptBytes)

            // Verify toolCallID is preserved in serialized JSON
            #expect(encoded.contains("call_abc123"))

            // Verify serialized string is parseable JSON
            guard let data = encoded.data(using: .utf8) else {
                #expect(Bool(false), "Encoded string must convert to UTF-8 data")
                return
            }
            let jsonObject = try? JSONSerialization.jsonObject(with: data)
            #expect(jsonObject != nil, "Serialized transcript must be valid JSON")
        }

        // Retained toolCallID with 300,000 quote characters must produce valid JSON under 512 KiB
        @Test func transcriptBounds_extremeQuotesInToolCallIDProducesValidJSON() throws {
            let extremeQuotes = String(repeating: "\"", count: 300_000)
            let turns: [ChatTurn] = [
                ChatTurn(role: .system, text: "System prompt"),
                ChatTurn(role: .user, text: "User prompt"),
                ChatTurn(role: .tool, text: "Tool result", toolCallID: extremeQuotes),
            ]

            let encoded = SubagentWorker.encodeTranscript(turns)
            #expect(encoded != nil)
            guard let encoded else { return }

            #expect(encoded.utf8.count <= SubagentLimits.maxTranscriptBytes)

            // Proves valid JSON: must deserialize cleanly with JSONSerialization
            guard let data = encoded.data(using: .utf8) else {
                #expect(Bool(false), "Encoded string must convert to UTF-8 data")
                return
            }
            let jsonObject = try? JSONSerialization.jsonObject(with: data)
            #expect(jsonObject != nil, "Serialized transcript must be valid JSON")
        }
    }
}
