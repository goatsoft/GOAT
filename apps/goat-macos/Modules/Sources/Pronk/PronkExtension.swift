import Foundation
import GOATed
import Herd
import Tools

/// The complete example uses only the public GOATed contract. Its only writable resource is
/// an explicitly supplied private state directory. Nothing is read from a Pen's workspace.
public struct PronkExtension: Extension {
    public let manifest = ExtensionManifest(id: "goat.pronk", version: "0.1.0")
    public let contributions: ExtensionContributions
    public init(stateDirectory: URL) {
        let pasture = PronkPasture(directory: stateDirectory)
        contributions = ExtensionContributions(
            prompts: [pasture], tools: [pasture], observers: [pasture],
            skills: [
                CompanionSkillProvider(
                    providerID: "goat.pronk.companion", name: "pronk",
                    description: "Adopt a fictional goat, offer imaginary treats, and read a Pen's pasture report.",
                    instructions:
                        "Use pronk_report to inspect this Pen's resident. When explicitly asked, use pronk_adopt with a name and alpine, nubian or pygmy breed, or pronk_treat with hay, apple or carrot. Check tool receipts before claiming success. This is a fictional game; it does not provide animal-care advice. State belongs only to this Pen. GOAT records completed chat adventures after durable persistence; do not invent that count.",
                    available: { $0.penID != nil })
            ])
    }
}

private actor PronkPasture: PromptProvider, ModelToolProvider, TurnObserver {
    struct Goat: Codable {
        var name: String
        var breed: String
        var treats: Int = 0
        var adventures: Int = 0
    }
    let directory: URL
    init(directory: URL) { self.directory = directory }

    func read(_ pen: UUID) throws -> Goat? {
        let file = directory.appendingPathComponent(pen.uuidString + ".json")
        guard let data = try LocalFileStore.boundedDataIfPresent(at: file, maximumBytes: 4096) else { return nil }
        let goat = try JSONDecoder().decode(Goat.self, from: data)
        guard goat.name.count <= 40, ["alpine", "nubian", "pygmy"].contains(goat.breed),
            (0...1_000_000).contains(goat.treats), (0...1_000_000).contains(goat.adventures)
        else {
            throw CapabilityError.invalidPayload
        }
        return goat
    }
    func write(_ goat: Goat, pen: UUID) throws {
        try Task.checkCancellation()
        try LocalFileStore.write(
            try JSONEncoder().encode(goat), to: directory.appendingPathComponent(pen.uuidString + ".json"))
    }
    func prompt(for context: ExtensionContext) async throws -> String {
        guard let pen = context.view.penID else { return "" }
        let goat = try read(pen)
        return
            "Pronk is an optional fictional goat sanctuary for this Pen. Use pronk_adopt, pronk_treat and pronk_report only when requested. Imaginary treats are game actions, not animal-care advice. Current resident: \(goat?.name ?? "none")."
    }
    func tools(for context: ExtensionContext) async throws -> [ToolSchema] {
        guard context.view.penID != nil else { return [] }
        return [
            ToolSchema(
                name: "pronk_adopt",
                description: "Adopt this Pen's one fictional goat. Fails if a goat already lives here.",
                inputSchemaJSON:
                    #"{"type":"object","additionalProperties":false,"properties":{"name":{"type":"string","minLength":1,"maxLength":40},"breed":{"type":"string","enum":["alpine","nubian","pygmy"]}},"required":["name","breed"]}"#
            ),
            ToolSchema(
                name: "pronk_treat", description: "Give the resident goat one imaginary treat.",
                inputSchemaJSON:
                    #"{"type":"object","additionalProperties":false,"properties":{"treat":{"type":"string","enum":["hay","apple","carrot"]}},"required":["treat"]}"#
            ),
            ToolSchema(
                name: "pronk_report", description: "Read the Pen's fictional pasture report.",
                inputSchemaJSON: #"{"type":"object","additionalProperties":false,"properties":{}}"#),
        ]
    }
    func invoke(_ call: ToolCallRequest, context: ExtensionContext) async throws -> ToolResult {
        guard let pen = context.view.penID else { throw CapabilityError.unavailable }
        let args = try JSONDecoder().decode([String: String].self, from: Data(call.argumentsJSON.utf8))
        switch call.tool {
        case "pronk_adopt":
            guard try read(pen) == nil else {
                return ToolResult(content: "This pasture already has a goat. Ask for its report.", isError: true)
            }
            guard let name = args["name"], let breed = args["breed"],
                !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw CapabilityError.invalidPayload }
            try write(Goat(name: name, breed: breed), pen: pen)
            return ToolResult(content: "\(name) the \(breed) has joined this Pen. A small, celebratory pronk ensues.")
        case "pronk_treat":
            guard var goat = try read(pen) else { return ToolResult(content: "Adopt a goat first.", isError: true) }
            goat.treats = min(1_000_000, goat.treats + 1)
            try write(goat, pen: pen)
            return ToolResult(
                content: "\(goat.name) accepts an imaginary \(args["treat"] ?? "treat"). Total treats: \(goat.treats).")
        case "pronk_report":
            guard let goat = try read(pen) else {
                return ToolResult(content: "An empty pasture awaits its first resident.")
            }
            return ToolResult(
                content:
                    "\(goat.name) · \(goat.breed)\nImaginary treats: \(goat.treats)\nCompleted chat adventures: \(goat.adventures)"
            )
        default: throw CapabilityError.unavailable
        }
    }
    func turnDidPersist(_ turn: PersistedTurn) async throws -> ObserverReceipt? {
        guard let pen = turn.context.view.penID, var goat = try read(pen) else { return nil }
        goat.adventures = min(1_000_000, goat.adventures + 1)
        try write(goat, pen: pen)
        return nil
    }
}
