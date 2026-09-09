import Foundation
import Herd
import Inference
import XCTest

@testable import GOAT

@MainActor final class EngineSetupTests: XCTestCase {
    func testFreshInstallHasNoImplicitConnection() {
        for settings in [
            LegacyEngineSettings(endpoint: nil, presetID: nil),
            LegacyEngineSettings(endpoint: "  ", presetID: "custom"),
            LegacyEngineSettings(endpoint: nil, presetID: "removed-preset"),
        ] {
            let file = StartupDiskLoader.fallbackEngineFile(settings)
            XCTAssertTrue(file.engines.isEmpty)
            XCTAssertNil(file.active)
        }
    }

    func testLegacyConnectionsKeepTheirAddressAndPreset() throws {
        let custom = StartupDiskLoader.fallbackEngineFile(
            LegacyEngineSettings(endpoint: "http://127.0.0.1:9123", presetID: nil))
        XCTAssertEqual(custom.engines.first?.url, "http://127.0.0.1:9123")
        XCTAssertEqual(custom.engines.first?.preset.id, "custom")
        XCTAssertEqual(custom.active, custom.engines.first?.id)
        let named = StartupDiskLoader.fallbackEngineFile(
            LegacyEngineSettings(endpoint: nil, presetID: "ollama"))
        XCTAssertEqual(named.engines.first?.url, EnginePreset.with(id: "ollama").url)
        XCTAssertEqual(named.engines.first?.presetID, "ollama")
    }

    func testStoredListIncludingEmptyListOverridesLegacyDefaults() throws {
        try requireIsolatedHome()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("engines.json")
        let profile = EngineProfile(id: "saved", name: "My server", url: "http://127.0.0.1:9123")
        let legacy = LegacyEngineSettings(endpoint: "http://127.0.0.1:8000", presetID: "omlx")
        for profiles in [[profile], []] {
            let stored = EngineStore.File(active: profiles.first?.id, engines: profiles)
            try EngineStore.save(stored, to: url)
            let restored = try StartupDiskLoader.loadOrMigrateEngines(legacy, at: url).file
            XCTAssertEqual(restored.engines, profiles)
            XCTAssertEqual(restored.active, stored.active)
        }
    }

    func testFreshEmptyListPersistsAndCorruptFileIsNotReplaced() throws {
        try requireIsolatedHome()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("engines.json")
        let legacy = LegacyEngineSettings(endpoint: nil, presetID: nil)
        let loaded = try StartupDiskLoader.loadOrMigrateEngines(legacy, at: url).file
        XCTAssertTrue(loaded.engines.isEmpty)
        XCTAssertNotNil(try EngineStore.load(from: url))
        let invalid = Data("{invalid".utf8)
        try invalid.write(to: url)
        XCTAssertThrowsError(try StartupDiskLoader.loadOrMigrateEngines(legacy, at: url))
        XCTAssertEqual(try Data(contentsOf: url), invalid)
    }

    func testSetupRequestRequiresReadyWritableEmptyStoreAndIsConsumedOnce() {
        let model = AppModel.shared
        let previous = (
            model.startupPhase, model.engineProfiles, model.engineStoreWritable,
            model.shouldPresentEngineSetup, model.settingsTab
        )
        defer {
            (
                model.startupPhase, model.engineProfiles, model.engineStoreWritable,
                model.shouldPresentEngineSetup, model.settingsTab
            ) = previous
        }
        model.engineProfiles = []
        model.engineStoreWritable = true
        model.shouldPresentEngineSetup = true
        model.startupPhase = .restoringLocalState
        XCTAssertFalse(model.consumeEngineSetupRequest())
        model.startupPhase = .ready
        model.engineStoreWritable = false
        XCTAssertFalse(model.consumeEngineSetupRequest())
        model.engineStoreWritable = true
        model.engineProfiles = [EngineProfile(id: "saved", name: "Saved", url: "http://127.0.0.1:9123")]
        XCTAssertFalse(model.consumeEngineSetupRequest())
        model.engineProfiles = []
        XCTAssertTrue(model.consumeEngineSetupRequest())
        XCTAssertEqual(model.settingsTab, .engine)
        XCTAssertFalse(model.consumeEngineSetupRequest())
    }

    func testFirstSaveActivatesEngineAndFailedSaveRollsBackSelection() async throws {
        try requireIsolatedHome()
        let model = AppModel.shared
        let previous = (
            model.startupPhase, model.engineProfiles, model.activeEngineID,
            model.engineStoreWritable, model.dbWarning, model.installedEngineApplicationPaths
        )
        let originalFile = try? Data(contentsOf: Home.enginesFile)
        defer {
            (
                model.startupPhase, model.engineProfiles, model.activeEngineID,
                model.engineStoreWritable, model.dbWarning, model.installedEngineApplicationPaths
            ) = previous
            if let originalFile {
                try? originalFile.write(to: Home.enginesFile)
            } else {
                try? FileManager.default.removeItem(at: Home.enginesFile)
            }
        }
        model.startupPhase = .ready
        model.engineProfiles = []
        model.activeEngineID = ""
        model.engineStoreWritable = false
        let first = EngineProfile(id: "first", name: "First", url: "http://127.0.0.1:9123")
        let rejected = await model.addOrUpdateEngine(first, connect: false)
        XCTAssertFalse(rejected)
        XCTAssertTrue(model.engineProfiles.isEmpty)
        XCTAssertEqual(model.activeEngineID, "")
        model.engineStoreWritable = true
        let intent = model.engineIntentRevision
        let saved = await model.addOrUpdateEngine(first, connect: false)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.activeEngineID, first.id)
        let second = EngineProfile(id: "second", name: "Second", url: "http://127.0.0.1:9124")
        let added = await model.addOrUpdateEngine(second, connect: false)
        XCTAssertTrue(added)
        XCTAssertEqual(model.activeEngineID, first.id)
        let stored = try XCTUnwrap(try EngineStore.load(from: Home.enginesFile))
        XCTAssertEqual(stored.active, first.id)
        XCTAssertEqual(stored.engines, [first, second])
        XCTAssertEqual(
            model.engineIntentRevision, intent, "Batch saves must not begin a connection before the key is saved")
    }

    private func requireIsolatedHome() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["GOAT_TEST_MODE"] == "1" && environment["GOAT_HOME"] != nil,
            "Disk setup tests require an isolated GOAT_HOME")
    }
}
