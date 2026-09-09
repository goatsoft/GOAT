import Foundation
import os.signpost

/// Points of interest for Instruments. These intervals stay cheap when signpost collection is off
/// and make main-actor publication, parsing, scrolling, and fullscreen transitions comparable.
public enum RenderSignposts {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.leet.goat",
        category: .pointsOfInterest)

    @inline(__always)
    public static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        defer { os_signpost(.end, log: log, name: name, signpostID: id) }
        return try work()
    }

    @inline(__always)
    public static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }
}
