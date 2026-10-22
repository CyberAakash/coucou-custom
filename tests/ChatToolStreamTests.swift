import Foundation

/// The streamed tool calls (ChatToolStream.Accumulator), on lines as OpenAI-style servers send them.
@main
enum ChatToolStreamTests {
    static func main() {
        // OpenAI / DeepSeek: the call in pieces, by index, then finish_reason tool_calls.
        var a = ChatToolStream.Accumulator()
        let lines = [
            #"data: {"choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"create_","arguments":""}}]}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":"reminder","arguments":"{\"text\":\"Str"}}]}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"etch\",\"in_minutes\":10}"}}]}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_def","function":{"name":"water_status","arguments":"{}"}}]}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]",
        ]
        var grew = false
        for l in lines { grew = a.feed(l) || grew }
        precondition(!grew && a.text.isEmpty && a.finish == "tool_calls", "no text, tool_calls")
        let calls = a.orderedCalls
        precondition(calls.count == 2 && calls[0] == .init(id: "call_abc", name: "create_reminder", arguments: #"{"text":"Stretch","in_minutes":10}"#), "joined: \(calls)")
        let input = ChatToolStream.input(calls[0])
        precondition(input["text"] as? String == "Stretch" && BuddyToolCatalog.number(input["in_minutes"]) == 10, "arguments parse")
        precondition(calls[1].name == "water_status", "second call")
        let m = a.assistantMessage
        let tc = m["tool_calls"] as! [[String: Any]]
        precondition(m["content"] is NSNull && tc.count == 2 && (tc[0]["function"] as! [String: Any])["name"] as? String == "create_reminder", "assistant message")
        precondition(JSONSerialization.isValidJSONObject(m), "sendable as JSON")

        // Ollama: text, then one whole call with an object for arguments and no id.
        var o = ChatToolStream.Accumulator()
        precondition(o.feed(#"data: {"choices":[{"delta":{"content":"Sure, "}}]}"#), "text grows")
        _ = o.feed(#"data: {"choices":[{"delta":{"content":"<think>hm</think>setting it."}}]}"#)
        _ = o.feed(#"data:{"choices":[{"delta":{"tool_calls":[{"function":{"name":"timer","arguments":{"action":"start","minutes":5}}}]},"finish_reason":"tool_calls"}]}"#)
        precondition(o.text == "Sure, <think>hm</think>setting it.", "text kept")
        let oc = o.orderedCalls
        precondition(oc.count == 1 && oc[0].id == "call_0" && ChatToolStream.input(oc[0])["action"] as? String == "start", "whole call, made-up id")
        precondition(o.assistantMessage["content"] as? String == "Sure, setting it.", "think blocks out of what is sent back")

        // Plain text only; noise lines.
        var p = ChatToolStream.Accumulator()
        for l in [": keep-alive", "", "event: x", #"data: {"choices":[]}"#, "data: not json", #"data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":"stop"}]}"#] { _ = p.feed(l) }
        precondition(p.text == "Hi" && p.orderedCalls.isEmpty && p.finish == "stop", "plain reply")
        precondition(ChatToolStream.input(.init(id: "x", name: "y", arguments: "{bad")).isEmpty, "broken arguments: {}")

        // A refusal of tools, and errors that are not one.
        precondition(ChatToolStream.refusesTools(status: 400, body: #"{"error":"llama3 does not support tools"}"#), "ollama")
        precondition(ChatToolStream.refusesTools(status: 422, body: "functions are not supported"), "422 functions")
        precondition(!ChatToolStream.refusesTools(status: 401, body: "invalid tool key"), "401 is not a refusal")
        precondition(!ChatToolStream.refusesTools(status: 400, body: "context length exceeded"), "another 400")
        print("ChatToolStream: all cases passed")
    }
}
