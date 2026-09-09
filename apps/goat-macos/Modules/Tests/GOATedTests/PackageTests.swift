import Foundation
import Testing
import zlib

@testable import GOATed

private func manifest(_ changes: [String: Any] = [:]) throws -> Data {
    var value: [String: Any] = [
        "formatVersion": 1, "apiVersion": 1, "id": "example.vue", "name": "Vue Toolkit",
        "version": "1.0.0", "author": "Example", "description": "Vue guidance.",
        "permissions": ["skill-resources", "prompt-context", "mcp-setup"],
        "skills": ["vue"], "prompts": ["prompts/vue.md"],
        "mcp": [["name": "example", "command": "example-server", "arguments": []]],
    ]
    value.merge(changes) { _, new in new }
    return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func entries(_ changes: [String: Any] = [:]) throws -> [(String, Data)] {
    [
        ("extension.json", try manifest(changes)),
        ("skills/vue/SKILL.md", Data("---\nname: vue\ndescription: Write Vue components.\n---\nUse TypeScript.".utf8)),
        ("skills/vue/references/example.md", Data("Scoped reference".utf8)),
        ("prompts/vue.md", Data("Prefer Vue with TypeScript.".utf8)),
    ]
}

/// ZIP fixture builder with explicit fields for adversarial central-directory cases.
private func archive(_ files: [(String, Data)], mode: UInt32 = 0o100644, method: UInt16 = 0, corruptCRC: Bool = false)
    throws -> Data
{
    var body = Data()
    var central = Data()
    func word(_ value: UInt64, _ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    for (path, bytes) in files {
        let name = Data(path.utf8)
        let checksum = bytes.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)) }
        let payload: Data
        if method == 8 {
            var stream = z_stream()
            #expect(
                deflateInit2_(
                    &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                    Int32(MemoryLayout<z_stream>.size)) == Z_OK)
            defer { deflateEnd(&stream) }
            var output = Data(count: bytes.count + 128)
            let result = bytes.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { target in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(bytes.count)
                    stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(target.count)
                    return deflate(&stream, Z_FINISH)
                }
            }
            #expect(result == Z_STREAM_END)
            output.count = Int(stream.total_out)
            payload = output
        } else {
            payload = bytes
        }
        let offset = body.count
        let crc = UInt64(checksum) ^ (corruptCRC ? 1 : 0)
        for (value, count) in [
            (UInt64(0x04034b50), 4), (20, 2), (0, 2), (UInt64(method), 2), (0, 4), (crc, 4), (UInt64(payload.count), 4),
            (UInt64(bytes.count), 4), (UInt64(name.count), 2), (0, 2),
        ] {
            body.append(word(value, count))
        }
        body.append(name)
        body.append(payload)
        for (value, count) in [
            (UInt64(0x02014b50), 4), (0x0314, 2), (20, 2), (0, 2), (UInt64(method), 2), (0, 4), (crc, 4),
            (UInt64(payload.count), 4), (UInt64(bytes.count), 4), (UInt64(name.count), 2), (0, 2), (0, 2), (0, 2),
            (0, 2), (UInt64(mode) << 16, 4), (UInt64(offset), 4),
        ] {
            central.append(word(value, count))
        }
        central.append(name)
    }
    let offset = body.count
    body.append(central)
    for (value, count) in [
        (UInt64(0x06054b50), 4), (0, 4), (UInt64(files.count), 2), (UInt64(files.count), 2), (UInt64(central.count), 4),
        (UInt64(offset), 4), (0, 2),
    ] { body.append(word(value, count)) }
    return body
}

@Test func goatedReadsStoredAndDeflatedArchivesWithoutExtractingFiles() throws {
    for method in [UInt16(0), 8] {
        let package = try ExtensionPackage(archive: archive(entries(), method: method))
        #expect(package.manifest.name == "Vue Toolkit")
        #expect(package.text(at: "skills/vue/references/example.md") == "Scoped reference")
        #expect(package.fileNames.count == 4)
        #expect(package.extensionValue.contributions.tools.isEmpty)
        #expect(package.extensionValue.contributions.services.isEmpty)
    }
}

@Test func goatedRejectsTraversalLinksExecutablesAndAmbiguousNames() throws {
    for path in ["../escape", "/absolute", "skills/../escape", "skills//bad", "skills\\bad", ".hidden", "skills/./bad"]
    {
        #expect(throws: (any Error).self) {
            try ExtensionPackage(archive: archive(entries() + [(path, Data("bad".utf8))]))
        }
    }
    for mode in [UInt32(0o120777), 0o100755, 0o060644] {
        #expect(throws: (any Error).self) { try ExtensionPackage(archive: archive(entries(), mode: mode)) }
    }
    #expect(throws: (any Error).self) {
        try ExtensionPackage(archive: archive(entries() + [("EXTENSION.JSON", manifest())]))
    }
    #expect(throws: (any Error).self) { try ExtensionPackage(archive: archive(entries() + [("skills/vue", Data())])) }
}

@Test func goatedRejectsCorruptionAndCompressedExpansionLimits() throws {
    #expect(throws: (any Error).self) { try ExtensionPackage(archive: archive(entries(), corruptCRC: true)) }
    let bytes = try archive(entries())
    for length in [0, 21, bytes.count - 1] {
        #expect(throws: (any Error).self) { try ExtensionPackage(archive: Data(bytes.prefix(length))) }
    }
    #expect(throws: (any Error).self) {
        try ExtensionPackage(
            archive: archive(
                entries() + [("skills/vue/huge.txt", Data(repeating: 65, count: 1_024 * 1_024 + 1))], method: 8))
    }
    #expect(throws: (any Error).self) { try ExtensionPackage(archive: archive(entries(), method: 12)) }
}

@Test func goatedRejectsUndeclaredAuthorityAndUnsupportedContent() throws {
    for change: [String: Any] in [
        ["formatVersion": 2], ["apiVersion": 2], ["id": "goat.herder"], ["id": "../../bad"],
        ["permissions": ["filesystem"]], ["permissions": []], ["entrypoint": "run.sh"],
        ["mcp": [["name": "bad", "command": "sh", "arguments": [], "env": ["SECRET": "hidden"]]]],
        ["prompts": ["missing.md"]], ["skills": ["missing"]],
    ] {
        #expect(throws: (any Error).self) { try ExtensionPackage(archive: archive(entries(change))) }
    }
    #expect(throws: (any Error).self) {
        try ExtensionPackage(archive: archive(entries() + [("run.sh", Data("echo bad".utf8))]))
    }
    #expect(throws: (any Error).self) {
        try ExtensionPackage(archive: archive(entries() + [("skills/vue/binary", Data([0, 1, 2]))]))
    }
}

@Test func goatedPackageContributionsStayInPenAndRevoke() async throws {
    let package = try ExtensionPackage(archive: archive(entries()))
    let runtime = ExtensionRuntime()
    let pen = UUID()
    let token = try await runtime.activate(package.extensionValue, scope: .pen(pen))
    let view = ExtensionView(chatID: UUID(), penID: pen)
    let other = ExtensionView(chatID: UUID(), penID: UUID())
    let catalog = await runtime.skillCatalog(for: view)
    #expect(catalog.skills.map(\.name) == ["vue"])
    #expect(await runtime.skillCatalog(for: other).skills.isEmpty)
    let snapshot = try await runtime.prepareTurn(ExtensionContext(view: view, turnID: UUID()))
    #expect(snapshot.promptSections.count == 1)
    #expect(snapshot.promptSections[0].contains("Untrusted extension context"))
    #expect(snapshot.tools.isEmpty)
    let provider = try #require(package.extensionValue.contributions.skills.first)
    #expect(try await provider.readResource(skill: "vue", path: "references/example.md") == "Scoped reference")
    await #expect(throws: (any Error).self) {
        try await provider.readResource(skill: "vue", path: "../../extension.json")
    }
    try await runtime.unregister(token)
    #expect(await runtime.skillCatalog(for: view).skills.isEmpty)
    let next = try await runtime.prepareTurn(ExtensionContext(view: view, turnID: UUID()))
    #expect(next.promptSections.isEmpty)
}
