import Foundation
import Testing

@testable import Inference

@Test func compactionCommandParsesAndBoundsAOneShotFocus() {
    #expect(
        ConversationCompaction.command(from: "/compact")
            == ConversationCompaction.Command(focus: ""))
    #expect(
        ConversationCompaction.command(from: "  /compact  keep the WGSL constraints ")
            == ConversationCompaction.Command(focus: "keep the WGSL constraints"))
    #expect(ConversationCompaction.command(from: "compact this") == nil)
    #expect(ConversationCompaction.command(from: "/compacts") == nil)

    let long = String(repeating: "x", count: 900)
    #expect(
        ConversationCompaction.command(from: "/compact " + long)?.focus.count
            == ConversationCompaction.maximumFocusLength)
}

@Test func compactionRequestAppendsANonemptyFocusExactlyOnce() {
    let bare = ConversationCompaction.modelRequest()
    #expect(!bare.contains("Pay particular attention"))

    let focused = ConversationCompaction.modelRequest(focus: "  keep the WGSL constraints  ")
    #expect(focused.contains("keep the WGSL constraints"))
    #expect(focused.components(separatedBy: "Pay particular attention").count == 2)
}

@Test func compactionPromptSectionNamesEveryFixedSectionAndForbidsFileRecall() {
    let section = ConversationCompaction.promptSection
    #expect(ConversationCompaction.sectionTitles.count == 8)
    for title in ConversationCompaction.sectionTitles {
        #expect(section.contains(title))
    }
    #expect(section.contains("GOAT appends those lists itself"))
}

@Test func fileListsDeriveReadAndEditedFromToolCallsWithEditWinning() {
    func call(_ name: String, _ path: String) -> ToolCallEvent {
        ToolCallEvent(id: "\(name)-\(path)", name: name, argumentsJSON: #"{"path":"\#(path)"}"#)
    }
    func group(_ name: String, _ path: String) -> [ChatTurn] {
        [
            ChatTurn(role: .assistant, text: "", toolCalls: [call(name, path)]),
            ChatTurn(role: .tool, text: "ok", toolCallID: "\(name)-\(path)"),
        ]
    }
    var turns = [ChatTurn(role: .user, text: "work")]
    turns += group("pen_read_file", "src/a.ts")
    turns += group("pen_read_file", "src/b.ts")
    turns += group("pen_edit_file", "src/b.ts")
    turns += group("pen_write_file", "src/c.ts")
    turns += group("pen_search", "src")  // directory navigation, not a file read

    let lists = ConversationCompaction.fileLists(from: turns)
    #expect(lists.read == ["src/a.ts"])
    #expect(lists.edited == ["src/b.ts", "src/c.ts"])

    let rendered = ConversationCompaction.fileListsSection(read: lists.read, edited: lists.edited)
    #expect(rendered.contains("Files edited:"))
    #expect(rendered.contains("- src/b.ts"))
    #expect(rendered.contains("- src/c.ts"))
    #expect(rendered.contains("Files read:"))
    #expect(rendered.contains("- src/a.ts"))
    #expect(ConversationCompaction.fileListsSection(read: [], edited: []).isEmpty)
}
