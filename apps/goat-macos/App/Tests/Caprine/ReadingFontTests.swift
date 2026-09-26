import AppKit
import OKLabColorPicker
import Pens
import Testing

@testable import GOAT

extension AppTests.Caprine {
    @Suite struct ReadingFontTests {

        @Test @MainActor func fontSizeSettersNormalizeAndPersistWithoutReenteringIndefinitely() {
            let model = AppModel.shared
            let chat = model.chatFontSize
            let code = model.codeFontSize
            defer {
                model.chatFontSize = chat
                model.codeFontSize = code
            }
            for input in [14.0, 14.0, 21.6, -100, 10_000, .nan, .infinity] {
                model.chatFontSize = input
                model.codeFontSize = input
                #expect(model.chatFontSize == ReadingFontRole.chat.normalizedSize(input))
                #expect(model.codeFontSize == ReadingFontRole.code.normalizedSize(input))
                #expect(UserDefaults.standard.double(forKey: "appearance.fontSize") == model.chatFontSize)
                #expect(UserDefaults.standard.double(forKey: "appearance.codeFontSize") == model.codeFontSize)
            }
        }

        @Test func readingSizesClampCorruptAndLegacyPreferences() {
            #expect(ReadingFontRole.chat.normalizedSize(.nan) == 14)
            #expect(ReadingFontRole.code.normalizedSize(.infinity) == 13)
            #expect(ReadingFontRole.chat.normalizedSize(-100) == 11)
            #expect(ReadingFontRole.chat.normalizedSize(10000) == 28)
            #expect(ReadingFontRole.code.normalizedSize(14 * 0.92) == 13)
            #expect(ReadingFontRole.code.normalizedSize(10000) == 24)
        }

        @Test @MainActor func missingFontsFallBackWithoutChangingTheRequestedSize() {
            let missing = "font:GOAT-Test-Missing-Font-123456"
            #expect(!ReadingFonts.isAvailable(missing, for: .chat))
            let chat = ReadingFonts.nsFont(missing, size: 22, role: .chat)
            #expect(chat.pointSize == 22)
            #expect(chat.fontName == NSFont.systemFont(ofSize: 22).fontName)
            let code = ReadingFonts.nsFont(missing, size: 18, role: .code)
            #expect(code.pointSize == 18)
            #expect(code.isFixedPitch)
            #expect(ReadingFonts.name(missing, for: .code).contains("unavailable"))
        }

        @Test @MainActor func codeChoicesCannotSelectProportionalFonts() {
            #expect(!ReadingFonts.isAvailable("serif", for: .code))
            #expect(!ReadingFonts.isAvailable("rounded", for: .code))
            #expect(ReadingFonts.nsFont("serif", size: 14, role: .code).isFixedPitch)
            for choice in ReadingFonts.installed(for: .code) {
                #expect(ReadingFonts.nsFont(choice.id, size: 14, role: .code).isFixedPitch)
            }
        }

        @Test @MainActor func systemDesignsAndInstalledFacesResolveForBothRenderers() throws {
            for choice in ReadingFonts.builtins(for: .chat) {
                #expect(ReadingFonts.isAvailable(choice.id, for: .chat))
                #expect(ReadingFonts.nsFont(choice.id, size: 17, role: .chat).pointSize == 17)
            }
            let face = try #require(ReadingFonts.installed(for: .chat).first)
            let font = ReadingFonts.nsFont(face.id, size: 19, role: .chat)
            #expect(font.fontName == String(face.id.dropFirst(5)))
            #expect(ReadingFonts.family(face.id, role: .chat) == .custom(font.fontName))
        }

        @Test @MainActor func themeFontsApplyOnlyWhenFollowingTheTheme() {
            #expect(
                ReadingFonts.requestedID(selection: "theme", themeFont: "AvenirNext-Regular", role: .chat)
                    == "font:AvenirNext-Regular")
            #expect(ReadingFonts.requestedID(selection: "theme", themeFont: "serif", role: .chat) == "serif")
            #expect(ReadingFonts.requestedID(selection: "theme", themeFont: nil, role: .code) == "monospaced")
            #expect(
                ReadingFonts.requestedID(selection: "rounded", themeFont: "AvenirNext-Regular", role: .chat)
                    == "rounded")
            #expect(
                ReadingFonts.requestedID(selection: "font:Menlo-Regular", themeFont: "Other-Mono", role: .code)
                    == "font:Menlo-Regular")
            let unavailable = ReadingFonts.requestedID(selection: "theme", themeFont: "GOAT-Missing-Font", role: .code)
            #expect(ReadingFonts.nsFont(unavailable, size: 17, role: .code).isFixedPitch)
        }
    }
}

extension AppTests.Caprine {
    @Suite struct ColorPickerValueTests {
        @Test func penColoursRoundTripWithoutSRGBClipping() {
            let source = OKLCH(l: 0.68, c: 0.30, h: 250)
            let restored = ColorPickerValues.pen(ColorPickerValues.picker(source))
            #expect(abs(restored.l - source.l) < 0.000001)
            #expect(abs(restored.c - source.c) < 0.000001)
            #expect(abs(restored.h - source.h) < 0.000001)
        }

        @Test(arguments: ["#000000", "#FFFFFF", "#3AA0FF", "#7542CB"])
        func themeColoursKeepTheirStoredRGB(hex: String) throws {
            let value = try #require(OKLabColorValue.from(hex: hex))
            #expect(ColorPickerValues.themeHex(value) == hex)
        }

        @Test func themeSlotsStayOpaqueEvenWhenHexIncludesAlpha() throws {
            let value = try #require(OKLabColorValue.from(hex: "#3AA0FF80"))
            #expect(ColorPickerValues.themeHex(value) == "#3AA0FF")
        }
    }
}
