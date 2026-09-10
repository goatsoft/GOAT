import Foundation
import Testing

@testable import GOAT

@Test func removingPenMetadataIncludesItsChatRelationships() {
    var plan = DataManagementPlan()
    plan.action = .uninstall
    #expect(plan.groups.isEmpty)
    plan.select(.pens, included: true)
    #expect(plan.groups == [.pens, .chats])
    plan.select(.chats, included: false)
    #expect(plan.groups.isEmpty)
    plan.select(.connections, included: true)
    #expect(plan.kept.contains("Chats and attachments"))
    #expect(plan.kept.contains("External Pen workspaces and project files"))
}

@Test func uninstallAndPreferencePlansKeepLocalDataAndCustomHome() {
    var plan = DataManagementPlan()
    #expect(plan.kept.contains("GOAT Home location"))
    plan.select(.chats, included: true)
    plan.action = .uninstall
    #expect(plan.kept.contains("Chats and attachments"))
    #expect(plan.affected.contains("macOS app preferences and saved window state"))
    #expect(plan.kept.contains("Any separately installed CLI"))
    plan.cliURL = URL(fileURLWithPath: "/custom/bin/goat")
    #expect(plan.affected.contains("The separately selected CLI copy"))
    #expect(!plan.kept.contains("Any separately installed CLI"))
}

@Test func uninstallPresetsResetKeepOptionsAndAllowPartialAdjustments() {
    var plan = DataManagementPlan()
    plan.action = .uninstall
    plan.keepPreferences = true
    plan.uninstallMode = .all
    #expect(!plan.keepPreferences)
    #expect(!plan.keepsHomeData)
    #expect(plan.groups == Set(DataManagementPlan.Group.allCases))
    #expect(plan.uninstallMode == .all)
    #expect(plan.kept.contains("External Pen workspaces and project files"))
    #expect(plan.kept.contains("Any separately installed CLI"))

    plan.select(.chats, included: false)
    #expect(plan.uninstallMode == .partial)
    #expect(!plan.groups.contains(.pens))
    #expect(plan.groups.contains(.memory))

    plan.uninstallMode = .all
    plan.keepPreferences = true
    #expect(plan.uninstallMode == .partial)
    plan.uninstallMode = .all
    plan.uninstallMode = .partial
    #expect(plan.groups.isEmpty)
    #expect(plan.keepsHomeData)
    #expect(!plan.keepPreferences)
}

@Test func inventoryOnlyInspectsMetadataAndPreservesLinkedTargets() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("custom-home")
    let support = root.appendingPathComponent("separate-support")
    let target = root.appendingPathComponent("external-project")
    for folder in [home, support, target] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let contents = Data("Keep this external file unchanged".utf8)
    let sentinel = target.appendingPathComponent("keep.txt")
    try contents.write(to: sentinel)
    try FileManager.default.createSymbolicLink(
        at: home.appendingPathComponent("projects"), withDestinationURL: target)
    let snapshot = DataManagementInventory(
        home: home, support: support, app: root.appendingPathComponent("GOAT.app"),
        homeSource: "Settings override", preferencesDomain: "dev.leet.goat.test")
    let inventory = snapshot.inspected()
    #expect(inventory.locations.first { $0.id == "home" }?.status == .folder)
    #expect(inventory.locations.first { $0.id == "pens" }?.status == .linked)
    #expect(inventory.locations.first { $0.id == "database" }?.status == .missing)
    #expect(inventory.locations.first { $0.id == "database" }?.url.deletingLastPathComponent().path == support.path)
    #expect(try Data(contentsOf: sentinel) == contents)
    #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("goat.sqlite").path))
    var plan = DataManagementPlan()
    plan.backupURL = home.appendingPathComponent("backups")
    #expect(plan.backupWarning(inventory: inventory) != nil)
    plan.backupURL = support
    #expect(plan.backupWarning(inventory: inventory) != nil)
    plan.backupURL = root.appendingPathComponent("custom-home-backup")
    #expect(plan.backupWarning(inventory: inventory) == nil)
    let linkedBackup = root.appendingPathComponent("linked-backup")
    try FileManager.default.createSymbolicLink(at: linkedBackup, withDestinationURL: home)
    plan.backupURL = linkedBackup
    #expect(plan.backupWarning(inventory: inventory) != nil)
    let sharedRoot = DataManagementInventory(
        home: URL(fileURLWithPath: "/"), support: support, app: root.appendingPathComponent("GOAT.app"),
        homeSource: "Settings override", preferencesDomain: "dev.leet.goat.test")
    #expect(plan.backupWarning(inventory: sharedRoot) != nil)
}
