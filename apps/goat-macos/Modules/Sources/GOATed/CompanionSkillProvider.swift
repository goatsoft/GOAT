import Foundation

/// Skills whose availability depends on the consumer's scope, rather than only registration scope.
public protocol ScopedSkillProvider: SkillProvider {
    func listSkills(for view: ExtensionView) async throws -> [SkillCandidate]
}

public struct CompanionSkillProvider: ScopedSkillProvider {
    public let providerID: String
    private let name: String
    private let description: String
    private let instructions: String
    private let available: @Sendable (ExtensionView) async -> Bool
    public init(
        providerID: String, name: String, description: String, instructions: String,
        available: @escaping @Sendable (ExtensionView) async -> Bool
    ) {
        self.providerID = providerID
        self.name = name
        self.description = description
        self.instructions = instructions
        self.available = available
    }
    public func listSkills() async throws -> [SkillCandidate] { [] }
    public func listSkills(for view: ExtensionView) async throws -> [SkillCandidate] {
        guard await available(view) else { return [] }
        return [SkillCandidate(name: name, description: description, source: .builtIn, providerID: providerID)]
    }
    public func loadSkill(named name: String) async throws -> SkillDefinition {
        guard name == self.name else { throw SkillError.notFound(name) }
        return SkillDefinition(
            summary: SkillSummary(
                identity: SkillIdentity(
                    extensionID: ExtensionID(rawValue: providerID), scope: .application,
                    providerID: providerID, name: name), name: name, description: description, source: .builtIn),
            instructions: instructions)
    }
    public func readResource(skill name: String, path: String) async throws -> String {
        throw SkillError.unreadableResource(path)
    }
}
