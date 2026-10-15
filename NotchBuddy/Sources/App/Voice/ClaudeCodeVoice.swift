#if !APPSTORE
import Foundation
import Network

// MARK: - ClaudeCodeVoice
//
// "OK Coucou, …" on the user's Claude Code login instead of an API key. The API brain hands
// Claude Coucou's tools directly; `claude -p` cannot take raw tool definitions, so for the turn
// Coucou serves them as an MCP server on loopback (VoiceToolServer) and the CLI calls them like
// any MCP tool. One CLI run covers every tool round of a turn; the next turn resumes its session.
@MainActor
final class ClaudeCodeVoice {
    static let shared = ClaudeCodeVoice()

    private static let model = "haiku"
    /// Spawning the CLI and connecting MCP cost ~3 s before the first token.
    private static let timeout: TimeInterval = 60

    private var sessionID: String?
    private var busy = false

    func reset() { sessionID = nil }

    /// The CLI's web search makes Claude end with a "Sources:" list of links: fine in the chat,
    /// noise when read aloud.
    nonisolated static func withoutSources(_ text: String) -> String {
        guard let r = text.range(of: #"\n\s*\**Sources\**:?\**\s*\n"#, options: [.regularExpression, .caseInsensitive])
        else { return text }
        return String(text[..<r.lowerBound])
    }

    func respond(to transcript: String, brain: ClaudeVoiceBrain) async -> ClaudeVoiceBrain.Reply? {
        guard !busy else { return nil }
        busy = true
        defer { busy = false }

        let acted = ActedFlag()
        let server = VoiceToolServer(tools: ClaudeVoiceBrain.mcpTools) { name, input in
            let (result, didAct) = await brain.run(tool: name, input: input)
            if didAct { acted.value = true }
            return result
        }
        guard let config = try? await server.start() else {
            appendAppLog("nb.log", "[Voice] Claude Code tool server failed to start")
            return nil
        }
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: config)
        }

        do {
            let reply = try await ClaudeCodeCLI.run(
                prompt: transcript,
                system: ClaudeVoiceBrain.systemPrompt() + "\n" + VoiceSettings.locationLine,
                model: Self.model,
                webSearch: true,
                mcpConfig: config,
                allowedTools: ClaudeVoiceBrain.mcpTools.compactMap { $0["name"] as? String }
                    .map { "mcp__\(VoiceToolServer.serverName)__\($0)" },
                resume: sessionID,
                timeout: Self.timeout)
            sessionID = reply.sessionID
            let text = VoiceQuery.spokenText(Self.withoutSources(reply.text))
            return ClaudeVoiceBrain.Reply(text: text, acted: acted.value, failed: text.isEmpty && !acted.value)
        } catch {
            appendAppLog("nb.log", "[Voice] Claude Code turn failed: \(error.localizedDescription)")
            // Something already happened (a pill, the music, the mail card): the parser must
            // not do it again.
            return acted.value ? ClaudeVoiceBrain.Reply(text: "", acted: true, failed: false) : nil
        }
    }
}

@MainActor private final class ActedFlag { var value = false }

extension ClaudeVoiceBrain {
    /// The brain's own tools; Anthropic's server-side web_search is the CLI's WebSearch here.
    /// With a city set, service_info also answers the weather (Open-Meteo, no key), which is
    /// quicker and surer than a web search.
    static var mcpTools: [[String: Any]] {
        let hasCity = !VoiceSettings.weatherCity.trimmingCharacters(in: .whitespaces).isEmpty
        return tools.filter { $0["input_schema"] != nil }.map { tool in
            guard hasCity, tool["name"] as? String == "service_info" else { return tool }
            var tool = tool
            tool["description"] = (tool["description"] as? String ?? "") + " Also the weather today or tomorrow at the user's city."
            tool["input_schema"] = ["type": "object",
                                    "properties": ["topic": ["type": "string", "enum": VoiceTopic.allCases.map(\.rawValue)]],
                                    "required": ["topic"]]
            return tool
        }
    }
}

// MARK: - VoiceToolServer
//
// The smallest MCP "streamable HTTP" server Claude Code accepts: JSON-RPC over POST, answered
// with plain JSON (no SSE stream; GET gets 405, which the client reads as "no stream").
// Bound to 127.0.0.1 on a random port, guarded by a random bearer token, alive for one voice
// turn. The token reaches the CLI in a 0600 config file, not argv, which other users can read.
final class VoiceToolServer: @unchecked Sendable {
    static let serverName = "coucou"

    typealias Handler = @MainActor @Sendable (String, [String: Any]) async -> String

    private let tools: [[String: Any]]
    private let handler: Handler
    private let token = UUID().uuidString + UUID().uuidString
    private let queue = DispatchQueue(label: "coucou.voice-tools")
    private var listener: NWListener?

    init(tools: [[String: Any]], handler: @escaping Handler) {
        self.tools = tools
        self.handler = handler
    }

    /// Starts listening and returns the path of the MCP config file to pass to the CLI.
    func start() async throws -> URL {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // Only touched on `queue`, where every state update arrives.
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    once.done = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        let config: [String: Any] = ["mcpServers": [Self.serverName: [
            "type": "http",
            "url": "http://127.0.0.1:\(port)/mcp",
            "headers": ["Authorization": "Bearer \(token)"],
        ]]]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coucou-voice-mcp-\(UUID().uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: config)
        guard FileManager.default.createFile(atPath: url.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, done, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            if let request = HTTPRequest(buffer) {
                self.handle(request, on: connection)
            } else if done || error != nil || buffer.count > 4 << 20 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        guard request.headers["authorization"] == "Bearer \(token)" else {
            return send(status: "401 Unauthorized", body: nil, on: connection)
        }
        switch request.method {
        case "POST": break
        case "DELETE": return send(status: "200 OK", body: nil, on: connection)
        default: return send(status: "405 Method Not Allowed", body: nil, on: connection)
        }
        guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return send(status: "400 Bad Request", body: nil, on: connection)
        }
        // A notification (no id) only needs acknowledging.
        guard let id = RPCID(message["id"]) else {
            return send(status: "202 Accepted", body: nil, on: connection)
        }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            reply(id: id, result: [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": Self.serverName, "version": "1"],
            ], on: connection)
        case "ping":
            reply(id: id, result: [:], on: connection)
        case "tools/list":
            let list = tools.map { tool -> [String: Any] in
                ["name": tool["name"] ?? "", "description": tool["description"] ?? "",
                 "inputSchema": tool["input_schema"] ?? ["type": "object"]]
            }
            reply(id: id, result: ["tools": list], on: connection)
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let handler = self.handler
            // Dictionaries of Any are not Sendable; the JSON round trip carries them across.
            let encoded = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
            Task { @MainActor in
                let input = (try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]) ?? [:]
                let text = await handler(name, input)
                self.reply(id: id, result: ["content": [["type": "text", "text": text]], "isError": false],
                           on: connection)
            }
        default:
            let body: [String: Any] = ["jsonrpc": "2.0", "id": id.json,
                                       "error": ["code": -32601, "message": "Method not found: \(method)"]]
            send(status: "200 OK", body: try? JSONSerialization.data(withJSONObject: body), on: connection)
        }
    }

    private func reply(id: RPCID, result: [String: Any], on connection: NWConnection) {
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id.json, "result": result]
        send(status: "200 OK", body: try? JSONSerialization.data(withJSONObject: body), on: connection)
    }

    private func send(status: String, body: Data?, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: \(body?.count ?? 0)\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        var data = Data((head + "\r\n").utf8)
        if let body { data.append(body) }
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// JSON-RPC ids are numbers or strings; this carries one across actors.
private enum RPCID: Sendable {
    case number(Int), string(String)

    init?(_ raw: Any?) {
        if let n = raw as? Int { self = .number(n) }
        else if let s = raw as? String { self = .string(s) }
        else { return nil }
    }

    var json: Any {
        switch self {
        case .number(let n): n
        case .string(let s): s
        }
    }
}

/// One complete HTTP/1.1 request, or nil while more bytes are needed.
private struct HTTPRequest {
    let method: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first?.split(separator: " "), let method = requestLine.first else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        self.method = String(method)
        self.headers = headers
        self.body = data[bodyStart..<(bodyStart + length)]
    }
}
#endif
