import Foundation
import Herd
import JUDAS

public struct MemoryProviderID: RawRepresentable, Codable, Sendable, Hashable, Comparable {
    public static let localWiki = MemoryProviderID(rawValue: "local-wiki")
    public static let llmWiki = MemoryProviderID(rawValue: "llm-wiki")

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum MemoryProviderKind: String, Codable, Sendable, Hashable {
    case wiki
    case hindsight
}

/// One explicitly selected Hindsight memory bank. This is a server identity, never a directory
/// on disk. The optional bearer token is held outside the memory configuration in CredentialStore.
public struct HindsightBankConnection: Codable, Sendable, Equatable {
    public var apiURL: String
    public var bankID: String

    public init(apiURL: String, bankID: String) {
        self.apiURL = apiURL
        self.bankID = bankID
    }
}

/// Hindsight permits HTTP on literal local networks, including LAN and Thunderbolt.
/// Public hosts still require TLS; mutable DNS aliases do not acquire local authority.
public enum HindsightEndpointPolicy {
    public static func permitsHTTP(forHost host: String) -> Bool {
        LocalNetworkAddress.contains(host: host)
    }
}

/// One Pen bank routed through GOAT's single configured Hindsight service. The route stores no
/// server URL or credential, so editing the service cannot leave stale per-Pen connections.
public struct HindsightPenBankRoute: Codable, Sendable, Equatable {
    public var serviceProviderID: MemoryProviderID
    public var bankID: String

    public init(serviceProviderID: MemoryProviderID, bankID: String) {
        self.serviceProviderID = serviceProviderID
        self.bankID = bankID
    }
}

/// Immutable, user-approved inputs for launching one managed Hindsight provider.
/// Credentials remain in Hindsight's own configuration and are never copied here.
public struct HindsightProviderSelection: Codable, Sendable, Equatable {
    public var nodeExecutable: String
    public var packageDirectory: String
    public var workspaceDirectory: String

    /// The exact coding-agent configuration used for this binding. The adapter validates its
    /// contents before launch instead of allowing the plugin to fall back to another service.
    public var configurationFile: String

    public init(
        nodeExecutable: String,
        packageDirectory: String,
        workspaceDirectory: String,
        configurationFile: String
    ) {
        self.nodeExecutable = nodeExecutable
        self.packageDirectory = packageDirectory
        self.workspaceDirectory = workspaceDirectory
        self.configurationFile = configurationFile
    }
}

/// Expected evidence captured only after a successful explicit bind. The managed adapter must
/// recompute and compare every field on each process generation. These values never direct launch.
public struct HindsightExpectedIdentity: Codable, Sendable, Equatable {
    public var packageVersion: String
    public var installationFingerprint: String
    public var contractFingerprint: String
    public var bankID: String
    public var apiURL: String
    public var harness: String

    public init(
        packageVersion: String,
        installationFingerprint: String,
        contractFingerprint: String,
        bankID: String,
        apiURL: String,
        harness: String = "goat"
    ) {
        self.packageVersion = packageVersion
        self.installationFingerprint = installationFingerprint
        self.contractFingerprint = contractFingerprint
        self.bankID = bankID
        self.apiURL = apiURL
        self.harness = harness
    }
}

public struct HindsightProviderConfiguration: Codable, Sendable, Equatable {
    /// Direct bank-scoped Hindsight connection used by current GOAT versions.
    public var connection: HindsightBankConnection?

    /// A Pen-specific bank routed through the one direct service connection.
    public var penRoute: HindsightPenBankRoute?

    /// Legacy coding-agent adapter evidence. It is decoded only so an existing configuration can
    /// remain intact and fail closed; GOAT no longer launches this adapter.
    public var selection: HindsightProviderSelection?
    public var expectedIdentity: HindsightExpectedIdentity?

    public init(
        selection: HindsightProviderSelection,
        expectedIdentity: HindsightExpectedIdentity
    ) {
        connection = nil
        penRoute = nil
        self.selection = selection
        self.expectedIdentity = expectedIdentity
    }

    public init(connection: HindsightBankConnection) {
        self.connection = connection
        penRoute = nil
        selection = nil
        expectedIdentity = nil
    }

    public init(penRoute: HindsightPenBankRoute) {
        connection = nil
        self.penRoute = penRoute
        selection = nil
        expectedIdentity = nil
    }
}

public struct MemoryProviderRecord: Codable, Sendable, Equatable, Identifiable {
    public static let localWiki = MemoryProviderRecord(
        id: .localWiki,
        displayName: "Markdown (local)",
        kind: .wiki,
        hindsight: nil)
    public static let llmWiki = MemoryProviderRecord(
        id: .llmWiki,
        displayName: "LLM Wiki (local)",
        kind: .wiki,
        hindsight: nil)

    public var id: MemoryProviderID
    public var displayName: String
    public var kind: MemoryProviderKind
    public var hindsight: HindsightProviderConfiguration?

    public init(
        id: MemoryProviderID,
        displayName: String,
        kind: MemoryProviderKind,
        hindsight: HindsightProviderConfiguration? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.hindsight = hindsight
    }
}

public struct GlobalMemoryBinding: Codable, Sendable, Equatable {
    public var providerID: MemoryProviderID
    /// Unique provider IDs in most-recently-selected order. The active provider is first.
    public var history: [MemoryProviderID]

    public init(providerID: MemoryProviderID, history: [MemoryProviderID]) {
        self.providerID = providerID
        self.history = history
    }
}

public enum PenMemorySelectionKind: String, Codable, Sendable, Hashable {
    case inherit
    case explicit
}

public struct PenMemorySelection: Codable, Sendable, Equatable {
    public var kind: PenMemorySelectionKind
    /// Every persisted Pen is pinned on first use, including an inherited Pen.
    public var providerID: MemoryProviderID

    public init(kind: PenMemorySelectionKind, providerID: MemoryProviderID) {
        self.kind = kind
        self.providerID = providerID
    }

    public static func inherited(pinnedTo providerID: MemoryProviderID) -> Self {
        Self(kind: .inherit, providerID: providerID)
    }

    public static func explicit(_ providerID: MemoryProviderID) -> Self {
        Self(kind: .explicit, providerID: providerID)
    }
}

public struct PenMemoryBinding: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var selection: PenMemorySelection
    /// Unique provider IDs in most-recently-selected order. A pinned provider is first.
    public var history: [MemoryProviderID]

    public init(
        enabled: Bool = true,
        selection: PenMemorySelection,
        history: [MemoryProviderID]
    ) {
        self.enabled = enabled
        self.selection = selection
        self.history = history
    }
}

public struct MemoryConfiguration: Codable, Sendable, Equatable {
    public static let currentSchema = 1
    public static let maximumProviders = 64
    public static let maximumPenBindings = 4_096
    public static let maximumHistoryEntries = 64

    public var schema: Int
    public var enabled: Bool
    public var autoReflectEnabled: Bool
    public var global: GlobalMemoryBinding
    /// Schema-1 compatibility only. Current GOAT versions keep this synchronized with `global`
    /// and do not expose it as a separate default or use it to activate a Pen.
    public var defaultPenProviderID: MemoryProviderID
    public var pens: [String: PenMemoryBinding]
    public var providers: [MemoryProviderRecord]

    public init(
        schema: Int = Self.currentSchema,
        enabled: Bool,
        autoReflectEnabled: Bool,
        global: GlobalMemoryBinding,
        defaultPenProviderID: MemoryProviderID,
        pens: [String: PenMemoryBinding],
        providers: [MemoryProviderRecord]
    ) {
        self.schema = schema
        self.enabled = enabled
        self.autoReflectEnabled = autoReflectEnabled
        self.global = global
        self.defaultPenProviderID = defaultPenProviderID
        self.pens = pens
        self.providers = providers
    }

    public static var fresh: Self {
        Self(
            enabled: true,
            autoReflectEnabled: true,
            global: GlobalMemoryBinding(
                providerID: .localWiki,
                history: [.localWiki]),
            defaultPenProviderID: .localWiki,
            pens: [:],
            // Keep the stable provider record so configurations remain forward-compatible. The
            // application independently gates LLM Wiki capabilities until its lifecycle exists.
            providers: [.llmWiki, .localWiki])
    }

    /// Removes one Hindsight connection from GOAT without touching the server-side bank. Any
    /// GOAT scope that used it is explicitly returned to local Markdown, and the removed provider
    /// is scrubbed from selection history.
    @discardableResult
    public mutating func removeHindsightProvider(_ providerID: MemoryProviderID) -> Bool {
        guard
            let provider = providers.first(where: { $0.id == providerID }),
            provider.kind == .hindsight
        else { return false }

        providers.removeAll { $0.id == providerID }
        if defaultPenProviderID == providerID { defaultPenProviderID = .localWiki }
        global = Self.removing(providerID, from: global)
        pens = pens.mapValues { Self.removing(providerID, from: $0) }
        return true
    }

    private static func removing(
        _ providerID: MemoryProviderID,
        from binding: GlobalMemoryBinding
    ) -> GlobalMemoryBinding {
        let selected = binding.providerID == providerID ? MemoryProviderID.localWiki : binding.providerID
        return GlobalMemoryBinding(
            providerID: selected,
            history: normalizedHistory(binding.history, removing: providerID, selected: selected))
    }

    private static func removing(
        _ providerID: MemoryProviderID,
        from binding: PenMemoryBinding
    ) -> PenMemoryBinding {
        guard binding.selection.providerID == providerID else {
            return PenMemoryBinding(
                enabled: binding.enabled,
                selection: binding.selection,
                history: normalizedHistory(
                    binding.history, removing: providerID, selected: binding.selection.providerID))
        }
        return PenMemoryBinding(
            enabled: binding.enabled,
            selection: .explicit(.localWiki),
            history: normalizedHistory(binding.history, removing: providerID, selected: .localWiki))
    }

    private static func normalizedHistory(
        _ history: [MemoryProviderID],
        removing providerID: MemoryProviderID,
        selected: MemoryProviderID
    ) -> [MemoryProviderID] {
        Array(
            ([selected] + history.filter { $0 != providerID && $0 != selected })
                .prefix(maximumHistoryEntries))
    }
}

extension MemoryConfiguration {
    func validatedCanonical(path: String) throws -> Self {
        guard schema == Self.currentSchema else {
            throw invalid(path, "unsupported memory configuration schema \(schema)")
        }
        guard !providers.isEmpty, providers.count <= Self.maximumProviders else {
            throw invalid(
                path,
                "provider count must be between 1 and \(Self.maximumProviders)")
        }
        guard pens.count <= Self.maximumPenBindings else {
            throw invalid(
                path,
                "Pen binding count exceeds \(Self.maximumPenBindings)")
        }

        var providerIDs = Set<MemoryProviderID>()
        for provider in providers {
            try validateProvider(provider, path: path)
            guard providerIDs.insert(provider.id).inserted else {
                throw invalid(path, "provider ID \(provider.id.rawValue) is duplicated")
            }
        }
        guard providers.filter({ $0.id == .localWiki }).count == 1
        else {
            throw invalid(path, "the stable local-wiki provider record is missing or changed")
        }
        for provider in providers {
            guard let route = provider.hindsight?.penRoute else { continue }
            guard route.serviceProviderID != provider.id,
                let service = providers.first(where: { $0.id == route.serviceProviderID }),
                service.kind == .hindsight,
                service.hindsight?.connection != nil
            else {
                throw invalid(
                    path,
                    "Hindsight Pen route \(provider.id.rawValue) references a missing service")
            }
        }

        try requireProvider(
            defaultPenProviderID,
            in: providerIDs,
            path: path,
            label: "schema-1 compatibility provider")
        try validateHistory(
            global.history,
            current: global.providerID,
            providerIDs: providerIDs,
            path: path,
            label: "Global")

        for (penID, binding) in pens {
            guard let parsed = UUID(uuidString: penID), parsed.uuidString == penID else {
                throw invalid(path, "Pen binding key \(penID) is not a canonical UUID")
            }
            try validateHistory(
                binding.history,
                current: binding.selection.providerID,
                providerIDs: providerIDs,
                path: path,
                label: "Pen \(penID)")
        }

        var canonical = self
        // Presentation-only rename. Existing local configurations remain valid and are rewritten
        // with the current label on their next successful configuration save.
        canonical.providers = canonical.providers.map {
            switch $0.id {
            case .localWiki: .localWiki
            case .llmWiki: .llmWiki
            default: $0
            }
        }
        canonical.providers.sort { $0.id < $1.id }
        return canonical
    }

    func validatedTransition(from previous: Self, path: String) throws -> Self {
        let prior = try previous.validatedCanonical(path: path)
        let next = try validatedCanonical(path: path)
        let nextProviders = Dictionary(uniqueKeysWithValues: next.providers.map { ($0.id, $0) })
        var transitionPrior = prior
        for provider in prior.providers where nextProviders[provider.id] == nil {
            guard transitionPrior.removeHindsightProvider(provider.id) else {
                throw invalid(
                    path,
                    "only a Hindsight configuration can be removed")
            }
        }
        for provider in transitionPrior.providers {
            guard let nextProvider = nextProviders[provider.id] else {
                throw invalid(path, "provider records cannot be removed")
            }
            guard nextProvider == provider || canEditHindsight(provider, to: nextProvider) else {
                throw invalid(
                    path,
                    "only a current bank-scoped Hindsight configuration can be edited in place")
            }
        }

        try validateHistoryTransition(
            from: transitionPrior.global.history,
            current: transitionPrior.global.providerID,
            to: next.global.history,
            next: next.global.providerID,
            path: path,
            label: "Global")

        for (penID, priorBinding) in transitionPrior.pens {
            guard let nextBinding = next.pens[penID] else {
                throw invalid(path, "persisted Pen \(penID) provider binding cannot be removed")
            }
            if !nextBinding.enabled {
                guard priorBinding.selection == nextBinding.selection,
                    priorBinding.history == nextBinding.history
                else {
                    throw invalid(path, "disabled Pen \(penID) must preserve its provider binding")
                }
                continue
            }
            if priorBinding.selection.providerID != nextBinding.selection.providerID {
                guard nextBinding.selection.kind == .explicit else {
                    throw invalid(
                        path,
                        "Pen \(penID) must explicitly select a different provider")
                }
            }
            try validateHistoryTransition(
                from: priorBinding.history,
                current: priorBinding.selection.providerID,
                to: nextBinding.history,
                next: nextBinding.selection.providerID,
                path: path,
                label: "Pen \(penID)")
        }

        for (penID, binding) in next.pens where prior.pens[penID] == nil {
            guard binding.history == [binding.selection.providerID] else {
                throw invalid(path, "new Pen \(penID) must start with only its pinned provider")
            }
            if binding.selection.kind == .inherit {
                guard binding.selection.providerID == next.defaultPenProviderID else {
                    throw invalid(
                        path,
                        "legacy inherited Pen \(penID) must pin the schema-1 compatibility provider")
                }
            }
        }
        return next
    }

    private func canEditHindsight(
        _ previous: MemoryProviderRecord,
        to next: MemoryProviderRecord
    ) -> Bool {
        previous.id == next.id
            && previous.displayName == next.displayName
            && previous.kind == .hindsight
            && next.kind == .hindsight
            && previous.hindsight?.connection != nil
            && next.hindsight?.connection != nil
    }

    private func validateHistoryTransition(
        from history: [MemoryProviderID],
        current: MemoryProviderID,
        to nextHistory: [MemoryProviderID],
        next: MemoryProviderID,
        path: String,
        label: String
    ) throws {
        guard current != next else {
            guard history == nextHistory else {
                throw invalid(path, "\(label) history changed without a provider change")
            }
            return
        }
        var expected = [next]
        expected.append(contentsOf: history.filter { $0 != next })
        if expected.count > Self.maximumHistoryEntries {
            expected.removeLast(expected.count - Self.maximumHistoryEntries)
        }
        guard nextHistory == expected else {
            throw invalid(path, "\(label) history is not the exact move-to-front transition")
        }
    }

    private func validateProvider(_ provider: MemoryProviderRecord, path: String) throws {
        try validateProviderID(provider.id, path: path)
        try validateDisplayName(provider.displayName, path: path)
        switch provider.kind {
        case .wiki:
            guard provider.hindsight == nil else {
                throw invalid(path, "local Wiki providers cannot have a Hindsight identity")
            }
            let isMarkdown =
                provider.id == .localWiki
                && ["Markdown (local)", "LLM Wiki (local)", "Local Wiki"].contains(provider.displayName)
            let isLLMWiki = provider.id == .llmWiki && provider.displayName == "LLM Wiki (local)"
            guard isMarkdown || isLLMWiki
            else {
                throw invalid(path, "unknown local Wiki provider in schema 1")
            }
        case .hindsight:
            let prefix = "hindsight-"
            let suffix = String(provider.id.rawValue.dropFirst(prefix.count))
            guard provider.id.rawValue.hasPrefix(prefix),
                let uuid = UUID(uuidString: suffix),
                suffix == uuid.uuidString.lowercased()
            else {
                throw invalid(path, "Hindsight provider IDs must be hindsight- followed by a UUID")
            }
            guard let identity = provider.hindsight else {
                throw invalid(path, "Hindsight provider \(provider.id.rawValue) has no identity")
            }
            try validateHindsight(identity, path: path, providerID: provider.id)
        }
    }

    private func validateProviderID(_ id: MemoryProviderID, path: String) throws {
        let bytes = Array(id.rawValue.utf8)
        guard !bytes.isEmpty, bytes.count <= 96,
            bytes.first != 45,
            bytes.last != 45,
            bytes.allSatisfy({ byte in
                (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45
            })
        else {
            throw invalid(path, "provider ID \(id.rawValue) is not a canonical safe slug")
        }
    }

    private func validateDisplayName(_ value: String, path: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == trimmed, !value.isEmpty, value.utf8.count <= 128,
            !containsControlCharacter(value)
        else {
            throw invalid(path, "provider display name is invalid")
        }
    }

    private func validateHindsight(
        _ configuration: HindsightProviderConfiguration,
        path: String,
        providerID: MemoryProviderID
    ) throws {
        if let connection = configuration.connection {
            guard configuration.penRoute == nil,
                configuration.selection == nil,
                configuration.expectedIdentity == nil
            else {
                throw invalid(path, "Hindsight provider must use one connection format")
            }
            try validateHindsightBank(connection, path: path, providerID: providerID)
            return
        }

        if let route = configuration.penRoute {
            guard configuration.selection == nil, configuration.expectedIdentity == nil else {
                throw invalid(path, "Hindsight provider must use one connection format")
            }
            try validateProviderID(route.serviceProviderID, path: path)
            try validateHindsightBankID(route.bankID, path: path, providerID: providerID)
            return
        }

        guard let selection = configuration.selection, let identity = configuration.expectedIdentity else {
            throw invalid(path, "Hindsight provider \(providerID.rawValue) has no connection")
        }
        try validateAbsolutePath(selection.nodeExecutable, path: path, label: "Node executable")
        try validateAbsolutePath(selection.packageDirectory, path: path, label: "package directory")
        try validateAbsolutePath(selection.workspaceDirectory, path: path, label: "workspace directory")
        try validateAbsolutePath(selection.configurationFile, path: path, label: "configuration file")
        try validateBoundedText(
            identity.packageVersion,
            maximumBytes: 64,
            path: path,
            label: "package version")
        try validateBoundedText(identity.bankID, maximumBytes: 256, path: path, label: "bank ID")
        try validateFingerprint(
            identity.installationFingerprint,
            path: path,
            providerID: providerID,
            label: "installation")
        try validateFingerprint(
            identity.contractFingerprint,
            path: path,
            providerID: providerID,
            label: "contract")
        guard identity.harness == "goat" else {
            throw invalid(path, "Hindsight provider \(providerID.rawValue) has the wrong harness")
        }
        guard identity.apiURL.utf8.count <= 2_048,
            !containsControlCharacter(identity.apiURL),
            let components = URLComponents(string: identity.apiURL),
            let scheme = components.scheme,
            scheme == scheme.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host,
            !host.isEmpty,
            host == host.lowercased(),
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.string == identity.apiURL
        else {
            throw invalid(path, "Hindsight provider \(providerID.rawValue) has an invalid API URL")
        }
        if scheme == "http", !HindsightEndpointPolicy.permitsHTTP(forHost: host) {
            throw invalid(
                path,
                "public Hindsight providers must use HTTPS")
        }
    }

    private func validateHindsightBank(
        _ connection: HindsightBankConnection,
        path: String,
        providerID: MemoryProviderID
    ) throws {
        try validateHindsightBankID(connection.bankID, path: path, providerID: providerID)
        guard connection.apiURL.utf8.count <= 2_048,
            !containsControlCharacter(connection.apiURL),
            let components = URLComponents(string: connection.apiURL),
            let scheme = components.scheme,
            scheme == scheme.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host,
            !host.isEmpty,
            host == host.lowercased(),
            components.path.isEmpty || components.path == "/",
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.string == connection.apiURL
        else {
            throw invalid(path, "Hindsight provider \(providerID.rawValue) has an invalid API URL")
        }
        if scheme == "http", !HindsightEndpointPolicy.permitsHTTP(forHost: host) {
            throw invalid(path, "public Hindsight providers must use HTTPS")
        }
    }

    private func validateHindsightBankID(
        _ bankID: String,
        path: String,
        providerID: MemoryProviderID
    ) throws {
        guard bankID.utf8.count <= 128,
            !bankID.isEmpty,
            bankID.utf8.allSatisfy({ byte in
                (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45 || byte == 95
            })
        else {
            throw invalid(path, "Hindsight provider \(providerID.rawValue) has an invalid bank ID")
        }
    }

    private func validateFingerprint(
        _ value: String,
        path: String,
        providerID: MemoryProviderID,
        label: String
    ) throws {
        guard value.utf8.count == 64,
            value.utf8.allSatisfy({ byte in
                (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
            })
        else {
            throw invalid(
                path,
                "Hindsight provider \(providerID.rawValue) has an invalid \(label) fingerprint")
        }
    }

    private func validateAbsolutePath(_ value: String, path: String, label: String) throws {
        guard !value.isEmpty, value.utf8.count <= 4_096,
            value.hasPrefix("/"),
            !containsControlCharacter(value),
            !value.hasSuffix("/"),
            value.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                .allSatisfy({ component in
                    !component.isEmpty && component != "." && component != ".."
                })
        else {
            throw invalid(path, "Hindsight \(label) is not a canonical absolute path")
        }
    }

    private func validateBoundedText(
        _ value: String,
        maximumBytes: Int,
        path: String,
        label: String
    ) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == trimmed, !value.isEmpty, value.utf8.count <= maximumBytes,
            !containsControlCharacter(value)
        else {
            throw invalid(path, "Hindsight \(label) is invalid")
        }
    }

    private func validateHistory(
        _ history: [MemoryProviderID],
        current: MemoryProviderID,
        providerIDs: Set<MemoryProviderID>,
        path: String,
        label: String
    ) throws {
        guard !history.isEmpty, history.count <= Self.maximumHistoryEntries,
            history.first == current,
            Set(history).count == history.count
        else {
            throw invalid(path, "\(label) provider history is not canonical")
        }
        for providerID in history {
            try requireProvider(providerID, in: providerIDs, path: path, label: "\(label) history")
        }
    }

    private func requireProvider(
        _ providerID: MemoryProviderID,
        in providerIDs: Set<MemoryProviderID>,
        path: String,
        label: String
    ) throws {
        guard providerIDs.contains(providerID) else {
            throw invalid(path, "\(label) references missing provider \(providerID.rawValue)")
        }
    }

    private func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7f
        }
    }

    private func invalid(_ path: String, _ reason: String) -> LocalStoreError {
        LocalStoreError.invalidData(path: path, reason: reason)
    }
}
