import Darwin
import Dispatch
import Foundation
import Testing

@testable import Herd
@testable import Memory

private struct MemoryConfigurationFixture {
    let parent: URL
    let configuration: URL
    let marker: URL
    let store: MemoryConfigurationStore
}

private func resolvedTemporaryDirectory() throws -> URL {
    let temporaryPath = FileManager.default.temporaryDirectory.path
    var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard temporaryPath.withCString({ Darwin.realpath($0, &resolvedPath) }) != nil else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let bytes = resolvedPath.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
}

private func memoryConfigurationFixture(_ label: String) throws -> MemoryConfigurationFixture {
    // `temporaryDirectory` is commonly spelled through macOS's `/var` root alias.
    // Resolve that test-fixture base before handing it to the fail-closed store so
    // the fixture does not require production code to follow an ancestor symlink.
    let parent = try resolvedTemporaryDirectory().appendingPathComponent(
        "goat-memory-configuration-\(label)-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let configuration = parent.appendingPathComponent("memory.json")
    let marker = parent.appendingPathComponent(".memory-v1-initialized")
    return MemoryConfigurationFixture(
        parent: parent,
        configuration: configuration,
        marker: marker,
        store: MemoryConfigurationStore(
            configurationURL: configuration,
            markerURL: marker))
}

private func rawConfigurationData(_ configuration: MemoryConfiguration) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(configuration)
    data.append(0x0a)
    return data
}

private func validHindsightProvider(
    id: String = "hindsight-00000000-0000-0000-0000-000000000001",
    installationFingerprint: String = String(repeating: "a", count: 64),
    contractFingerprint: String = String(repeating: "b", count: 64)
) -> MemoryProviderRecord {
    MemoryProviderRecord(
        id: MemoryProviderID(rawValue: id),
        displayName: "Hindsight Test",
        kind: .hindsight,
        hindsight: HindsightProviderConfiguration(
            selection: HindsightProviderSelection(
                nodeExecutable: "/usr/local/bin/node",
                packageDirectory: "/private/tmp/hindsight-package",
                workspaceDirectory: "/private/tmp/hindsight-workspace",
                configurationFile: "/private/tmp/hindsight-config.json"),
            expectedIdentity: HindsightExpectedIdentity(
                packageVersion: "0.4.3",
                installationFingerprint: installationFingerprint,
                contractFingerprint: contractFingerprint,
                bankID: "goat-test-bank",
                apiURL: "http://127.0.0.1:8888")))
}

private func directHindsightProvider(
    id: String = "hindsight-00000000-0000-0000-0000-000000000010",
    apiURL: String = "http://127.0.0.1:8888",
    bankID: String = "goat-test-bank"
) -> MemoryProviderRecord {
    MemoryProviderRecord(
        id: MemoryProviderID(rawValue: id),
        displayName: "Hindsight \(bankID)",
        kind: .hindsight,
        hindsight: HindsightProviderConfiguration(
            connection: HindsightBankConnection(apiURL: apiURL, bankID: bankID)))
}

private func hindsightPenRouteProvider(
    id: String = "hindsight-00000000-0000-0000-0000-000000000020",
    serviceProviderID: MemoryProviderID = MemoryProviderID(
        rawValue: "hindsight-00000000-0000-0000-0000-000000000010"),
    bankID: String = "goat-my-pen-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
) -> MemoryProviderRecord {
    MemoryProviderRecord(
        id: MemoryProviderID(rawValue: id),
        displayName: "Hindsight",
        kind: .hindsight,
        hindsight: HindsightProviderConfiguration(
            penRoute: HindsightPenBankRoute(
                serviceProviderID: serviceProviderID,
                bankID: bankID)))
}

private func initializedFixture(_ label: String) throws -> MemoryConfigurationFixture {
    let fixture = try memoryConfigurationFixture(label)
    _ = try fixture.store.loadOrInitialize()
    return fixture
}

private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
}

private func waitForMemoryConfigurationSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: TimeInterval = 5
) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(
                returning: semaphore.wait(timeout: .now() + timeout) == .success)
        }
    }
}

@Suite struct MemoryConfigurationStoreTests {
    @Test func freshProfileCreatesStableOwnerOnlyWikiAuthority() throws {
        let fixture = try memoryConfigurationFixture("fresh")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let loaded = try fixture.store.loadOrInitialize()

        #expect(loaded.configuration == .fresh)
        #expect(loaded.configuration.providers == [.llmWiki, .localWiki])
        #expect(loaded.configuration.global.providerID == .localWiki)
        #expect(loaded.configuration.defaultPenProviderID == .localWiki)
        #expect(loaded.configuration.enabled)
        #expect(loaded.configuration.autoReflectEnabled)
        #expect(loaded.revision.rawValue.utf8.count == 64)
        #expect(
            loaded.revision.rawValue.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
            })
        #expect(try permissions(at: fixture.configuration) & 0o777 == 0o600)
        #expect(try permissions(at: fixture.marker) & 0o777 == 0o600)
        let lock = fixture.parent.appendingPathComponent(
            SecureMemoryConfigurationFileSystem.lockName)
        #expect(try permissions(at: lock) & 0o777 == 0o600)
        #expect(try Data(contentsOf: fixture.marker) == Data("memory-config-v1\n".utf8))

        let original = try Data(contentsOf: fixture.configuration)
        #expect(try fixture.store.loadOrInitialize() == loaded)
        #expect(try Data(contentsOf: fixture.configuration) == original)
    }

    @Test func existingValidConfigurationWithoutMarkerFinishesInitialization() throws {
        let fixture = try initializedFixture("finish-marker")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let original = try Data(contentsOf: fixture.configuration)
        try FileManager.default.removeItem(at: fixture.marker)

        #expect(try fixture.store.loadOrInitialize().configuration == .fresh)
        #expect(try Data(contentsOf: fixture.configuration) == original)
        #expect(try Data(contentsOf: fixture.marker) == Data("memory-config-v1\n".utf8))
    }

    @Test func privateTemporaryPathAuthorityIsPreservedWithoutFilesystemCanonicalization() throws {
        let parentPath = "/private/tmp/goat-memory-path-\(UUID().uuidString)"
        let parent = URL(fileURLWithPath: parentPath, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let configurationPath = "\(parentPath)/memory.json"
        let markerPath = "\(parentPath)/.memory-v1-initialized"
        let configurationData = try rawConfigurationData(.fresh)
        try configurationData.write(to: URL(fileURLWithPath: configurationPath))
        try Data("memory-config-v1\n".utf8).write(to: URL(fileURLWithPath: markerPath))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configurationPath)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: markerPath)
        let store = MemoryConfigurationStore(
            configurationURL: URL(fileURLWithPath: configurationPath),
            markerURL: URL(fileURLWithPath: markerPath))

        #expect(store.configurationURL.path == configurationPath)
        #expect(store.markerURL.path == markerPath)
        #expect(try store.loadOrInitialize().configuration == .fresh)
        #expect(try Data(contentsOf: store.configurationURL) == configurationData)
    }

    @Test func nonlocalOrAmbiguousStoreLocationsFailBeforeWriting() throws {
        let fixture = try memoryConfigurationFixture("unsafe-location")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let invalidStores = [
            MemoryConfigurationStore(
                configurationURL: URL(string: "memory.json")!,
                markerURL: fixture.marker),
            MemoryConfigurationStore(
                configurationURL: fixture.configuration,
                markerURL: fixture.configuration),
            MemoryConfigurationStore(
                configurationURL: fixture.configuration,
                markerURL: fixture.parent.appendingPathComponent("nested/.memory-v1-initialized")),
            MemoryConfigurationStore(
                configurationURL: URL(string: "file:///private/tmp/../tmp/memory.json")!,
                markerURL: URL(string: "file:///private/tmp/../tmp/.memory-v1-initialized")!),
            MemoryConfigurationStore(
                configurationURL: URL(fileURLWithPath: "/memory.json"),
                markerURL: URL(fileURLWithPath: "/.memory-v1-initialized")),
            MemoryConfigurationStore(
                configurationURL: fixture.parent.appendingPathComponent(
                    SecureMemoryConfigurationFileSystem.lockName),
                markerURL: fixture.marker),
            MemoryConfigurationStore(
                configurationURL: fixture.parent.appendingPathComponent(
                    SecureMemoryConfigurationFileSystem.stagingPrefix + "reserved"),
                markerURL: fixture.marker),
        ]

        for store in invalidStores {
            #expect(throws: LocalStoreError.self) {
                _ = try store.loadOrInitialize()
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.configuration.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
    }

    @Test func markerWithoutConfigurationFailsClosedInsteadOfReenablingDefaults() throws {
        let fixture = try initializedFixture("missing-after-initialization")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let marker = try Data(contentsOf: fixture.marker)
        try FileManager.default.removeItem(at: fixture.configuration)

        #expect(throws: LocalStoreError.self) {
            _ = try fixture.store.loadOrInitialize()
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.configuration.path))
        #expect(try Data(contentsOf: fixture.marker) == marker)
    }

    @Test func retainedExchangeStageRequiresManualRecovery() throws {
        let fixture = try initializedFixture("retained-exchange-stage")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let authority = try Data(contentsOf: fixture.configuration)
        let stage = fixture.parent.appendingPathComponent(
            SecureMemoryConfigurationFileSystem.stagingPrefix + UUID().uuidString.lowercased())
        try authority.write(to: stage)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stage.path)

        #expect(throws: LocalStoreError.self) {
            _ = try fixture.store.loadOrInitialize()
        }
        #expect(try Data(contentsOf: fixture.configuration) == authority)
        #expect(try Data(contentsOf: stage) == authority)
    }

    @Test func malformedAndFutureConfigurationBytesRemainUntouched() throws {
        let malformedValues: [Data] = [
            Data("{ definitely not JSON".utf8),
            try rawConfigurationData(
                MemoryConfiguration(
                    schema: MemoryConfiguration.currentSchema + 1,
                    enabled: true,
                    autoReflectEnabled: false,
                    global: GlobalMemoryBinding(providerID: .localWiki, history: [.localWiki]),
                    defaultPenProviderID: .localWiki,
                    pens: [:],
                    providers: [.localWiki])),
        ]

        for (index, data) in malformedValues.enumerated() {
            let fixture = try initializedFixture("malformed-\(index)")
            defer { try? FileManager.default.removeItem(at: fixture.parent) }
            try data.write(to: fixture.configuration)

            #expect(throws: LocalStoreError.self) {
                _ = try fixture.store.loadOrInitialize()
            }
            #expect(try Data(contentsOf: fixture.configuration) == data)
        }
    }

    @Test func malformedMarkerFailsClosedWithoutChangingConfiguration() throws {
        let fixture = try initializedFixture("bad-marker")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let configuration = try Data(contentsOf: fixture.configuration)
        let badMarker = Data("wrong-marker\n".utf8)
        try badMarker.write(to: fixture.marker)

        #expect(throws: LocalStoreError.self) {
            _ = try fixture.store.loadOrInitialize()
        }
        #expect(try Data(contentsOf: fixture.configuration) == configuration)
        #expect(try Data(contentsOf: fixture.marker) == badMarker)
    }

    @Test func oversizedConfigurationIsRejectedWithoutBufferingOrReplacement() throws {
        let fixture = try initializedFixture("oversized")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        try FileManager.default.removeItem(at: fixture.configuration)
        FileManager.default.createFile(atPath: fixture.configuration.path, contents: Data())
        let handle = try FileHandle(forWritingTo: fixture.configuration)
        try handle.truncate(
            atOffset: UInt64(MemoryConfigurationStore.maximumConfigurationBytes + 1))
        try handle.close()

        #expect(throws: LocalStoreError.self) {
            _ = try fixture.store.loadOrInitialize()
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.configuration.path)
        #expect(
            (attributes[.size] as? NSNumber)?.intValue
                == MemoryConfigurationStore.maximumConfigurationBytes + 1)
    }

    @Test func symlinkedConfigurationAndMarkerAreRejectedWithoutTouchingTargets() throws {
        let configurationFixture = try initializedFixture("configuration-symlink")
        defer { try? FileManager.default.removeItem(at: configurationFixture.parent) }
        let outsideConfiguration = configurationFixture.parent.appendingPathComponent("outside.json")
        let outsideData = Data("outside recovery evidence".utf8)
        try outsideData.write(to: outsideConfiguration)
        try FileManager.default.removeItem(at: configurationFixture.configuration)
        try FileManager.default.createSymbolicLink(
            at: configurationFixture.configuration,
            withDestinationURL: outsideConfiguration)

        #expect(throws: LocalStoreError.self) {
            _ = try configurationFixture.store.loadOrInitialize()
        }
        #expect(try Data(contentsOf: outsideConfiguration) == outsideData)

        let markerFixture = try initializedFixture("marker-symlink")
        defer { try? FileManager.default.removeItem(at: markerFixture.parent) }
        let outsideMarker = markerFixture.parent.appendingPathComponent("outside-marker")
        try outsideData.write(to: outsideMarker)
        try FileManager.default.removeItem(at: markerFixture.marker)
        try FileManager.default.createSymbolicLink(
            at: markerFixture.marker,
            withDestinationURL: outsideMarker)

        #expect(throws: LocalStoreError.self) {
            _ = try markerFixture.store.loadOrInitialize()
        }
        #expect(try Data(contentsOf: outsideMarker) == outsideData)
    }

    @Test func ancestorSymlinksAndUnownedModesFailClosed() throws {
        let ancestorFixture = try memoryConfigurationFixture("ancestor-symlink")
        defer { try? FileManager.default.removeItem(at: ancestorFixture.parent) }
        let target = ancestorFixture.parent.appendingPathComponent("target", isDirectory: true)
        let link = ancestorFixture.parent.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linkedStore = MemoryConfigurationStore(
            configurationURL: link.appendingPathComponent("memory.json"),
            markerURL: link.appendingPathComponent(".memory-v1-initialized"))

        #expect(throws: LocalStoreError.self) {
            _ = try linkedStore.loadOrInitialize()
        }
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("memory.json").path))

        let writableFixture = try memoryConfigurationFixture("writable-parent")
        defer { try? FileManager.default.removeItem(at: writableFixture.parent) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: writableFixture.parent.path)
        #expect(throws: LocalStoreError.self) {
            _ = try writableFixture.store.loadOrInitialize()
        }
        #expect(!FileManager.default.fileExists(atPath: writableFixture.configuration.path))
    }

    @Test func authorityAndWriterLockMustRemainOwnerOnlyRegularFiles() throws {
        let authorityFixture = try initializedFixture("authority-mode")
        defer { try? FileManager.default.removeItem(at: authorityFixture.parent) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: authorityFixture.configuration.path)
        #expect(throws: LocalStoreError.self) {
            _ = try authorityFixture.store.loadOrInitialize()
        }
        #expect(try permissions(at: authorityFixture.configuration) & 0o777 == 0o644)

        let lockFixture = try initializedFixture("lock-symlink")
        defer { try? FileManager.default.removeItem(at: lockFixture.parent) }
        let lock = lockFixture.parent.appendingPathComponent(
            SecureMemoryConfigurationFileSystem.lockName)
        let outside = lockFixture.parent.appendingPathComponent("outside-lock")
        let outsideData = Data("do not lock this file".utf8)
        try outsideData.write(to: outside)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: outside.path)
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: outside)

        #expect(throws: LocalStoreError.self) {
            _ = try lockFixture.store.loadOrInitialize()
        }
        #expect(try Data(contentsOf: outside) == outsideData)
    }

    @Test func replacingTheNamedParentCannotRedirectPublication() throws {
        let fixture = try memoryConfigurationFixture("parent-identity")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let loaded = try fixture.store.loadOrInitialize()
        let original = try Data(contentsOf: fixture.configuration)
        let moved = fixture.parent.deletingLastPathComponent().appendingPathComponent(
            fixture.parent.lastPathComponent + "-moved",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: moved) }
        let movedSignal = DispatchSemaphore(value: 0)
        let store = MemoryConfigurationStore(
            configurationURL: fixture.configuration,
            markerURL: fixture.marker,
            testingHooks: MemoryConfigurationStoreTestingHooks(
                beforeConfigurationPublication: {
                    do {
                        try FileManager.default.moveItem(at: fixture.parent, to: moved)
                        try FileManager.default.createDirectory(
                            at: fixture.parent,
                            withIntermediateDirectories: false)
                        movedSignal.signal()
                    } catch {}
                }))
        var proposed = loaded.configuration
        proposed.autoReflectEnabled = false

        #expect(throws: LocalStoreError.self) {
            _ = try store.save(proposed, ifRevision: loaded.revision)
        }
        #expect(movedSignal.wait(timeout: .now()) == .success)
        #expect(!FileManager.default.fileExists(atPath: fixture.configuration.path))
        #expect(
            try Data(contentsOf: moved.appendingPathComponent("memory.json")) == original)
    }

    @Test func invalidProviderReferencesAndPenKeysFailClosed() throws {
        let missing = MemoryProviderID(
            rawValue: "hindsight-00000000-0000-0000-0000-000000000099")
        let lowercasePenID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let invalidConfigurations: [MemoryConfiguration] = [
            {
                var value = MemoryConfiguration.fresh
                value.providers.append(.localWiki)
                return value
            }(),
            {
                var value = MemoryConfiguration.fresh
                value.defaultPenProviderID = missing
                return value
            }(),
            {
                var value = MemoryConfiguration.fresh
                value.global.history.append(missing)
                return value
            }(),
            {
                var value = MemoryConfiguration.fresh
                value.pens[lowercasePenID] = PenMemoryBinding(
                    selection: .inherited(pinnedTo: .localWiki),
                    history: [.localWiki])
                return value
            }(),
            {
                var value = MemoryConfiguration.fresh
                value.providers[0].displayName = "Renamed Wiki"
                return value
            }(),
            {
                var value = MemoryConfiguration.fresh
                value.providers = []
                return value
            }(),
        ]

        for (index, configuration) in invalidConfigurations.enumerated() {
            let fixture = try initializedFixture("invalid-reference-\(index)")
            defer { try? FileManager.default.removeItem(at: fixture.parent) }
            let data = try rawConfigurationData(configuration)
            try data.write(to: fixture.configuration)

            #expect(throws: LocalStoreError.self) {
                _ = try fixture.store.loadOrInitialize()
            }
            #expect(try Data(contentsOf: fixture.configuration) == data)
        }
    }

    @Test func invalidPenSelectionAndHistoryShapesFailClosed() throws {
        let penID = UUID().uuidString
        let invalidBindings = [
            PenMemoryBinding(
                selection: .inherited(pinnedTo: .localWiki),
                history: []),
            PenMemoryBinding(
                selection: .explicit(.localWiki),
                history: [.localWiki, .localWiki]),
        ]

        for (index, binding) in invalidBindings.enumerated() {
            let fixture = try initializedFixture("invalid-binding-\(index)")
            defer { try? FileManager.default.removeItem(at: fixture.parent) }
            var configuration = MemoryConfiguration.fresh
            configuration.pens[penID] = binding
            let data = try rawConfigurationData(configuration)
            try data.write(to: fixture.configuration)

            #expect(throws: LocalStoreError.self) {
                _ = try fixture.store.loadOrInitialize()
            }
            #expect(try Data(contentsOf: fixture.configuration) == data)
        }

        let nilFixture = try initializedFixture("nil-pinned-provider")
        defer { try? FileManager.default.removeItem(at: nilFixture.parent) }
        var configuration = MemoryConfiguration.fresh
        configuration.pens[penID] = PenMemoryBinding(
            selection: .inherited(pinnedTo: .localWiki),
            history: [.localWiki])
        let encoded = try rawConfigurationData(configuration)
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var pens = try #require(object["pens"] as? [String: Any])
        var binding = try #require(pens[penID] as? [String: Any])
        var selection = try #require(binding["selection"] as? [String: Any])
        selection["providerID"] = NSNull()
        binding["selection"] = selection
        pens[penID] = binding
        object["pens"] = pens
        var nilData = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
        nilData.append(0x0a)
        try nilData.write(to: nilFixture.configuration)
        #expect(throws: LocalStoreError.self) {
            _ = try nilFixture.store.loadOrInitialize()
        }
        #expect(try Data(contentsOf: nilFixture.configuration) == nilData)
    }

    @Test func invalidHindsightIdentitiesFailClosed() throws {
        let invalidProviders: [MemoryProviderRecord] = [
            {
                var value = validHindsightProvider()
                value.hindsight?.selection?.nodeExecutable = "node"
                return value
            }(),
            {
                var value = validHindsightProvider()
                value.hindsight?.selection?.packageDirectory = "relative/package"
                return value
            }(),
            {
                var value = validHindsightProvider()
                value.hindsight?.selection?.workspaceDirectory = "/private/tmp/../tmp/workspace"
                return value
            }(),
            {
                var value = validHindsightProvider()
                value.hindsight?.selection?.configurationFile = "config.json"
                return value
            }(),
            validHindsightProvider(
                installationFingerprint: String(repeating: "A", count: 64)),
            validHindsightProvider(
                contractFingerprint: String(repeating: "B", count: 64)),
            {
                var value = validHindsightProvider()
                value.hindsight?.expectedIdentity?.bankID = "bank\nsecond-line"
                return value
            }(),
            {
                var value = validHindsightProvider()
                value.hindsight?.expectedIdentity?.apiURL = "https://user:secret@example.com"
                return value
            }(),
            {
                var value = validHindsightProvider()
                value.hindsight?.expectedIdentity?.apiURL = "http://hindsight.example.com"
                return value
            }(),
            {
                var value = validHindsightProvider()
                value.hindsight?.expectedIdentity?.harness = "codex"
                return value
            }(),
            {
                var value = validHindsightProvider()
                value.id = MemoryProviderID(rawValue: "service-test")
                return value
            }(),
            MemoryProviderRecord(
                id: MemoryProviderID(
                    rawValue: "hindsight-00000000-0000-0000-0000-000000000002"),
                displayName: "Missing identity",
                kind: .hindsight),
        ]

        for (index, provider) in invalidProviders.enumerated() {
            let fixture = try initializedFixture("invalid-hindsight-\(index)")
            defer { try? FileManager.default.removeItem(at: fixture.parent) }
            var configuration = MemoryConfiguration.fresh
            configuration.providers.append(provider)
            let data = try rawConfigurationData(configuration)
            try data.write(to: fixture.configuration)

            #expect(throws: LocalStoreError.self) {
                _ = try fixture.store.loadOrInitialize()
            }
            #expect(try Data(contentsOf: fixture.configuration) == data)
        }
    }

    @Test func directHindsightBankConnectionRoundTripsAndRejectsUnsafeValues() throws {
        let fixture = try initializedFixture("direct-hindsight-bank")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let initial = try fixture.store.loadOrInitialize()
        let provider = directHindsightProvider()
        var configuration = initial.configuration
        configuration.providers.append(provider)

        let saved = try fixture.store.save(configuration, ifRevision: initial.revision)
        let loaded = try fixture.store.loadOrInitialize()
        #expect(
            saved.configuration.providers.first(where: { $0.id == provider.id })?.hindsight?.connection
                == HindsightBankConnection(apiURL: "http://127.0.0.1:8888", bankID: "goat-test-bank"))
        #expect(
            loaded.configuration.providers.first(where: { $0.id == provider.id })?.hindsight?.connection
                == HindsightBankConnection(apiURL: "http://127.0.0.1:8888", bankID: "goat-test-bank"))

        let thunderboltProvider = directHindsightProvider(
            id: "hindsight-00000000-0000-0000-0000-000000000014",
            apiURL: "http://192.168.253.1:8888")
        var privateNetworkConfiguration = saved.configuration
        privateNetworkConfiguration.providers.append(thunderboltProvider)
        let privateNetworkSaved = try fixture.store.save(
            privateNetworkConfiguration,
            ifRevision: saved.revision)
        #expect(
            privateNetworkSaved.configuration.providers.first(where: { $0.id == thunderboltProvider.id })?
                .hindsight?.connection
                == HindsightBankConnection(apiURL: "http://192.168.253.1:8888", bankID: "goat-test-bank"))

        let invalidProviders = [
            directHindsightProvider(
                id: "hindsight-00000000-0000-0000-0000-000000000011", bankID: "GOAT"),
            directHindsightProvider(
                id: "hindsight-00000000-0000-0000-0000-000000000012",
                apiURL: "http://hindsight.example.com"),
            directHindsightProvider(
                id: "hindsight-00000000-0000-0000-0000-000000000013",
                apiURL: "https://hindsight.example.com/mcp/goat"),
        ]
        for invalid in invalidProviders {
            var invalidConfiguration = privateNetworkSaved.configuration
            invalidConfiguration.providers.append(invalid)
            #expect(throws: LocalStoreError.self) {
                _ = try fixture.store.save(invalidConfiguration, ifRevision: privateNetworkSaved.revision)
            }
        }
    }

    @Test func hindsightHTTPPolicyAllowsOnlyLocalNetworkIPv4Addresses() {
        #expect(HindsightEndpointPolicy.permitsHTTP(forHost: "localhost"))
        #expect(HindsightEndpointPolicy.permitsHTTP(forHost: "127.0.0.2"))
        #expect(HindsightEndpointPolicy.permitsHTTP(forHost: "192.168.253.1"))
        #expect(HindsightEndpointPolicy.permitsHTTP(forHost: "fd00::1"))
        #expect(HindsightEndpointPolicy.permitsHTTP(forHost: "fe80::1%en0"))
        #expect(HindsightEndpointPolicy.permitsHTTP(forHost: "10.20.30.40"))
        #expect(HindsightEndpointPolicy.permitsHTTP(forHost: "172.31.1.1"))
        #expect(HindsightEndpointPolicy.permitsHTTP(forHost: "169.254.1.1"))
        #expect(!HindsightEndpointPolicy.permitsHTTP(forHost: "172.32.1.1"))
        #expect(!HindsightEndpointPolicy.permitsHTTP(forHost: "8.8.8.8"))
        #expect(!HindsightEndpointPolicy.permitsHTTP(forHost: "hindsight.example.com"))
    }

    @Test func hindsightPenRouteRoundTripsOnlyWithDirectService() throws {
        let fixture = try initializedFixture("hindsight-pen-route")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let initial = try fixture.store.loadOrInitialize()
        let service = directHindsightProvider()
        let route = hindsightPenRouteProvider(serviceProviderID: service.id)
        var configuration = initial.configuration
        configuration.providers.append(contentsOf: [service, route])

        let saved = try fixture.store.save(configuration, ifRevision: initial.revision)
        let loaded = try fixture.store.loadOrInitialize()

        #expect(
            saved.configuration.providers.first(where: { $0.id == route.id })?.hindsight?.penRoute
                == route.hindsight?.penRoute)
        #expect(
            loaded.configuration.providers.first(where: { $0.id == route.id })?.hindsight?.penRoute
                == route.hindsight?.penRoute)

        var missingService = initial.configuration
        missingService.providers.append(route)
        #expect(throws: LocalStoreError.self) {
            _ = try fixture.store.save(missingService, ifRevision: saved.revision)
        }

        var routeToRoute = initial.configuration
        let secondRoute = hindsightPenRouteProvider(
            id: "hindsight-00000000-0000-0000-0000-000000000021",
            serviceProviderID: route.id,
            bankID: "goat-second-pen-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        routeToRoute.providers.append(contentsOf: [route, secondRoute])
        #expect(throws: LocalStoreError.self) {
            _ = try fixture.store.save(routeToRoute, ifRevision: saved.revision)
        }
    }

    @Test func unknownProviderKindsFailClosed() throws {
        let fixture = try initializedFixture("unknown-provider")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        var configuration = MemoryConfiguration.fresh
        configuration.providers.append(validHindsightProvider())
        let encoded = try rawConfigurationData(configuration)
        let string = try #require(String(data: encoded, encoding: .utf8))
        let changed = string.replacingOccurrences(
            of: "\"kind\" : \"hindsight\"",
            with: "\"kind\" : \"future\"")
        #expect(changed != string)
        let data = Data(changed.utf8)
        try data.write(to: fixture.configuration)

        #expect(throws: LocalStoreError.self) {
            _ = try fixture.store.loadOrInitialize()
        }
        #expect(try Data(contentsOf: fixture.configuration) == data)
    }

    @Test func configuredBoundsAreEnforcedBeforeWriting() throws {
        let providerFixture = try memoryConfigurationFixture("provider-bound")
        defer { try? FileManager.default.removeItem(at: providerFixture.parent) }
        let providerLoaded = try providerFixture.store.loadOrInitialize()
        let providerOriginal = try Data(contentsOf: providerFixture.configuration)
        var tooManyProviders = MemoryConfiguration.fresh
        for index in 0..<(MemoryConfiguration.maximumProviders - tooManyProviders.providers.count + 1) {
            let id = String(
                format: "hindsight-00000000-0000-0000-0000-%012llx",
                UInt64(index + 1))
            tooManyProviders.providers.append(validHindsightProvider(id: id))
        }
        #expect(tooManyProviders.providers.count == MemoryConfiguration.maximumProviders + 1)
        #expect(throws: LocalStoreError.self) {
            _ = try providerFixture.store.save(
                tooManyProviders,
                ifRevision: providerLoaded.revision)
        }
        #expect(try Data(contentsOf: providerFixture.configuration) == providerOriginal)

        let penFixture = try memoryConfigurationFixture("pen-bound")
        defer { try? FileManager.default.removeItem(at: penFixture.parent) }
        let penLoaded = try penFixture.store.loadOrInitialize()
        let penOriginal = try Data(contentsOf: penFixture.configuration)
        var tooManyPens = MemoryConfiguration.fresh
        for index in 0...MemoryConfiguration.maximumPenBindings {
            let id = String(format: "00000000-0000-0000-0000-%012llX", UInt64(index))
            tooManyPens.pens[id] = PenMemoryBinding(
                selection: .inherited(pinnedTo: .localWiki),
                history: [.localWiki])
        }
        #expect(tooManyPens.pens.count == MemoryConfiguration.maximumPenBindings + 1)
        #expect(throws: LocalStoreError.self) {
            _ = try penFixture.store.save(tooManyPens, ifRevision: penLoaded.revision)
        }
        #expect(try Data(contentsOf: penFixture.configuration) == penOriginal)

        let historyFixture = try memoryConfigurationFixture("history-bound")
        defer { try? FileManager.default.removeItem(at: historyFixture.parent) }
        let historyLoaded = try historyFixture.store.loadOrInitialize()
        let historyOriginal = try Data(contentsOf: historyFixture.configuration)
        var tooMuchHistory = MemoryConfiguration.fresh
        tooMuchHistory.global.history = Array(
            repeating: .localWiki,
            count: MemoryConfiguration.maximumHistoryEntries + 1)
        #expect(throws: LocalStoreError.self) {
            _ = try historyFixture.store.save(
                tooMuchHistory,
                ifRevision: historyLoaded.revision)
        }
        #expect(try Data(contentsOf: historyFixture.configuration) == historyOriginal)

        let byteFixture = try memoryConfigurationFixture("byte-bound")
        defer { try? FileManager.default.removeItem(at: byteFixture.parent) }
        let byteLoaded = try byteFixture.store.loadOrInitialize()
        let byteOriginal = try Data(contentsOf: byteFixture.configuration)
        let longComponent = String(repeating: "x", count: 1_100)
        var tooManyBytes = MemoryConfiguration.fresh
        for index in 1..<(MemoryConfiguration.maximumProviders - tooManyBytes.providers.count + 1) {
            let id = String(
                format: "hindsight-00000000-0000-0000-0000-%012llx",
                UInt64(index))
            var provider = validHindsightProvider(id: id)
            provider.hindsight?.selection?.nodeExecutable = "/private/tmp/node-\(longComponent)-\(index)"
            provider.hindsight?.selection?.packageDirectory = "/private/tmp/package-\(longComponent)-\(index)"
            provider.hindsight?.selection?.workspaceDirectory = "/private/tmp/workspace-\(longComponent)-\(index)"
            provider.hindsight?.selection?.configurationFile = "/private/tmp/config-\(longComponent)-\(index)"
            tooManyBytes.providers.append(provider)
        }
        #expect(tooManyBytes.providers.count == MemoryConfiguration.maximumProviders)
        #expect(throws: LocalStoreError.self) {
            _ = try byteFixture.store.save(tooManyBytes, ifRevision: byteLoaded.revision)
        }
        #expect(try Data(contentsOf: byteFixture.configuration) == byteOriginal)
    }

    @Test func providerRecordsAreAppendOnlyAndHindsightRebindUsesANewUUID() throws {
        let fixture = try memoryConfigurationFixture("append-only-providers")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let initial = try fixture.store.loadOrInitialize()
        let first = validHindsightProvider()
        var configuration = initial.configuration
        configuration.providers.append(first)
        let added = try fixture.store.save(configuration, ifRevision: initial.revision)
        let authoritative = try Data(contentsOf: fixture.configuration)

        var renamed = added.configuration
        renamed.providers[0].displayName = "Changed in place"
        var reboundInPlace = added.configuration
        reboundInPlace.providers[0].hindsight?.selection?.workspaceDirectory =
            "/private/tmp/a-different-workspace"
        var changedEvidence = added.configuration
        changedEvidence.providers[0].hindsight?.expectedIdentity?.installationFingerprint =
            String(repeating: "c", count: 64)
        for invalid in [renamed, reboundInPlace, changedEvidence] {
            #expect(throws: LocalStoreError.self) {
                _ = try fixture.store.save(invalid, ifRevision: added.revision)
            }
            #expect(try Data(contentsOf: fixture.configuration) == authoritative)
        }

        let second = validHindsightProvider(
            id: "hindsight-00000000-0000-0000-0000-000000000002")
        var rebound = added.configuration
        rebound.providers.append(second)
        let reboundSaved = try fixture.store.save(rebound, ifRevision: added.revision)

        #expect(reboundSaved.configuration.providers.contains(first))
        #expect(reboundSaved.configuration.providers.contains(second))
        #expect(first.id != second.id)
    }

    @Test func directHindsightConnectionCanBeEditedAndExplicitlyRemoved() throws {
        let fixture = try memoryConfigurationFixture("editable-direct-hindsight")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let initial = try fixture.store.loadOrInitialize()
        let provider = directHindsightProvider()
        let olderProvider = directHindsightProvider(
            id: "hindsight-00000000-0000-0000-0000-000000000011",
            bankID: "older-bank")
        let penID = UUID().uuidString
        var configuredOlder = initial.configuration
        configuredOlder.providers.append(olderProvider)
        configuredOlder.global = GlobalMemoryBinding(
            providerID: olderProvider.id,
            history: [olderProvider.id, .localWiki])
        configuredOlder.defaultPenProviderID = olderProvider.id
        let savedOlder = try fixture.store.save(configuredOlder, ifRevision: initial.revision)

        var configured = savedOlder.configuration
        configured.providers.append(provider)
        configured.global = GlobalMemoryBinding(
            providerID: provider.id,
            history: [provider.id, olderProvider.id, .localWiki])
        configured.defaultPenProviderID = provider.id
        configured.pens[penID] = PenMemoryBinding(
            enabled: false,
            selection: .explicit(provider.id),
            history: [provider.id])
        var saved = try fixture.store.save(configured, ifRevision: savedOlder.revision)

        var edited = saved.configuration
        let editedConnection = HindsightBankConnection(
            apiURL: "https://memory.example.test",
            bankID: "edited-bank")
        let providerIndex = try #require(edited.providers.firstIndex { $0.id == provider.id })
        edited.providers[providerIndex] = MemoryProviderRecord(
            id: provider.id,
            displayName: provider.displayName,
            kind: .hindsight,
            hindsight: HindsightProviderConfiguration(connection: editedConnection))
        saved = try fixture.store.save(edited, ifRevision: saved.revision)
        #expect(saved.configuration.providers[providerIndex].hindsight?.connection == editedConnection)

        var renamedDirect = saved.configuration
        renamedDirect.providers[providerIndex].displayName = "Renamed Hindsight"
        #expect(throws: LocalStoreError.self) {
            _ = try fixture.store.save(renamedDirect, ifRevision: saved.revision)
        }

        var removed = saved.configuration
        let didRemove = removed.removeHindsightProvider(provider.id)
        let didRemoveOlder = removed.removeHindsightProvider(olderProvider.id)
        #expect(didRemove)
        #expect(didRemoveOlder)
        let removal = try fixture.store.save(removed, ifRevision: saved.revision)

        #expect(!removal.configuration.providers.contains { $0.kind == .hindsight })
        #expect(removal.configuration.global.providerID == .localWiki)
        #expect(removal.configuration.global.history == [.localWiki])
        #expect(removal.configuration.defaultPenProviderID == .localWiki)
        #expect(removal.configuration.pens[penID]?.selection == .explicit(.localWiki))
        #expect(removal.configuration.pens[penID]?.history == [.localWiki])
        #expect(removal.configuration.pens[penID]?.enabled == false)
    }

    @Test func globalAndPenHistoryUseExactMoveToFrontAndDisablePreservesBinding() throws {
        let fixture = try memoryConfigurationFixture("binding-transitions")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let initial = try fixture.store.loadOrInitialize()
        let first = validHindsightProvider()
        let second = validHindsightProvider(
            id: "hindsight-00000000-0000-0000-0000-000000000002")
        var providersAdded = initial.configuration
        providersAdded.providers.append(contentsOf: [first, second])
        var saved = try fixture.store.save(providersAdded, ifRevision: initial.revision)

        var wrongGlobal = saved.configuration
        wrongGlobal.global = GlobalMemoryBinding(
            providerID: first.id,
            history: [first.id])
        #expect(throws: LocalStoreError.self) {
            _ = try fixture.store.save(wrongGlobal, ifRevision: saved.revision)
        }

        var firstGlobal = saved.configuration
        firstGlobal.global = GlobalMemoryBinding(
            providerID: first.id,
            history: [first.id, .localWiki])
        saved = try fixture.store.save(firstGlobal, ifRevision: saved.revision)

        var wrongSecondGlobal = saved.configuration
        wrongSecondGlobal.global = GlobalMemoryBinding(
            providerID: second.id,
            history: [second.id, .localWiki, first.id])
        #expect(throws: LocalStoreError.self) {
            _ = try fixture.store.save(wrongSecondGlobal, ifRevision: saved.revision)
        }

        var secondGlobal = saved.configuration
        secondGlobal.global = GlobalMemoryBinding(
            providerID: second.id,
            history: [second.id, first.id, .localWiki])
        saved = try fixture.store.save(secondGlobal, ifRevision: saved.revision)

        let penID = UUID().uuidString
        var wrongNewPen = saved.configuration
        wrongNewPen.pens[penID] = PenMemoryBinding(
            selection: .explicit(first.id),
            history: [first.id, .localWiki])
        #expect(throws: LocalStoreError.self) {
            _ = try fixture.store.save(wrongNewPen, ifRevision: saved.revision)
        }

        var newPen = saved.configuration
        newPen.pens[penID] = PenMemoryBinding(
            selection: .explicit(first.id),
            history: [first.id])
        saved = try fixture.store.save(newPen, ifRevision: saved.revision)

        var movedPen = saved.configuration
        movedPen.pens[penID] = PenMemoryBinding(
            selection: .explicit(second.id),
            history: [second.id, first.id])
        saved = try fixture.store.save(movedPen, ifRevision: saved.revision)

        var removedPen = saved.configuration
        removedPen.pens.removeValue(forKey: penID)
        #expect(throws: LocalStoreError.self) {
            _ = try fixture.store.save(removedPen, ifRevision: saved.revision)
        }
        #expect(try fixture.store.loadOrInitialize().configuration.pens[penID] != nil)

        var changedHistoryOnly = saved.configuration
        changedHistoryOnly.pens[penID]?.history = [second.id]
        #expect(throws: LocalStoreError.self) {
            _ = try fixture.store.save(changedHistoryOnly, ifRevision: saved.revision)
        }

        var disabled = saved.configuration
        disabled.pens[penID]?.enabled = false
        saved = try fixture.store.save(disabled, ifRevision: saved.revision)
        var changedWhileDisabled = saved.configuration
        changedWhileDisabled.pens[penID]?.selection = .explicit(first.id)
        changedWhileDisabled.pens[penID]?.history = [first.id, second.id]
        #expect(throws: LocalStoreError.self) {
            _ = try fixture.store.save(changedWhileDisabled, ifRevision: saved.revision)
        }

        var resumed = saved.configuration
        resumed.pens[penID]?.enabled = true
        let resumedSaved = try fixture.store.save(resumed, ifRevision: saved.revision)
        #expect(resumedSaved.configuration.pens[penID]?.selection.providerID == second.id)
        #expect(resumedSaved.configuration.pens[penID]?.history == [second.id, first.id])

        var disabledAgain = resumedSaved.configuration
        disabledAgain.pens[penID]?.enabled = false
        saved = try fixture.store.save(disabledAgain, ifRevision: resumedSaved.revision)
        var enabledOnCurrentProvider = saved.configuration
        enabledOnCurrentProvider.pens[penID] = PenMemoryBinding(
            enabled: true,
            selection: .explicit(first.id),
            history: [first.id, second.id])
        let movedWhileEnabling = try fixture.store.save(
            enabledOnCurrentProvider,
            ifRevision: saved.revision)
        #expect(movedWhileEnabling.configuration.pens[penID]?.enabled == true)
        #expect(movedWhileEnabling.configuration.pens[penID]?.selection.providerID == first.id)
        #expect(movedWhileEnabling.configuration.pens[penID]?.history == [first.id, second.id])
    }

    @Test func providerIdentityAndHistoryRoundTripAsDeterministicSortedJSON() throws {
        let fixture = try memoryConfigurationFixture("deterministic")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let hindsight = validHindsightProvider()
        let penID = UUID().uuidString
        var configuration = MemoryConfiguration.fresh
        configuration.providers = [.llmWiki, .localWiki, hindsight]
        configuration.global = GlobalMemoryBinding(
            providerID: hindsight.id,
            history: [hindsight.id, .localWiki])
        configuration.defaultPenProviderID = hindsight.id
        configuration.pens[penID] = PenMemoryBinding(
            enabled: false,
            selection: .explicit(hindsight.id),
            history: [hindsight.id])

        let initial = try fixture.store.loadOrInitialize()
        let saved = try fixture.store.save(configuration, ifRevision: initial.revision)
        let first = try Data(contentsOf: fixture.configuration)
        let loaded = try fixture.store.loadOrInitialize()
        let resaved = try fixture.store.save(
            loaded.configuration,
            ifRevision: loaded.revision)
        let second = try Data(contentsOf: fixture.configuration)

        #expect(first == second)
        #expect(first.last == 0x0a)
        let json = try #require(String(data: first, encoding: .utf8))
        #expect(json.contains("\"installationFingerprint\""))
        #expect(json.contains("\"contractFingerprint\""))
        #expect(!json.contains("\"serviceMode\""))
        #expect(saved.revision == loaded.revision)
        #expect(resaved.revision == loaded.revision)
        #expect(loaded.configuration.providers.map(\.id) == [hindsight.id, .llmWiki, .localWiki])
        #expect(loaded.configuration.global.history == [hindsight.id, .localWiki])
        #expect(loaded.configuration.pens[penID]?.history == [hindsight.id])
        #expect(loaded.configuration.pens[penID]?.enabled == false)
        #expect(loaded.configuration.providers.first?.hindsight == hindsight.hindsight)
    }

    @Test func saveRefusesToOverwriteCorruptExistingAuthority() throws {
        let fixture = try initializedFixture("refuse-overwrite")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let loaded = try fixture.store.loadOrInitialize()
        let corrupt = Data("corrupt recovery evidence".utf8)
        try corrupt.write(to: fixture.configuration)

        #expect(throws: LocalStoreError.self) {
            _ = try fixture.store.save(.fresh, ifRevision: loaded.revision)
        }
        #expect(try Data(contentsOf: fixture.configuration) == corrupt)
    }

    @Test func revisionedSaveRejectsAndPreservesAStaleValidExternalEdit() throws {
        let fixture = try memoryConfigurationFixture("stale-valid-edit")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let loaded = try fixture.store.loadOrInitialize()
        var external = loaded.configuration
        external.enabled = false
        let externalData = try rawConfigurationData(external)
        try externalData.write(to: fixture.configuration)

        var proposed = loaded.configuration
        proposed.autoReflectEnabled = false
        #expect(throws: LocalStoreError.self) {
            _ = try fixture.store.save(proposed, ifRevision: loaded.revision)
        }

        #expect(try Data(contentsOf: fixture.configuration) == externalData)
        let reloaded = try fixture.store.loadOrInitialize()
        #expect(reloaded.configuration == external)
        #expect(reloaded.revision != loaded.revision)
    }

    @Test func missingMarkerIsRepairedBeforeConfigurationPublication() throws {
        let fixture = try memoryConfigurationFixture("marker-before-publication")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let loaded = try fixture.store.loadOrInitialize()
        let original = try Data(contentsOf: fixture.configuration)
        try FileManager.default.removeItem(at: fixture.marker)
        let observedRepair = DispatchSemaphore(value: 0)
        let store = MemoryConfigurationStore(
            configurationURL: fixture.configuration,
            markerURL: fixture.marker,
            testingHooks: MemoryConfigurationStoreTestingHooks(
                beforeConfigurationPublication: {
                    if (try? Data(contentsOf: fixture.marker)) == Data("memory-config-v1\n".utf8) {
                        observedRepair.signal()
                    }
                }))
        var proposed = loaded.configuration
        proposed.autoReflectEnabled = false
        _ = try store.save(proposed, ifRevision: loaded.revision)

        #expect(observedRepair.wait(timeout: .now()) == .success)
        #expect(try Data(contentsOf: fixture.configuration) != original)

        let markerRaceFixture = try initializedFixture("marker-race")
        defer { try? FileManager.default.removeItem(at: markerRaceFixture.parent) }
        let markerRaceOriginal = try Data(contentsOf: markerRaceFixture.configuration)
        let markerRaceStore = MemoryConfigurationStore(
            configurationURL: markerRaceFixture.configuration,
            markerURL: markerRaceFixture.marker,
            testingHooks: MemoryConfigurationStoreTestingHooks(
                beforeConfigurationPublication: {
                    try? Data("tampered marker\n".utf8).write(to: markerRaceFixture.marker)
                }))
        var markerRaceProposed = try markerRaceFixture.store.loadOrInitialize().configuration
        markerRaceProposed.enabled = false
        #expect(throws: LocalStoreError.self) {
            _ = try markerRaceStore.save(
                markerRaceProposed,
                ifRevision: markerRaceFixture.store.loadOrInitialize().revision)
        }
        #expect(try Data(contentsOf: markerRaceFixture.configuration) == markerRaceOriginal)

        let blockedFixture = try memoryConfigurationFixture("blocked-marker-repair")
        defer { try? FileManager.default.removeItem(at: blockedFixture.parent) }
        let blockedLoaded = try blockedFixture.store.loadOrInitialize()
        let blockedOriginal = try Data(contentsOf: blockedFixture.configuration)
        try FileManager.default.removeItem(at: blockedFixture.marker)
        try FileManager.default.createDirectory(
            at: blockedFixture.marker,
            withIntermediateDirectories: false)
        var blockedProposed = blockedLoaded.configuration
        blockedProposed.enabled = false
        #expect(throws: LocalStoreError.self) {
            _ = try blockedFixture.store.save(
                blockedProposed,
                ifRevision: blockedLoaded.revision)
        }
        #expect(try Data(contentsOf: blockedFixture.configuration) == blockedOriginal)
    }

    @Test func concurrentSameRevisionWritersSerializeAndPreserveTheWinner() async throws {
        let fixture = try memoryConfigurationFixture("concurrent-cas")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let loaded = try fixture.store.loadOrInitialize()
        let enteredPublication = DispatchSemaphore(value: 0)
        let releasePublication = DispatchSemaphore(value: 0)
        let firstStore = MemoryConfigurationStore(
            configurationURL: fixture.configuration,
            markerURL: fixture.marker,
            testingHooks: MemoryConfigurationStoreTestingHooks(
                beforeConfigurationPublication: {
                    enteredPublication.signal()
                    _ = releasePublication.wait(timeout: .now() + 5)
                }))
        var firstConfiguration = loaded.configuration
        firstConfiguration.enabled = false
        var secondConfiguration = loaded.configuration
        secondConfiguration.autoReflectEnabled = false
        let expectedWinner = firstConfiguration
        let revision = loaded.revision
        let secondStore = fixture.store

        let first = Task.detached {
            @Sendable [firstStore, firstConfiguration, revision] in
            do {
                _ = try firstStore.save(
                    firstConfiguration,
                    ifRevision: revision)
                return true
            } catch {
                return false
            }
        }
        #expect(await waitForMemoryConfigurationSemaphore(enteredPublication))
        let secondStarted = DispatchSemaphore(value: 0)
        let second = Task.detached {
            @Sendable [secondStore, secondConfiguration, revision, secondStarted] in
            secondStarted.signal()
            do {
                _ = try secondStore.save(
                    secondConfiguration,
                    ifRevision: revision)
                return true
            } catch {
                return false
            }
        }
        #expect(await waitForMemoryConfigurationSemaphore(secondStarted))
        releasePublication.signal()

        #expect(await first.value)
        #expect(!(await second.value))
        let authoritative = try fixture.store.loadOrInitialize()
        #expect(authoritative.configuration == expectedWinner)
    }
}
