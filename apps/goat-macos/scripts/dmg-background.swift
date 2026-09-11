// Render the ImageGen master at both Finder scales with the validated bundle's build.
import AppKit
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("DMG background: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fail("usage: dmg-background.swift SOURCE APP OUTPUT_DIRECTORY")
}
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let appURL = URL(fileURLWithPath: CommandLine.arguments[2])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width * 2 == image.height * 3 else {
    fail("expected a 3:2 background master")
}
let plistData = try Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
guard let info = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
      let build = info["CFBundleVersion"] as? String, let buildNumber = Int(build), buildNumber > 0,
      let version = info["CFBundleShortVersionString"] as? String,
      let channel = info["GOATReleaseChannel"] as? String else {
    fail("missing bundle identity; no placeholder build labels are allowed")
}
let text = "BUILD \(build)" as NSString
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
    .foregroundColor: NSColor(srgbRed: 0.02, green: 0.10, blue: 0.22, alpha: 1),
]
let textSize = text.size(withAttributes: attributes)
guard textSize.width <= 60 else { fail("build number does not fit the artwork capsule") }
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
for scale in [1, 2] {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: 720 * scale, height: 480 * scale,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("could not create the background renderer")
    }
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.draw(image, in: CGRect(x: 0, y: 0, width: 720, height: 480))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    // Measured centre of the ImageGen master's empty capsule, in Finder points.
    text.draw(at: NSPoint(x: 153 - textSize.width / 2, y: 480 - 46 - textSize.height / 2),
              withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    guard let rendered = context.makeImage() else { fail("could not render background") }
    let bitmap = NSBitmapImageRep(cgImage: rendered)
    bitmap.size = NSSize(width: 720, height: 480)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fail("could not encode background")
    }
    let filename = scale == 1 ? "background.png" : "background@2x.png"
    try png.write(to: outputURL.appendingPathComponent(filename))
}
let metadata: [String: Any] = ["build": buildNumber, "version": version, "channel": channel,
                               "label": text as String]
try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
    .write(to: outputURL.appendingPathComponent("build.json"))
