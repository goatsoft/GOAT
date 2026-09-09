import AppKit
import SwiftUI
import Testing

@testable import GOAT

@MainActor
@Test(arguments: [
    "Hello", "A much longer first line\nHi", "A much longer first line\n\n",
    String(repeating: "A paragraph that wraps across multiple lines. ", count: 4) + "\nHi",
])
func streamingCursorFollowsTheFinalTextLine(source: String) throws {
    let view = Text(source)
        .font(.system(size: 16, design: .monospaced))
        .foregroundStyle(.black)
        .textRenderer(StreamingTextRenderer(tint: .red))
        .padding(.trailing, 6)
        .frame(width: 400, alignment: .leading)
        .padding(20)
        .background(.white)
        .environment(\.colorScheme, .light)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    let image = try #require(renderer.nsImage)
    let data = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: data))
    var marker = CGRect.null
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                color.redComponent > 0.8,
                color.redComponent - color.greenComponent > 0.3,
                color.redComponent - color.blueComponent > 0.3
            {
                marker = marker.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
    }
    #expect(!marker.isNull)
    let finalLine = source.components(separatedBy: "\n").last ?? ""
    let expectedX = 23 + CGFloat(finalLine.count) * 9.6
    #expect(abs(marker.minX - expectedX) < 4)
    #expect(marker.maxY > CGFloat(bitmap.pixelsHigh) - 25)
}
