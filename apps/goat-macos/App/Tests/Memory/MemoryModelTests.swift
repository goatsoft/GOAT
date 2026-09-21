import Darwin
import Foundation
import Testing

@testable import Bleet
@testable import GOAT
@testable import Hindsight
@testable import Hoofprint
@testable import MCPClient
@testable import Memory
@testable import Shepherd
@testable import Tools

private func resolvedMemoryModelTemporaryDirectory() throws -> URL {
    let temporaryPath = FileManager.default.temporaryDirectory.path
    var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard temporaryPath.withCString({ Darwin.realpath($0, &resolvedPath) }) != nil else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let bytes = resolvedPath.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
}

extension AppTests.Memory {
    @Suite struct MemoryModelTests {

        @MainActor
        @Test func rememberActionUsesTheMessagesPenSetting() async throws {
            let model = AppModel.shared
            await model.memory.load()
            let originalChats = model.chats
            let originalConfiguration = model.memory.configuration
            defer {
                model.chats = originalChats
                model.memory.configuration = originalConfiguration
            }
            model.memory.configuration = .fresh
            let session = ChatSession(effort: .trot, modelID: "test", projectID: UUID())
            let message = ChatMessage(role: .assistant)
            message.text = "A fact to remember."
            message.complete = true
            session.messages = [message]
            model.chats = [session]

            #expect(model.memory.isEnabled)
            #expect(!model.canRemember(message, projectID: session.projectID))
            model.remember(message)
            #expect(model.messageMemorySaves[message.id] == nil)

            // Moving the same message to Global must update availability without changing selection.
            session.projectID = nil
            #expect(model.canRemember(message, projectID: session.projectID))
            message.complete = false
            #expect(!model.canRemember(message, projectID: session.projectID))
            message.complete = true
            session.messages = []
            model.remember(message)
            #expect(model.messageMemorySaves[message.id] == nil)
        }

        @MainActor
        @Test func invalidMemoryConfigurationExposesNoMemoryCapability() async throws {
            let root = try resolvedMemoryModelTemporaryDirectory()
                .appendingPathComponent("goat-memory-model-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let configuration = root.appendingPathComponent("memory.json", isDirectory: false)
            let marker = root.appendingPathComponent("memory.marker", isDirectory: false)
            try "{ invalid JSON".write(to: configuration, atomically: true, encoding: .utf8)
            let store = MemoryConfigurationStore(configurationURL: configuration, markerURL: marker)
            let model = MemoryModel(activity: ActivityLog(), configurationStore: store)

            await model.load()

            #expect(model.configurationLoadState == .failed)
            #expect(!model.isEnabled)
            #expect(!model.isEnabled(forProjectID: nil))
            let entries = try await model.promptEntries(forProjectID: nil)
            #expect(entries.isEmpty)
        }

        @MainActor
        @Test func newPenMemoryIsOffUntilExplicitlyEnabled() async throws {
            let root = try resolvedMemoryModelTemporaryDirectory()
                .appendingPathComponent("goat-memory-model-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = MemoryConfigurationStore(
                configurationURL: root.appendingPathComponent("memory.json"),
                markerURL: root.appendingPathComponent("memory.marker"))
            let model = MemoryModel(activity: ActivityLog(), configurationStore: store)
            let penID = UUID()

            await model.load()

            #expect(model.isEnabled(forProjectID: nil))
            #expect(!model.penMemoryIsEnabled(forProjectID: penID))
            #expect(!model.isEnabled(forProjectID: penID))

            await model.setEnabled(true, forProjectID: penID, projectName: "Test Pen")

            #expect(model.penMemoryIsEnabled(forProjectID: penID))
            #expect(model.isEnabled(forProjectID: penID))
            #expect(model.configuration.pens[penID.uuidString]?.selection == .explicit(.localWiki))
        }

        @MainActor
        @Test func providerChangeLeavesExistingPenOffUntilExplicitRebind() async throws {
            let root = try resolvedMemoryModelTemporaryDirectory()
                .appendingPathComponent("goat-memory-model-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = MemoryConfigurationStore(
                configurationURL: root.appendingPathComponent("memory.json"),
                markerURL: root.appendingPathComponent("memory.marker"))
            let initial = try store.loadOrInitialize()
            let penID = UUID()
            var configuration = initial.configuration
            configuration.global = GlobalMemoryBinding(
                providerID: .llmWiki,
                history: [.llmWiki, .localWiki])
            configuration.defaultPenProviderID = .llmWiki
            configuration.pens[penID.uuidString] = PenMemoryBinding(
                selection: .explicit(.localWiki),
                history: [.localWiki])
            _ = try store.save(configuration, ifRevision: initial.revision)
            let model = MemoryModel(activity: ActivityLog(), configurationStore: store)

            await model.load()

            #expect(!model.penMemoryIsEnabled(forProjectID: penID))
            #expect(!model.isEnabled(forProjectID: penID))

            await model.setEnabled(true, forProjectID: penID, projectName: "Test Pen")

            #expect(model.penMemoryIsEnabled(forProjectID: penID))
            #expect(model.configuration.pens[penID.uuidString]?.selection == .explicit(.llmWiki))
            #expect(model.configuration.pens[penID.uuidString]?.history == [.llmWiki, .localWiki])
        }

        @Test func persistedTranscriptKeepsRecentTurnsWithinTheRetentionBound() throws {
            let chatID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
            let messages = [
                ShepherdPersistedTurn.Message(role: .user, text: String(repeating: "old ", count: 3_000)),
                ShepherdPersistedTurn.Message(role: .assistant, text: "old answer"),
                ShepherdPersistedTurn.Message(role: .user, text: "latest request"),
                ShepherdPersistedTurn.Message(role: .assistant, text: "latest answer 🐐"),
            ]
            let turn = ShepherdPersistedTurn(
                chatID: chatID,
                projectID: nil,
                commandMessageID: nil,
                title: "Bounded chat",
                createdAt: Date(timeIntervalSince1970: 0),
                kind: .regular,
                messages: messages)

            let rendered = MemoryModel.persistedTranscript(turn, maximumBytes: 1_024)

            #expect(rendered.utf8.count <= 1_024)
            #expect(rendered.contains("Earlier completed exchanges omitted"))
            #expect(rendered.contains("latest request"))
            #expect(rendered.contains("latest answer 🐐"))
        }
    }
}
