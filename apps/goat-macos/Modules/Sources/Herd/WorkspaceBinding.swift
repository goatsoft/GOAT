import Foundation

/// A user-owned working folder bound to a Pen. This is deliberately separate from the Pen's
/// managed GOAT folder so a project repository never gains GOAT metadata or memory files unless
/// its owner explicitly puts them there.
public struct PenWorkspace: Codable, Sendable, Equatable {
    public var path: String
    public var bookmark: Data?
    public var wasCreatedByGOAT: Bool

    public init(path: String, bookmark: Data? = nil, wasCreatedByGOAT: Bool) {
        self.path = path
        self.bookmark = bookmark
        self.wasCreatedByGOAT = wasCreatedByGOAT
    }
}
