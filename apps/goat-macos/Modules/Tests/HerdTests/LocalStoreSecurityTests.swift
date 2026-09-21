import Darwin
import Foundation
import Testing

@testable import Herd

private func temporaryDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func corruptCredentialsAreNeverOverwrittenByASet() throws {
    let root = try temporaryDirectory("corrupt-credentials")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("credentials.json")
    let original = Data("{ broken".utf8)
    try original.write(to: file)

    #expect(throws: LocalStoreError.self) {
        try CredentialStore.set("secret", for: "engine.test.apiKey", in: file)
    }
    #expect(try Data(contentsOf: file) == original)
}

@Test func credentialReplacementIsOwnerOnly() throws {
    let root = try temporaryDirectory("credential-mode")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("credentials.json")

    try CredentialStore.set("secret", for: "engine.test.apiKey", in: file)

    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect((permissions.intValue & 0o777) == 0o600)
    #expect(try CredentialStore.load(from: file)["engine.test.apiKey"] == "secret")
}

@Test func loadingLegacyCredentialsTightensPermissionsBeforeReading() throws {
    let root = try temporaryDirectory("credential-load-mode")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("credentials.json")
    try Data(#"{"key":"secret"}"#.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

    #expect(try CredentialStore.load(from: file)["key"] == "secret")

    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect((permissions.intValue & 0o777) == 0o600)
}

@Test func managedAndOwnerOnlyReadsRejectOversizedFiles() throws {
    let root = try temporaryDirectory("bounded-local-files")
    defer { try? FileManager.default.removeItem(at: root) }
    let managed = root.appendingPathComponent("managed.json")
    let secret = root.appendingPathComponent("secret.json")

    FileManager.default.createFile(atPath: managed.path, contents: Data())
    let managedHandle = try FileHandle(forWritingTo: managed)
    try managedHandle.truncate(
        atOffset: UInt64(LocalFileStore.maximumManagedFileBytes + 1))
    try managedHandle.close()

    FileManager.default.createFile(atPath: secret.path, contents: Data())
    let secretHandle = try FileHandle(forWritingTo: secret)
    try secretHandle.truncate(
        atOffset: UInt64(LocalFileStore.maximumOwnerOnlyFileBytes + 1))
    try secretHandle.close()

    #expect(throws: LocalStoreError.self) {
        _ = try LocalFileStore.dataIfPresent(at: managed)
    }
    #expect(throws: LocalStoreError.self) {
        _ = try CredentialStore.load(from: secret)
    }
}

@Test func managedReadsRejectSpecialFilesWithoutBlocking() throws {
    let root = try temporaryDirectory("special-local-files")
    defer { try? FileManager.default.removeItem(at: root) }
    let fifo = root.appendingPathComponent("named-pipe")
    #expect(Darwin.mkfifo(fifo.path, mode_t(0o600)) == 0)

    #expect(throws: LocalStoreError.self) {
        _ = try LocalFileStore.dataIfPresent(at: fifo)
    }
    #expect(throws: LocalStoreError.self) {
        _ = try LocalFileStore.ownerOnlyDataIfPresent(at: fifo)
    }
}
