import Foundation

public struct ExtensionID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum ExtensionScope: Hashable, Sendable {
    case application
    case pen(UUID)
    case chat(UUID)
}

public struct ExtensionView: Hashable, Sendable {
    public let chatID: UUID
    public let penID: UUID?

    public init(chatID: UUID, penID: UUID?) {
        self.chatID = chatID
        self.penID = penID
    }

    func includes(_ scope: ExtensionScope) -> Bool {
        switch scope {
        case .application: true
        case .pen(let id): penID == id
        case .chat(let id): chatID == id
        }
    }
}

public struct Registration: Hashable, Sendable {
    let id: UUID
    public let extensionID: ExtensionID
    public let scope: ExtensionScope

    init(id: UUID, extensionID: ExtensionID, scope: ExtensionScope) {
        self.id = id
        self.extensionID = extensionID
        self.scope = scope
    }
}

public enum ExtensionRuntimeError: LocalizedError, Sendable, Equatable {
    case invalidIdentifier(String)
    case duplicateProvider(String)
    case registrationNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let value):
            "Invalid GOATed identifier: \(value)"
        case .duplicateProvider(let value):
            "GOATed provider is already registered in that scope: \(value)"
        case .registrationNotFound:
            "GOATed registration is no longer active."
        }
    }
}

/// GOATed, the GOAT Extension Dynamics runtime. The actor owns registration lifetime and returns
/// immutable snapshots to consumers. All API v1 capability families share this scoped
/// registration, cancellation and revocation contract (ADR-0042).
public actor ExtensionRuntime {
    struct SkillProviderRegistration: Sendable {
        let token: Registration
        let provider: any SkillProvider
    }

    var skillProviders: [UUID: SkillProviderRegistration] = [:]

    struct ExtensionEntry: Sendable {
        let token: Registration
        let manifest: ExtensionManifest
        let contributions: ExtensionContributions
        let skillTokens: [Registration]
    }
    var quarantined: Set<ExtensionID> = []
    var entries: [UUID: ExtensionEntry] = [:]
    var work: [UUID: [UUID: @Sendable () -> Void]] = [:]
    var turnWork: [UUID: [UUID: @Sendable () -> Void]] = [:]
    var turns: [UUID: TurnSnapshot] = [:]
    var persistedTurns: Set<UUID> = []
    var diagnostics: [ExtensionDiagnostic] = []
    let clock: any ExtensionClock
    let timeout: Duration

    public init(clock: any ExtensionClock = RuntimeClock(), timeout: Duration = .seconds(5)) {
        self.clock = clock
        self.timeout = timeout
    }

    public func registerSkillProvider(
        _ provider: any SkillProvider,
        extensionID: ExtensionID,
        scope: ExtensionScope
    ) throws -> Registration {
        guard !quarantined.contains(extensionID), skillProviders.count < 128 else { throw CapabilityError.capacity }
        try Self.validateIdentifier(extensionID.rawValue)
        try Self.validateIdentifier(provider.providerID)
        guard
            !skillProviders.values.contains(where: {
                $0.token.scope == scope && $0.provider.providerID == provider.providerID
            })
        else {
            throw ExtensionRuntimeError.duplicateProvider(provider.providerID)
        }
        let token = Registration(id: UUID(), extensionID: extensionID, scope: scope)
        skillProviders[token.id] = SkillProviderRegistration(token: token, provider: provider)
        return token
    }

    public func unregister(_ token: Registration) throws {
        if entries[token.id] != nil {
            deactivate(token)
            return
        }
        cancelWork(for: token.id)
        guard skillProviders.removeValue(forKey: token.id) != nil else {
            throw ExtensionRuntimeError.registrationNotFound
        }
    }

    public func skillCatalog(
        for view: ExtensionView,
        selection: SkillSelection = SkillSelection()
    ) async -> SkillCatalog {
        let registrations = skillProviders.values
            .filter { view.includes($0.token.scope) }
            .sorted { lhs, rhs in
                if lhs.token.scope.sortRank != rhs.token.scope.sortRank {
                    return lhs.token.scope.sortRank < rhs.token.scope.sortRank
                }
                if lhs.token.extensionID.rawValue != rhs.token.extensionID.rawValue {
                    return lhs.token.extensionID.rawValue < rhs.token.extensionID.rawValue
                }
                return lhs.provider.providerID < rhs.provider.providerID
            }

        var candidates: [SkillCandidate] = []
        var issues: [SkillIssue] = []
        for registration in registrations {
            if Task.isCancelled { break }
            guard skillProviders[registration.token.id] != nil else { continue }
            do {
                let listed: [SkillCandidate] = try await bounded(owner: registration.token) {
                    if let scoped = registration.provider as? any ScopedSkillProvider {
                        return try await scoped.listSkills(for: view)
                    }
                    return try await registration.provider.listSkills()
                }
                guard listed.count <= 128,
                    listed.allSatisfy({ $0.name.utf8.count <= 128 && $0.description.utf8.count <= 4096 })
                else {
                    throw CapabilityError.invalidPayload
                }
                try Task.checkCancellation()
                guard skillProviders[registration.token.id] != nil else { continue }
                candidates.append(
                    contentsOf: listed.map {
                        $0.withRegistration(
                            extensionID: registration.token.extensionID,
                            scope: registration.token.scope,
                            providerID: registration.provider.providerID,
                            registrationID: registration.token.id)
                    })
            } catch is CancellationError {
                break
            } catch {
                guard skillProviders[registration.token.id] != nil else { continue }
                issues.append(
                    SkillIssue(
                        source: registration.provider.providerID,
                        message: error.localizedDescription))
            }
        }
        let activeCandidates =
            Task.isCancelled
            ? []
            : candidates.filter { candidate in
                guard let id = candidate.identity.registrationID else { return false }
                return skillProviders[id] != nil
            }
        return SkillCatalog.resolve(candidates: activeCandidates, issues: issues, selection: selection)
    }

    public func loadSkill(
        named name: String,
        for view: ExtensionView,
        selection: SkillSelection = SkillSelection()
    ) async throws -> SkillDefinition {
        try Task.checkCancellation()
        let catalog = await skillCatalog(for: view, selection: selection)
        try Task.checkCancellation()
        guard let summary = catalog.skills.first(where: { $0.name == name }) else {
            throw SkillError.notFound(name)
        }
        guard
            let registration = skillProviders.values.first(where: {
                $0.token.id == summary.identity.registrationID
                    && $0.token.extensionID == summary.identity.extensionID
                    && $0.token.scope == summary.identity.scope
                    && $0.provider.providerID == summary.identity.providerID
            })
        else {
            throw SkillError.providerUnavailable(summary.identity.providerID)
        }
        let definition = try await bounded(owner: registration.token) {
            try await registration.provider.loadSkill(named: name)
        }
        try Task.checkCancellation()
        guard skillProviders[registration.token.id] != nil else {
            throw ExtensionRuntimeError.registrationNotFound
        }
        guard definition.summary.identity.providerID == registration.provider.providerID,
            definition.summary.name == summary.name
        else {
            throw SkillError.changedDuringLoad(name)
        }
        return definition.withResolvedSummary(summary)
    }

    public func readSkillResource(
        skill name: String,
        path: String,
        expectedIdentity: SkillIdentity,
        for view: ExtensionView,
        selection: SkillSelection = SkillSelection()
    ) async throws -> String {
        try Task.checkCancellation()
        let catalog = await skillCatalog(for: view, selection: selection)
        try Task.checkCancellation()
        guard
            let summary = catalog.skills.first(where: {
                $0.name == name && $0.identity == expectedIdentity
            })
        else {
            throw SkillError.notFound(name)
        }
        guard
            let registration = skillProviders.values.first(where: {
                $0.token.id == summary.identity.registrationID
                    && $0.token.extensionID == summary.identity.extensionID
                    && $0.token.scope == summary.identity.scope
                    && $0.provider.providerID == summary.identity.providerID
            })
        else {
            throw SkillError.providerUnavailable(summary.identity.providerID)
        }
        let resource = try await bounded(owner: registration.token) {
            try await registration.provider.readResource(skill: name, path: path)
        }
        try Task.checkCancellation()
        guard skillProviders[registration.token.id] != nil else {
            throw ExtensionRuntimeError.registrationNotFound
        }
        return resource
    }

    static func validateIdentifier(_ value: String) throws {
        let allowed = value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "."
        }
        guard !value.isEmpty, value.utf8.count <= 128, allowed else {
            throw ExtensionRuntimeError.invalidIdentifier(value)
        }
    }
}

extension ExtensionScope {
    var sortRank: Int {
        switch self {
        case .application: 0
        case .pen: 1
        case .chat: 2
        }
    }
}
