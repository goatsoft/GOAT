// Finder has one icon size per window. Keep native footer artwork at 48 points
// within its 96-point item footprint, with room for the filename below it.
import AppKit
import UniformTypeIdentifiers

for path in CommandLine.arguments.dropFirst() {
    let original = NSWorkspace.shared.icon(for: .folder)
    let image = NSImage(size: NSSize(width: 96, height: 96))
    image.lockFocus()
    original.draw(in: NSRect(x: 24, y: 0, width: 48, height: 48))
    image.unlockFocus()
    guard NSWorkspace.shared.setIcon(image, forFile: path, options: []) else {
        FileHandle.standardError.write(Data("Could not set staging footer icon: \(path)\n".utf8))
        exit(1)
    }
}
