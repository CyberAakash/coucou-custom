import Foundation

// coucou-custom fork: the Buddy's tools for the streamed OpenAI-style providers (DeepSeek, Qwen,
// Moonshot, Ollama, LM Studio). The reply still streams; tool calls arrive in pieces in the
// stream (`delta.tool_calls`, by index), are put together, run, answered, and the model goes on.
// A server or a model without tools says so with an error: the chat then streams as before.

enum ChatToolStream {
    struct Call: Equatable, Sendable {
        var id = ""
        var name = ""
        var arguments = ""
    }

    /// One streamed reply put together from its SSE lines.
    struct Accumulator: Equatable {
        var text = ""
        private(set) var calls: [Int: Call] = [:]
        var finish: String?

        /// Reads one SSE line; true when the text grew.
        mutating func feed(_ line: String) -> Bool {
            guard line.hasPrefix("data:") else { return false }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choice = (json["choices"] as? [[String: Any]])?.first else { return false }
            if let f = choice["finish_reason"] as? String { finish = f }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            for (n, piece) in (delta["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
                let i = piece["index"] as? Int ?? n
                var c = calls[i] ?? Call()
                if let id = piece["id"] as? String, !id.isEmpty { c.id = id }
                if let fn = piece["function"] as? [String: Any] {
                    if let name = fn["name"] as? String { c.name += name }
                    // Some servers send the arguments whole, as an object.
                    if let a = fn["arguments"] as? String { c.arguments += a }
                    else if let o = fn["arguments"], JSONSerialization.isValidJSONObject(o),
                            let d = try? JSONSerialization.data(withJSONObject: o) { c.arguments = String(decoding: d, as: UTF8.self) }
                }
                calls[i] = c
            }
            if let t = delta["content"] as? String, !t.isEmpty { text += t; return true }
            return false
        }

        /// The calls in order, each with an id (made up when the server gave none).
        var orderedCalls: [Call] {
            calls.keys.sorted().compactMap { i in
                guard var c = calls[i], !c.name.isEmpty else { return nil }
                if c.id.isEmpty { c.id = "call_\(i)" }
                return c
            }
        }

        /// The assistant message to send back with the results.
        var assistantMessage: [String: Any] {
            var m: [String: Any] = ["role": "assistant",
                                    "content": text.isEmpty ? NSNull() as Any : LocalChat.filterThinkingBlocks(text)]
            m["tool_calls"] = orderedCalls.map { c in
                ["id": c.id, "type": "function", "function": ["name": c.name, "arguments": c.arguments.isEmpty ? "{}" : c.arguments]]
            }
            return m
        }
    }

    /// The arguments' JSON, {} when broken.
    static func input(_ c: Call) -> [String: Any] {
        guard let d = c.arguments.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    /// The server refused the request because of `tools` (a model without them, an old server).
    static func refusesTools(status: Int, body: String) -> Bool {
        guard status == 400 || status == 404 || status == 422 || status == 500 else { return false }
        let b = body.lowercased()
        return b.contains("tool") || b.contains("function")
    }

    #if !APPSTORE
    /// Streams the reply with the Buddy's tools, running their calls (each shown in the chat before
    /// the reply's bubble `placeholder`); returns the final text, or nil when tools are refused.
    /// Throws LocalChatError as LocalChat.streamChat does.
    @MainActor
    static func run(baseURL: String, apiKey: String?, model: String, messages: [[String: Any]],
                    state: AppState, placeholder: UUID) async throws -> String? {
        var msgs = messages
        let endpoint = LocalChat.streamEndpoint(baseURL: baseURL, apiKey: apiKey)
        guard let url = URL(string: endpoint.url) else { throw LocalChatError.serverUnreachable(baseURL) }
        for round in 0..<6 {
            var body: [String: Any] = ["model": model, "messages": msgs, "stream": true, "max_tokens": 4096]
            if round < 5 { body["tools"] = BuddyToolCatalog.openAI }   // the last round answers in words
            var req = URLRequest(url: url, timeoutInterval: 300)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(endpoint.authorization, forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            let bytes: URLSession.AsyncBytes, response: URLResponse
            do { (bytes, response) = try await URLSession.shared.bytes(for: req) }
            catch { throw LocalChatError.serverUnreachable(baseURL) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                var raw = Data()
                do { for try await b in bytes { raw.append(b); if raw.count > 8192 { break } } } catch {}
                let text = String(decoding: raw, as: UTF8.self)
                if round == 0, refusesTools(status: status, body: text) { return nil }
                if status == 404 { throw LocalChatError.modelNotFound(model) }
                if let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                   let msg = (json["error"] as? [String: Any])?["message"] as? String { throw LocalChatError.serverError(msg) }
                throw LocalChatError.serverError("HTTP \(status)")
            }

            var acc = Accumulator()
            var last = Date.distantPast
            do {
                for try await line in bytes.lines {
                    guard acc.feed(line) else { continue }
                    if Date().timeIntervalSince(last) >= 1.0 / 15.0 {
                        last = Date()
                        show(LocalChat.progressiveFilter(acc.text), state: state, in: placeholder)
                    }
                }
            } catch { throw LocalChatError.serverUnreachable(baseURL) }

            let calls = acc.orderedCalls
            guard !calls.isEmpty else {
                let final = LocalChat.filterThinkingBlocks(acc.text).trimmingCharacters(in: .whitespacesAndNewlines)
                show(final, state: state, in: placeholder)
                return final
            }
            msgs.append(acc.assistantMessage)
            for c in calls {
                let result = await BuddyToolRunner.runShown(c.name, input(c), state: state, before: placeholder)
                msgs.append(["role": "tool", "tool_call_id": c.id, "content": result])
            }
            show("", state: state, in: placeholder)   // what it said before the calls goes; the answer follows
        }
        return ""
    }

    @MainActor
    private static func show(_ visible: String, state: AppState, in id: UUID) {
        if !visible.isEmpty, state.stateOverride == .thinking { state.stateOverride = nil }
        if let i = state.chatHistory.firstIndex(where: { $0.id == id }) { state.chatHistory[i].content = visible }
    }
    #endif
}
