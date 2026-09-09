import Foundation
import Testing

@testable import Herd
@testable import Inference

private func temporaryEngineFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-engines-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("engines.json")
}

@Test func missingEngineFileIsDistinctFromCorruptJSON() throws {
    let file = try temporaryEngineFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    #expect(try EngineStore.load(from: file) == nil)

    let corrupt = Data("{ not valid".utf8)
    try corrupt.write(to: file)
    #expect(throws: LocalStoreError.self) { _ = try EngineStore.load(from: file) }
    #expect(try Data(contentsOf: file) == corrupt)
}

@Test func emptyEngineListRoundTripsAsAnIntentionalOfflineState() throws {
    let file = try temporaryEngineFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let offline = EngineStore.File(active: nil, engines: [])

    try EngineStore.save(offline, to: file)

    let stored = try EngineStore.load(from: file)
    let loaded = try #require(stored)
    #expect(loaded.active == nil)
    #expect(loaded.engines.isEmpty)
}

@Test func legacyProfilesDefaultToAutomaticRequestStyle() throws {
    let data = Data(
        #"{"active":"local","engines":[{"id":"local","name":"Local","url":"http://127.0.0.1:8000"}]}"#
            .utf8)
    let file = try temporaryEngineFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    try data.write(to: file)

    let loaded = try #require(try EngineStore.load(from: file))
    #expect(loaded.engines.first?.requestStyle == .automatic)
}

@Test func qwenRequestStyleRoundTripsWithTheEngineProfile() throws {
    let file = try temporaryEngineFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let profile = EngineProfile(
        id: "qwen", name: "Qwen local", url: "http://127.0.0.1:8000",
        requestStyle: .qwenChatTemplate)

    try EngineStore.save(EngineStore.File(active: profile.id, engines: [profile]), to: file)

    let loaded = try #require(try EngineStore.load(from: file))
    #expect(loaded.engines.first?.requestStyle == .qwenChatTemplate)
}

@Test func engineEndpointCannotEmbedCredentials() throws {
    let file = try temporaryEngineFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let profile = EngineProfile(
        id: "unsafe", name: "Unsafe", url: "http://user:secret@127.0.0.1:8000")

    #expect(throws: LocalStoreError.self) {
        try EngineStore.save(
            EngineStore.File(active: profile.id, engines: [profile]), to: file)
    }
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func engineEndpointCannotPersistQueryOrFragmentSecrets() throws {
    let file = try temporaryEngineFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    for endpoint in [
        "https://example.com/v1?api_key=secret",
        "https://example.com/v1#token=secret",
    ] {
        let profile = EngineProfile(id: UUID().uuidString, name: "Unsafe", url: endpoint)
        #expect(throws: LocalStoreError.self) {
            try EngineStore.save(
                EngineStore.File(active: profile.id, engines: [profile]), to: file)
        }
    }
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func engineIDsMustBeUniqueAndActiveMustResolve() throws {
    let file = try temporaryEngineFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let first = EngineProfile(id: "same", name: "One", url: "http://127.0.0.1:8000")
    let second = EngineProfile(id: "same", name: "Two", url: "http://127.0.0.1:8001")

    #expect(throws: LocalStoreError.self) {
        try EngineStore.save(
            EngineStore.File(active: first.id, engines: [first, second]), to: file)
    }
    #expect(throws: LocalStoreError.self) {
        try EngineStore.save(
            EngineStore.File(active: "missing", engines: [first]), to: file)
    }
}
