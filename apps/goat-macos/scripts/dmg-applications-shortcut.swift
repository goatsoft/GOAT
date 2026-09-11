// A regular Finder alias can carry its own icon without styling its target.
import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("DMG shortcut: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 4, ["create", "verify"].contains(args[1]),
      args.count == (args[1] == "create" ? 5 : 4) else {
    fail("usage: create TARGET ALIAS ICON, or verify TARGET ALIAS")
}
let target = URL(fileURLWithPath: args[2]).standardizedFileURL
let alias = URL(fileURLWithPath: args[3]).standardizedFileURL
guard try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
    fail("destination must be a folder")
}

if args[1] == "create" {
    guard (try? FileManager.default.attributesOfItem(atPath: alias.path)) == nil,
          let icon = NSImage(contentsOfFile: args[4]) else {
        fail("alias must not exist and artwork must be readable")
    }
    let bookmark = try target.bookmarkData(
        options: [.suitableForBookmarkFile, .minimalBookmark, .withoutImplicitSecurityScope],
        includingResourceValuesForKeys: nil, relativeTo: nil)
    try URL.writeBookmarkData(bookmark, to: alias)
    let values = try alias.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
    guard values.isAliasFile == true, values.isSymbolicLink == false else {
        fail("refusing to style anything except a regular Finder alias")
    }
    guard NSWorkspace.shared.setIcon(icon, forFile: alias.path, options: []) else {
        fail("could not set the shortcut icon")
    }
}

let values = try alias.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
guard values.isAliasFile == true, values.isSymbolicLink == false else {
    fail("expected a regular Finder alias, not a symbolic link")
}
let resolved = try URL(resolvingAliasFileAt: alias, options: [.withoutUI, .withoutMounting])
guard resolved.standardizedFileURL.resolvingSymlinksInPath()
        == target.resolvingSymlinksInPath() else {
    fail("shortcut resolves to the wrong folder")
}
let resourceFork = try Data(contentsOf: URL(fileURLWithPath: alias.path + "/..namedfork/rsrc"))
guard !resourceFork.isEmpty else { fail("shortcut icon resource is missing") }
print("Finder Applications shortcut verified")
