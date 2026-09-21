import Foundation
import GOATed
import Pronk
import Testing
import Tools

private func context(pen: UUID? = nil) -> ExtensionContext {
    ExtensionContext(view: ExtensionView(chatID: UUID(), penID: pen), turnID: UUID())
}

@Test func pronkIsOfflinePersistentAndPenScoped() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pronk-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = ExtensionRuntime()
    let pen = UUID()
    _ = try await runtime.activate(PronkExtension(stateDirectory: root))
    #expect(try await runtime.prepareTurn(context()).tools.isEmpty)
    let ctx = context(pen: pen)
    let snapshot = try await runtime.prepareTurn(ctx)
    func handle(_ name: String) -> ToolHandle { snapshot.tools.first { $0.schema.name == name }!.handle }
    let adopted = try await runtime.invoke(handle("pronk_adopt"), argumentsJSON: #"{"name":"Pebble","breed":"pygmy"}"#)
    { _, _ in true }
    #expect(adopted.content.contains("Pebble"))
    _ = try await runtime.invoke(handle("pronk_treat"), argumentsJSON: #"{"treat":"carrot"}"#) { _, _ in true }
    let turn = PersistedTurn(context: ctx, title: "Adventure", createdAt: .now, messages: [])
    _ = await runtime.didPersist(turn)
    _ = await runtime.didPersist(turn)
    let report = try await runtime.invoke(handle("pronk_report"), argumentsJSON: "{}") { _, _ in true }
    #expect(report.content.contains("treats: 1"))
    #expect(report.content.contains("adventures: 1"))
    let other = try await runtime.prepareTurn(context(pen: UUID()))
    let otherReport = try await runtime.invoke(
        other.tools.first { $0.schema.name == "pronk_report" }!.handle, argumentsJSON: "{}"
    ) { _, _ in true }
    #expect(!otherReport.content.contains("Pebble"))
    let fresh = ExtensionRuntime()
    _ = try await fresh.activate(PronkExtension(stateDirectory: root))
    let restored = try await fresh.prepareTurn(context(pen: pen))
    #expect(restored.promptSections.joined().contains("Pebble"))
}
