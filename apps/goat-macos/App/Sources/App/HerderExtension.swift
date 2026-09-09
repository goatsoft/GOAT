import Foundation
import GOATed
import Pens
import Tools

/// Bundled GOATed adapter. The host reviews writes before the runtime starts execution.
struct HerderExtension: Extension {
    let manifest = ExtensionManifest(id: "goat.herder", version: "0.1.0")
    let contributions: ExtensionContributions

    init(provider: HerderFileProvider) {
        contributions = ExtensionContributions(tools: [provider])
    }
}

actor HerderFileProvider: ModelToolProvider {
    let files: PenFileTools
    let turnID: UUID
    let commands: PenCommandTools?
    let writesEnabled: Bool
    private var stagedCommand: (arguments: String, command: PenCommandTools.PreparedCommand)?
    private var staged: (arguments: String, tool: String, write: PenFileTools.PreparedWrite)?

    init(files: PenFileTools, turnID: UUID, commands: PenCommandTools? = nil, writesEnabled: Bool = true) {
        self.writesEnabled = writesEnabled
        self.files = files
        self.turnID = turnID
        self.commands = commands
    }

    func tools(for context: ExtensionContext) async throws -> [ToolSchema] {
        guard context.turnID == turnID else { return [] }
        return PenFileTools.schemas.filter { writesEnabled || !["pen_write_file", "pen_edit_file"].contains($0.name) }
            + (commands == nil ? [] : PenCommandTools.schemas)
    }

    func prepareCommand(argumentsJSON: String) async throws -> PenCommandTools.PreparedCommand {
        stagedCommand = nil
        guard let commands else { throw CapabilityError.unavailable }
        let command = try await commands.prepare(argumentsJSON: argumentsJSON)
        stagedCommand = (argumentsJSON, command)
        return command
    }

    func stopCommands() async { await commands?.stopAll() }

    func prepare(_ call: ToolCallRequest) async throws -> String? {
        staged = nil
        guard call.tool == "pen_write_file" || call.tool == "pen_edit_file" else { return nil }
        guard writesEnabled else { throw CapabilityError.unavailable }
        let write = try await files.prepare(tool: call.tool, argumentsJSON: call.argumentsJSON)
        staged = (call.argumentsJSON, call.tool, write)
        return write.previewJSON
    }

    func invoke(_ call: ToolCallRequest, context: ExtensionContext) async throws -> ToolResult {
        guard context.turnID == turnID else { throw CapabilityError.revoked }
        do {
            if call.tool == "pen_run_command" {
                guard let commands, let staged = stagedCommand, staged.arguments == call.argumentsJSON else {
                    throw CapabilityError.unauthorized
                }
                stagedCommand = nil
                return try await commands.start(staged.command)
            }
            if call.tool == "pen_command_status" || call.tool == "pen_stop_command" {
                guard let commands else { throw CapabilityError.unavailable }
                return try await commands.invoke(tool: call.tool, argumentsJSON: call.argumentsJSON)
            }
            if call.tool == "pen_write_file" || call.tool == "pen_edit_file" {
                guard writesEnabled, let current = staged, current.arguments == call.argumentsJSON,
                    current.tool == call.tool
                else {
                    throw CapabilityError.unauthorized
                }
                staged = nil
                return try await files.commit(current.write)
            }
            let result = try await files.read(tool: call.tool, argumentsJSON: call.argumentsJSON)
            guard result.content.utf8.count <= 262_144 else {
                return ToolResult(content: "Encoded file content exceeds the tool response limit.", isError: true)
            }
            return result
        } catch is CancellationError { throw CancellationError() } catch {
            return ToolResult(content: error.localizedDescription, isError: true)
        }
    }
}
