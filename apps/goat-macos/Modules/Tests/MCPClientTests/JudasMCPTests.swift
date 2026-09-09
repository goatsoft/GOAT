import Foundation
import Testing

@testable import JUDAS
@testable import MCPClient

@Test func judasBlocksConfiguredMCPProcessBeforeLaunch() async throws {
    let judas = Judas(mode: .localNetworksOnly)
    let manager = MCPServerManager(judas: judas)
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: destination) }
    let config = MCPServerConfig(
        name: "blocked", transport: .stdio(command: "/usr/bin/touch", args: [destination.path], env: [:]))
    let state = await manager.connect(config)
    #expect(state.status == .failed)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(judas.drain().events.contains { $0.source == .mcpProcess && $0.action == .denied })
}
