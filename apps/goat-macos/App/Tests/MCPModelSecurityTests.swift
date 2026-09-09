import Foundation
import Testing

@testable import GOAT
@testable import MCPClient

@Test func toolWireNamesAreStableBoundedAndCollisionResistant() {
    let first = MCPModel.requestToolName(server: "a/b", tool: "read file")
    let same = MCPModel.requestToolName(server: "a/b", tool: "read file")
    let serverCollision = MCPModel.requestToolName(server: "a_b", tool: "read file")
    let toolCollision = MCPModel.requestToolName(server: "a/b", tool: "read_file")

    #expect(first == same)
    #expect(first != serverCollision)
    #expect(first != toolCollision)
    #expect(first.count <= 64)
    #expect(
        first.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 95, 97...122: true
            default: false
            }
        })
}

@Test func grantsBindToTheExactServerTransport() {
    let base = MCPServerConfig(
        name: "files", transport: .stdio(command: "npx", args: ["server-a"], env: [:]))
    let changedCommand = MCPServerConfig(
        name: "files", transport: .stdio(command: "npx", args: ["server-b"], env: [:]))
    let firstHTTP = MCPServerConfig(
        name: "remote",
        transport: .http(
            url: URL(string: "https://localhost.example/mcp")!,
            headers: ["Authorization": "Bearer first"]))
    let secondHTTP = MCPServerConfig(
        name: "remote",
        transport: .http(
            url: URL(string: "https://localhost.example/mcp")!,
            headers: ["Authorization": "Bearer second"]))

    #expect(base.permissionFingerprint != changedCommand.permissionFingerprint)
    #expect(firstHTTP.permissionFingerprint != secondHTTP.permissionFingerprint)
    #expect(base.permissionFingerprint == base.permissionFingerprint)
}

@Test func permissionPreviewShowsEveryExecutableArgument() throws {
    let object: [String: Any] = [
        "items": Array(repeating: "x", count: 4_000),
        "dangerousTail": "delete-everything",
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let arguments = try #require(String(data: data, encoding: .utf8))
    #expect(arguments.utf8.count <= MCPServerManager.maximumArgumentBytes)

    let preview = try #require(MCPModel.permissionPreview(arguments))
    #expect(preview.contains("dangerousTail"))
    #expect(preview.contains("delete-everything"))
    #expect(!preview.contains("truncated"))

    let oversized = #"{"value":"\#(String(repeating: "x", count: MCPServerManager.maximumArgumentBytes))"}"#
    #expect(MCPModel.permissionPreview(oversized) == nil)
}
