import Darwin
import Foundation

/// Resolve Apple's selected toolchain before entering the command sandbox. `/usr/bin` shims
/// otherwise perform developer-tool discovery inside the sandbox and can fail before execution.
struct DeveloperToolchain: Sendable {
    let directory: String
    var searchPaths: [String] {
        [directory + "/Toolchains/XcodeDefault.xctoolchain/usr/bin", directory + "/usr/bin"]
    }

    var sdkRoot: String? {
        [directory + "/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk", directory + "/SDKs/MacOSX.sdk"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    static func selected() async -> Self? {
        await Task.detached(priority: .utility) { readSelected() }.value
    }

    private static func readSelected() -> Self? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--print-path"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard data.count < 4096 else { return nil }
        let directory = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard directory.hasPrefix("/"), FileManager.default.fileExists(atPath: directory) else { return nil }
        return Self(directory: URL(fileURLWithPath: directory).resolvingSymlinksInPath().path)
    }

    func replacingShim(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard path == "/usr/bin/" + name,
            ["git", "swift", "swiftc", "clang", "clang++", "cc", "c++", "xcodebuild", "make", "ar", "ld"].contains(name)
        else { return path }
        return searchPaths.map { $0 + "/" + name }.first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? path
    }
}
