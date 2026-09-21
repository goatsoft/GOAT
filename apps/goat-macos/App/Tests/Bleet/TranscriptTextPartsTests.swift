import Testing

@testable import GOAT

extension AppTests.Bleet {
    @Suite struct TranscriptTextPartsTests {

        @Test func transcriptPartsPreserveEveryScalarAndBoundPathologicalGraphemes() throws {
            let fixtures = [
                "", "\r\n\n  ```swift\nlet goat = \"🐐\"\n```  \n",
                String(repeating: "👩🏽‍💻 café\r\n", count: 3_000),
                "a" + String(repeating: "\u{0301}", count: 30_000),
            ]
            for source in fixtures {
                let parts = try TranscriptTextParts.split(source)
                #expect(parts.allSatisfy { $0.utf8.count <= TranscriptTextParts.maximumBytes })
                #expect(parts.joined().unicodeScalars.elementsEqual(source.unicodeScalars))
            }
        }

        @Test func appendingTextPreservesCompletedPartsForReaders() throws {
            let source = String(repeating: "let goat = \"🐐\"\n", count: 2_000)
            let before = try TranscriptTextParts.split(source)
            let after = try TranscriptTextParts.split(source + String(repeating: "more\n", count: 2_000))
            #expect(Array(before.dropLast()) == Array(after.prefix(before.count - 1)))
        }
    }
}
