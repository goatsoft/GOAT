import CryptoKit
import Foundation
import GOATed
import Inference
import Pens
import Tools

public actor SubagentCapabilityFence {
    public static let permittedTools: Set<String> = [
        "pen_read_file",
        "pen_list_files",
        "pen_search",
        "pen_glob",
    ]

    public struct ReadSpan: Sendable {
        public let path: String
        public let startLine: Int
        public let endLine: Int
        public let lines: [String]
    }

    private let authority: any SubagentHostAuthority
    private let lease: SubagentCapabilityLease
    private var readSpans: [String: [ReadSpan]] = [:]
    private var retainedSpanBytes: Int = 0

    public init(authority: any SubagentHostAuthority, lease: SubagentCapabilityLease) {
        self.authority = authority
        self.lease = lease
    }

    public init(fileTools: PenFileTools, lease: SubagentCapabilityLease) {
        self.authority = SubagentTurnAuthority { fileTools }
        self.lease = lease
    }

    public var availableToolSpecs: [ToolSpec] {
        PenFileTools.schemas
            .filter { Self.permittedTools.contains($0.name) }
            .map {
                ToolSpec(
                    name: $0.name,
                    description: $0.description,
                    parametersJSON: $0.inputSchemaJSON
                )
            }
    }

    public func invoke(_ call: ToolCallRequest) async throws -> ToolResult {
        try lease.checkValid()
        try await authority.validateHostAuthority()

        guard Self.permittedTools.contains(call.tool) else {
            return ToolResult(
                content:
                    "Unattended approval denied: subagents are strictly read-only and cannot execute '\(call.tool)'.",
                isError: true
            )
        }

        do {
            let fileTools = try await authority.currentPenFileTools()
            let result = try await fileTools.read(tool: call.tool, argumentsJSON: call.argumentsJSON)

            try lease.checkValid()
            try await authority.validateHostAuthority()

            if call.tool == "pen_read_file" && !result.isError {
                recordRead(argumentsJSON: call.argumentsJSON, output: result.content)
            }

            var content = result.content
            if content.utf8.count > SubagentLimits.maxToolOutputBytes {
                content = UTF8BoundaryTruncator.truncate(
                    content,
                    maxBytes: SubagentLimits.maxToolOutputBytes - 32,
                    notice: "\n[output truncated to 32 KiB]"
                )
            }

            return ToolResult(
                content: content,
                isError: result.isError,
                diagnostic: result.diagnostic
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CapabilityError {
            throw error
        } catch let error as PenFileTools.Failure {
            return ToolResult(content: error.localizedDescription, isError: true, diagnostic: error.diagnostic)
        } catch {
            return ToolResult(content: error.localizedDescription, isError: true)
        }
    }

    private func recordRead(argumentsJSON: String, output: String) {
        guard let data = argumentsJSON.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let path = json["path"] as? String
        else {
            return
        }

        let normalizedPath = normalizePath(path)
        let lines = output.components(separatedBy: "\n")
        guard let header = lines.first, header.contains("lines ") else {
            return
        }

        // Header pattern: "<path>, lines <start>-<end> of <total>..."
        var start = 1
        var end = 1
        if let rangeIdx = header.range(of: "lines ") {
            let after = header[rangeIdx.upperBound...]
            let parts = after.components(separatedBy: " ")
            if let span = parts.first {
                let nums = span.components(separatedBy: "-")
                if nums.count == 2, let s = Int(nums[0]), let e = Int(nums[1]) {
                    start = s
                    end = e
                }
            }
        }

        let bodyLines = Array(lines.dropFirst())
        let bodyBytes = bodyLines.reduce(0) { $0 + $1.utf8.count + 1 }

        // Bound retained read spans in memory to 512 KiB total
        if retainedSpanBytes + bodyBytes > SubagentLimits.maxTranscriptBytes {
            while retainedSpanBytes + bodyBytes > SubagentLimits.maxTranscriptBytes, !readSpans.isEmpty {
                if let firstKey = readSpans.keys.first, let removed = readSpans.removeValue(forKey: firstKey) {
                    let freed = removed.reduce(0) { sum, s in sum + s.lines.reduce(0) { $0 + $1.utf8.count + 1 } }
                    retainedSpanBytes = max(0, retainedSpanBytes - freed)
                }
            }
        }

        let span = ReadSpan(
            path: normalizedPath,
            startLine: start,
            endLine: end,
            lines: bodyLines
        )
        readSpans[normalizedPath, default: []].append(span)
        retainedSpanBytes += bodyBytes
    }

    private func normalizePath(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public func verifyCitations(
        claimed: [SubagentCitationClaim]
    ) -> (verified: [SubagentCitation], unresolved: [SubagentUnresolvedItem]) {
        var verified: [SubagentCitation] = []
        var unresolved: [SubagentUnresolvedItem] = []

        for citation in claimed {
            // Strictly check for positive, ordered line bounds
            guard citation.startLine >= 1, citation.endLine >= citation.startLine else {
                unresolved.append(
                    SubagentUnresolvedItem(
                        path: citation.path,
                        reason: "unverifiedCitation",
                        detail: "Invalid or inverted line range \(citation.startLine)-\(citation.endLine) for '\(citation.path)'."
                    )
                )
                continue
            }

            let normalized = normalizePath(citation.path)
            guard let spans = readSpans[normalized], !spans.isEmpty else {
                unresolved.append(
                    SubagentUnresolvedItem(
                        path: citation.path,
                        reason: "unverifiedCitation",
                        detail: "File '\(citation.path)' was not read via pen_read_file during this delegation."
                    )
                )
                continue
            }

            // Find a span covering citation.startLine...citation.endLine
            var matchedSliceData: Data?
            for span in spans {
                if citation.startLine >= span.startLine && citation.endLine <= span.endLine {
                    let relativeStart = citation.startLine - span.startLine
                    let (relativeCount, overflowCount) = (citation.endLine - citation.startLine).addingReportingOverflow(1)
                    if !overflowCount && relativeStart >= 0 && relativeCount > 0 {
                        let (endIndex, overflowEnd) = relativeStart.addingReportingOverflow(relativeCount)
                        if !overflowEnd && endIndex <= span.lines.count {
                            let sliceLines = span.lines[relativeStart..<endIndex]
                            let sliceText = sliceLines.joined(separator: "\n")
                            matchedSliceData = Data(sliceText.utf8)
                            break
                        }
                    }
                }
            }

            if let sliceData = matchedSliceData {
                let digest = SHA256.hash(data: sliceData)
                let hashString = digest.map { String(format: "%02x", $0) }.joined()
                let verifiedCitation = SubagentCitation(
                    path: citation.path,
                    startLine: citation.startLine,
                    endLine: citation.endLine,
                    sliceHash: hashString
                )
                verified.append(verifiedCitation)
            } else {
                unresolved.append(
                    SubagentUnresolvedItem(
                        path: citation.path,
                        reason: "unverifiedCitation",
                        detail:
                            "Line range \(citation.startLine)-\(citation.endLine) was not covered by read spans for '\(citation.path)'."
                    )
                )
            }
        }

        return (verified: verified, unresolved: unresolved)
    }

    public func verifyCitations(
        claimed: [SubagentCitation]
    ) -> (verified: [SubagentCitation], unresolved: [SubagentUnresolvedItem]) {
        let claims = claimed.map { SubagentCitationClaim(path: $0.path, startLine: $0.startLine, endLine: $0.endLine) }
        return verifyCitations(claimed: claims)
    }
}
