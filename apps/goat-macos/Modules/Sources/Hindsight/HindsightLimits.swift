import Foundation

/// Shared transport and projection limits. No graph layout or UI dependency.
public enum HindsightLimits {
    public static let graphNodes = 60
    public static let graphBytes = 2 * 1_024 * 1_024
    public static let knowledgePages = 20
    public static let knowledgeBytes = 2 * 1_024 * 1_024

    public static func validKnowledgeID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 512
            && id.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90)
                    || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95
            }
    }
}
