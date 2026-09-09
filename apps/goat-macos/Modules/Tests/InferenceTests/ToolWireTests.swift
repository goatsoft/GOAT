import Foundation
import Testing

@testable import Inference

@Test func accumulatorReassemblesFragmentedCalls() throws {
    // Mirrors the exact fragment shapes observed live from vMLX (2026-08-29).
    let chunk1 = """
        {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_4b510a24","type":"function","function":{"name":"","arguments":""}}]},"finish_reason":null}]}
        """
    let chunk2 = """
        {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"get_weather","arguments":"{\\"city\\": \\"Perth\\"}"}}]},"finish_reason":null}]}
        """
    var acc = ToolCallAccumulator()
    for raw in [chunk1, chunk2] {
        let chunk = try JSONDecoder().decode(StreamChunk.self, from: raw.data(using: .utf8)!)
        if let calls = chunk.choices.first?.delta?.tool_calls { acc.feed(calls) }
    }
    #expect(!acc.isEmpty)
    let events = acc.events
    #expect(events.count == 1)
    #expect(events[0].id == "call_4b510a24")
    #expect(events[0].name == "get_weather")
    #expect(events[0].argumentsJSON == "{\"city\": \"Perth\"}")
}

@Test func toolsEncodeWithParametersAsObjectNotString() throws {
    let request = GenerationRequest(
        model: "Qwen3-8B",
        turns: [ChatTurn(role: .user, text: "hi")],
        effort: .trot,
        tools: [
            ToolSpec(
                name: "fs__read_file",
                description: "[fs] Read a file",
                parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#
            )
        ]
    )
    let data = try JSONEncoder().encode(OpenAICompatEngine.makeBody(for: request))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let tools = json["tools"] as! [[String: Any]]
    #expect(tools[0]["type"] as? String == "function")
    let function = tools[0]["function"] as! [String: Any]
    #expect(function["name"] as? String == "fs__read_file")
    let params = function["parameters"] as! [String: Any]  // object, not string
    #expect(params["type"] as? String == "object")
    #expect((params["required"] as? [String])?.first == "path")
}

@Test func toolRoundTripTurnsEncodeOpenAIShape() throws {
    let call = ToolCallEvent(id: "call_1", name: "fs__read_file", argumentsJSON: #"{"path":"/tmp/x"}"#)
    let request = GenerationRequest(
        model: "Qwen3-8B",
        turns: [
            ChatTurn(role: .user, text: "read it"),
            ChatTurn(role: .assistant, text: "", toolCalls: [call]),
            ChatTurn(role: .tool, text: "file contents here", toolCallID: "call_1"),
        ],
        effort: .trot
    )
    let data = try JSONEncoder().encode(OpenAICompatEngine.makeBody(for: request))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let messages = json["messages"] as! [[String: Any]]

    let assistant = messages[1]
    #expect(assistant["content"] is NSNull)  // empty text + tool_calls → null content
    let toolCalls = assistant["tool_calls"] as! [[String: Any]]
    #expect(toolCalls[0]["id"] as? String == "call_1")
    let function = toolCalls[0]["function"] as! [String: Any]
    #expect(function["arguments"] as? String == #"{"path":"/tmp/x"}"#)

    let toolMsg = messages[2]
    #expect(toolMsg["role"] as? String == "tool")
    #expect(toolMsg["tool_call_id"] as? String == "call_1")
    #expect(toolMsg["content"] as? String == "file contents here")
}

@Test func emptyToolsListOmitsTheField() throws {
    let request = GenerationRequest(model: "m", turns: [ChatTurn(role: .user, text: "x")], effort: .trot)
    let data = try JSONEncoder().encode(OpenAICompatEngine.makeBody(for: request))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["tools"] == nil)
}
