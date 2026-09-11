import Foundation

public enum UnexecutedToolMarkupDetector {
    public enum EnvelopeStyle: String, Sendable, Equatable {
        case qwen
        case glm
        case orphan
    }

    public enum Confidence: String, Sendable, Equatable {
        case high
        case low
    }

    public struct Result: Sendable, Equatable {
        public let style: EnvelopeStyle
        public let confidence: Confidence

        public init(style: EnvelopeStyle, confidence: Confidence) {
            self.style = style
            self.confidence = confidence
        }
    }

    public static func detect(_ text: String, toolNames: Set<String>) -> Result? {
        let candidate = excludingCode(text)
        let open = "<tool_call>"
        let close = "</tool_call>"
        var searchStart = candidate.startIndex
        var sawEnvelope = false

        while let openRange = candidate.range(of: open, range: searchStart..<candidate.endIndex) {
            sawEnvelope = true
            guard let closeRange = candidate.range(of: close, range: openRange.upperBound..<candidate.endIndex) else {
                break
            }
            if isStandalone(candidate, range: openRange, closing: closeRange) {
                let body = String(candidate[openRange.upperBound..<closeRange.lowerBound])
                if let name = qwenToolName(in: body, toolNames: toolNames) {
                    _ = name
                    return Result(style: .qwen, confidence: .high)
                }
                if glmToolName(in: body, toolNames: toolNames) {
                    return Result(style: .glm, confidence: .high)
                }
            }
            searchStart = closeRange.upperBound
        }

        if sawEnvelope || candidate.contains(close) {
            return Result(style: .orphan, confidence: .low)
        }
        return nil
    }

    private static func qwenToolName(in body: String, toolNames: Set<String>) -> String? {
        for name in toolNames.sorted() where body.contains("<function=\(name)>") {
            return name
        }
        return nil
    }

    private static func glmToolName(in body: String, toolNames: Set<String>) -> Bool {
        guard body.contains("<arg_key>"), body.contains("<arg_value>") else { return false }
        for name in toolNames where containsWholeName(name, in: body) { return true }
        return false
    }

    private static func containsWholeName(_ name: String, in body: String) -> Bool {
        var searchStart = body.startIndex
        while let range = body.range(of: name, range: searchStart..<body.endIndex) {
            let before = range.lowerBound > body.startIndex ? body[body.index(before: range.lowerBound)] : nil
            let after = range.upperBound < body.endIndex ? body[range.upperBound] : nil
            let word: (Character?) -> Bool = { character in
                guard let character else { return false }
                return character.isLetter || character.isNumber || character == "_"
            }
            if !word(before) && !word(after) { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isStandalone(_ text: String, range: Range<String.Index>, closing: Range<String.Index>) -> Bool {
        let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[closing.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        return text[lineStart..<range.lowerBound].trimmingCharacters(in: .whitespaces) .isEmpty
            && text[closing.upperBound..<lineEnd].trimmingCharacters(in: .whitespaces) .isEmpty
    }

    private static func excludingCode(_ text: String) -> String {
        var result = ""
        var fence: Character?
        var fenceLength = 0
        var inlineDelimiter: Character?
        var inlineLength = 0

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                let run = trimmed.prefix { $0 == marker }.count
                if run >= fenceLength { fence = nil; fenceLength = 0 }
                result += "\n"
                continue
            }
            let backtickRun = trimmed.prefix { $0 == "`" }.count
            let tildeRun = trimmed.prefix { $0 == "~" }.count
            if backtickRun >= 3 || tildeRun >= 3 {
                fence = backtickRun >= tildeRun ? "`" : "~"
                fenceLength = max(backtickRun, tildeRun)
                result += "\n"
                continue
            }

            var index = line.startIndex
            while index < line.endIndex {
                let character = line[index]
                if let delimiter = inlineDelimiter {
                    if character == delimiter {
                        var end = index
                        while end < line.endIndex && line[end] == delimiter { end = line.index(after: end) }
                        if line.distance(from: index, to: end) >= inlineLength { inlineDelimiter = nil; inlineLength = 0 }
                        index = end
                    } else {
                        index = line.index(after: index)
                    }
                    continue
                }
                if character == "`" {
                    var end = index
                    while end < line.endIndex && line[end] == "`" { end = line.index(after: end) }
                    inlineDelimiter = "`"
                    inlineLength = line.distance(from: index, to: end)
                    index = end
                    continue
                }
                result.append(character)
                index = line.index(after: index)
            }
            result += "\n"
        }
        return result
    }
}
