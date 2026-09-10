import Darwin
import Foundation
import Testing

@testable import GOAT

private struct UninstallFixture {
    let root: URL
    var request: UninstallRequest

    init(groups: Set<String> = []) throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let support = root.appendingPathComponent("support")
        let app = root.appendingPathComponent("GOAT.app")
        let recovery = root.appendingPathComponent("recovery")
        for folder in [home, support, app.appendingPathComponent("Contents"), recovery] {
            try fm.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let domain = "dev.leet.goat.fixture.\(UUID().uuidString)"
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": domain], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        request = UninstallRequest(
            parentPID: Int32.max, home: home, support: support, app: app,
            preferencesDomain: domain, keepPreferences: true, removedGroups: groups, protectedPaths: [],
            recovery: recovery)
        try request.captureRoots()
    }

    func write(_ path: String, text: String = "retain these bytes") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test func partialUninstallDefaultsKeepHomeAndChatsButRemoveAppPreferences() {
    var plan = DataManagementPlan()
    plan.action = .uninstall
    #expect(!plan.keepPreferences)
    #expect(plan.uninstallMode == .partial)
    #expect(plan.keepsHomeData)
    #expect(plan.groups.isEmpty)
    #expect(plan.affected == ["The selected GOAT app copy", "macOS app preferences and saved window state"])
    plan.keepsHomeData = false
    #expect(plan.groups.contains(.pens))
    #expect(plan.groups.contains(.chats))
    plan.select(.chats, included: false)
    #expect(!plan.groups.contains(.pens))
}

@Test func appOnlyUninstallLeavesHomeChatsAndPreferencesUntouched() throws {
    let fixture = try UninstallFixture()
    defer { fixture.clean() }
    let chat = try fixture.write("support/goat.sqlite")
    let secret = try fixture.write("home/config/credentials.json")
    var trashed: [URL] = []
    try UninstallOperation.execute(fixture.request) { trashed.append($0) }
    #expect(trashed == [fixture.request.app])
    #expect(try Data(contentsOf: chat) == Data("retain these bytes".utf8))
    #expect(FileManager.default.fileExists(atPath: secret.path))
}

@Test func selectedDataMovesWithDatabaseCompanionsWhileLinksAndUnknownFilesStay() throws {
    let fixture = try UninstallFixture(groups: [
        DataManagementPlan.Group.chats.rawValue, DataManagementPlan.Group.memory.rawValue,
    ])
    defer { fixture.clean() }
    let memory = try fixture.write("home/memory/notes.md")
    let unknown = try fixture.write("home/owner.txt")
    let external = try fixture.write("external/keep.md")
    try FileManager.default.createSymbolicLink(
        at: fixture.request.home.appendingPathComponent("memory/linked.md"), withDestinationURL: external)
    for name in ["goat.sqlite", "goat.sqlite-wal", "goat.sqlite-shm", "Attachments/image.png"] {
        _ = try fixture.write("support/\(name)")
    }
    try UninstallOperation.execute(fixture.request) { _ in }
    #expect(!FileManager.default.fileExists(atPath: memory.path))
    #expect(FileManager.default.fileExists(atPath: unknown.path))
    #expect(FileManager.default.fileExists(atPath: external.path))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: fixture.request.home.appendingPathComponent("memory/linked.md").path) == external.path)
    for name in ["goat.sqlite", "goat.sqlite-wal", "goat.sqlite-shm", "Attachments/image.png"] {
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.request.recovery.appendingPathComponent("data/application-support/\(name)").path))
    }
    let completed = try JSONDecoder().decode(
        [UninstallMove].self, from: Data(contentsOf: fixture.request.recovery.appendingPathComponent("completed.json")))
    #expect(completed.count == 5)
}

@Test func runningHostAndChangedRootsCannotStartRemoval() throws {
    var fixture = try UninstallFixture(groups: [DataManagementPlan.Group.chats.rawValue])
    defer { fixture.clean() }
    let chat = try fixture.write("support/goat.sqlite")
    fixture.request.parentPID = getpid()
    #expect(throws: UninstallError.self) {
        try UninstallOperation.execute(fixture.request) { _ in Issue.record("Must not trash") }
    }
    fixture.request.parentPID = Int32.max
    try FileManager.default.moveItem(
        at: fixture.request.support, to: fixture.root.appendingPathComponent("old-support"))
    try FileManager.default.createSymbolicLink(
        at: fixture.request.support, withDestinationURL: fixture.root.appendingPathComponent("old-support"))
    #expect(throws: UninstallError.self) {
        try UninstallOperation.execute(fixture.request) { _ in Issue.record("Must not trash") }
    }
    #expect(FileManager.default.fileExists(atPath: chat.path))
}

@Test func nestedExternalWorkspaceBlocksBeforeAnyDataIsMoved() throws {
    var fixture = try UninstallFixture(groups: [DataManagementPlan.Group.memory.rawValue])
    defer { fixture.clean() }
    let note = try fixture.write("home/memory/global.md")
    let external = try fixture.write("home/memory/workspace/source.swift")
    fixture.request.protectedPaths = [external.deletingLastPathComponent()]
    #expect(throws: UninstallError.self) {
        try UninstallOperation.execute(fixture.request) { _ in Issue.record("Must not trash") }
    }
    #expect(FileManager.default.fileExists(atPath: note.path))
    #expect(FileManager.default.fileExists(atPath: external.path))
}

@Test func trashFailureRetainsRecoverableDataAndCompletedManifest() throws {
    let fixture = try UninstallFixture(groups: [DataManagementPlan.Group.connections.rawValue])
    defer { fixture.clean() }
    _ = try fixture.write("home/config/credentials.json")
    #expect(throws: UninstallError.self) {
        try UninstallOperation.execute(fixture.request) { _ in throw UninstallError.unsafe("Fixture Trash unavailable")
        }
    }
    #expect(FileManager.default.fileExists(atPath: fixture.request.app.path))
    #expect(
        FileManager.default.fileExists(
            atPath: fixture.request.recovery.appendingPathComponent("data/home/config/credentials.json").path))
    #expect(
        FileManager.default.fileExists(atPath: fixture.request.recovery.appendingPathComponent("completed.json").path))
}

@Test func removedPreferencesAreBackedUpWithoutClearingOtherDomains() throws {
    var fixture = try UninstallFixture()
    defer { fixture.clean() }
    let defaults = UserDefaults.standard
    let domain = fixture.request.preferencesDomain
    let other = domain + ".other"
    defer {
        defaults.removePersistentDomain(forName: domain)
        defaults.removePersistentDomain(forName: other)
    }
    defaults.setPersistentDomain(["theme": "pasture", "goat.home": fixture.request.home.path], forName: domain)
    defaults.setPersistentDomain(["keep": true], forName: other)
    fixture.request.keepPreferences = false
    try UninstallOperation.execute(fixture.request) { _ in }
    #expect(defaults.persistentDomain(forName: domain)?.isEmpty != false)
    #expect(defaults.persistentDomain(forName: other)?["keep"] as? Bool == true)
    let plist = fixture.request.recovery.appendingPathComponent("preferences.plist")
    let restored =
        try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
    #expect(restored?["theme"] as? String == "pasture")
    #expect(
        (try FileManager.default.attributesOfItem(atPath: plist.path)[.posixPermissions] as? NSNumber)?.intValue
            == 0o600)
}

@Test func maintenanceLockExcludesOtherWritersAndRejectsLinkedLockFiles() throws {
    let fixture = try UninstallFixture()
    defer { fixture.clean() }
    let path = fixture.root.appendingPathComponent("lock").path
    let shared = try MaintenanceGate.acquire(exclusive: false, path: path)
    #expect(throws: UninstallError.self) { _ = try MaintenanceGate.acquire(exclusive: true, path: path) }
    close(shared)
    let exclusive = try MaintenanceGate.acquire(exclusive: true, path: path)
    #expect(throws: UninstallError.self) { _ = try MaintenanceGate.acquire(exclusive: false, path: path) }
    close(exclusive)
    let link = fixture.root.appendingPathComponent("linked-lock")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: path)
    #expect(throws: UninstallError.self) { _ = try MaintenanceGate.acquire(exclusive: true, path: link.path) }
}

@Test func recoveryMustRemainPrivateBeforeAnySourceMove() throws {
    let fixture = try UninstallFixture(groups: [DataManagementPlan.Group.connections.rawValue])
    defer { fixture.clean() }
    let credentials = try fixture.write("home/config/credentials.json")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.request.recovery.path)
    #expect(throws: UninstallError.self) {
        try UninstallOperation.execute(fixture.request) { _ in Issue.record("Must not trash") }
    }
    #expect(FileManager.default.fileExists(atPath: credentials.path))
}
