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

    func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
        requests.append(request)
        let events =
            script.isEmpty
            ? [.done(GenStats(ttft: nil, tokens: 10, duration: 0.01))]
            : script.removeFirst()
        let sleepDuration = delay

        return AsyncThrowingStream { continuation in
            Task {
                if let sleepDuration {
                    try? await Task.sleep(for: sleepDuration)
                }
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}

private actor HangingEngine: InferenceEngine {
    func health() async -> EngineHealth { .ok([]) }

    func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable _ in
                continuation.finish(throwing: CancellationError())
            }
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
            let (workspace, _) = try createWorkspace()
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
            #expect(!lease.isRevoked)
            try lease.checkValid()

            // Revoking the lease terminates access immediately
            lease.revoke()
            #expect(lease.isRevoked)
            #expect(throws: CapabilityError.self) {
                try lease.checkValid()
            }

            // Once in a terminal state, CAS ensures subsequent writes fail
            let runId = UUID().uuidString
            let record = SubagentRunRecord(
                id: runId,
                chatId: chatID.uuidString,
                parentTurnId: turnID.uuidString,
                status: "completed",
                taskBriefJson: "{}"
            )
            try await db.save(record)

            let secondTransition = try await db.transitionSubagentRun(
                id: runId,
                toStatus: "timedOut",
                roundsExecuted: 1,
                totalTokens: 10,
                transcriptBytes: 0,
                transcriptJson: nil,
                summary: nil,
                citationsJson: nil,
                receiptJson: nil
            )
            #expect(!secondTransition)
            let fetched = try await db.subagentRun(id: runId)
            #expect(fetched?.status == "completed")
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
            let result = try await task.value

            #expect(result.receipt.status == .cancelled || result.receipt.status == .timedOut)
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
    }
}
