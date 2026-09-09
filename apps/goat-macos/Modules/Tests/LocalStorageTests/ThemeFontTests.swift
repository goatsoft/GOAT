import Foundation
import Testing

@testable import Caprine
@testable import Herd

@Test func themeFontsSurviveSaveLoadAndExportWithoutRequiringInstallation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var theme = ThemeCatalog.light
    theme.id = "font-test"
    theme.fonts = ThemeFonts(chat: "NotInstalled-Regular", code: "NotInstalled-Mono")
    let saved = try ThemeStore.save(theme, in: root)
    #expect(saved.schema == 1)
    #expect(try ThemeStore.all(in: root).first?.fonts == theme.fonts)
    let exported = try JSONDecoder().decode(ThemeSpec.self, from: Data(ThemeStore.exportJSON(saved).utf8))
    #expect(exported.fonts == theme.fonts)
    #expect(exported.schema == 1)
}

@Test func oldThemesLoadWithoutFontMetadataOrDiskRewrites() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("legacy-font-test")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var theme = ThemeCatalog.light
    theme.id = "legacy-font-test"
    theme.schema = 1
    let original = try JSONEncoder().encode(theme)
    let file = folder.appendingPathComponent("theme.json")
    try original.write(to: file)
    let loaded = try #require(ThemeStore.all(in: root).first)
    #expect(loaded.schema == 1)
    #expect(loaded.fonts == nil)
    #expect(try Data(contentsOf: file) == original)
}

@Test func themeFontsRejectPathsURLsAndUnboundedNames() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for invalid in [
        "", "../font.ttf", "https://example.com/font.ttf", " font ", "Font\nName", String(repeating: "a", count: 129),
    ] {
        var theme = ThemeCatalog.light
        theme.id = "invalid-font-test"
        theme.fonts = ThemeFonts(chat: invalid)
        #expect(throws: LocalStoreError.self) { try ThemeStore.save(theme, in: root) }
        theme.fonts = ThemeFonts(code: invalid)
        #expect(throws: LocalStoreError.self) { try ThemeStore.save(theme, in: root) }
    }
}
