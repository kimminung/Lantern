import Foundation

/// MCP(Model Context Protocol) JSON-RPC 2.0 클라이언트.
/// - stdio 전송: macOS에서 로컬 서버 프로세스를 띄우고 줄 단위 JSON으로 통신한다.
/// - Streamable HTTP 전송: POST로 요청을 보내고 JSON 또는 SSE 응답을 읽는다.
actor MCPClient {
    enum MCPError: LocalizedError {
        case notConnected
        case transportUnavailable(String)
        case server(code: Int, message: String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "MCP 서버에 연결되어 있지 않습니다"
            case .transportUnavailable(let reason): return reason
            case .server(let code, let message): return "MCP 서버 오류 \(code): \(message)"
            case .malformed(let detail): return "MCP 응답 형식 오류: \(detail)"
            }
        }
    }

    let config: MCPServerConfig
    private(set) var tools: [MCPToolDescriptor] = []
    private(set) var serverInfo: String = ""
    private var nextID = 1
    private var transport: (any MCPTransport)?

    init(config: MCPServerConfig) {
        self.config = config
    }

    // MARK: 연결

    func connect() async throws {
        let transport: any MCPTransport
        switch config.transport {
        case .stdio:
            #if os(macOS)
            transport = try StdioTransport(command: config.command, arguments: config.arguments)
            #else
            throw MCPError.transportUnavailable("stdio 전송은 macOS에서만 지원됩니다. HTTP 전송을 사용하세요.")
            #endif
        case .http:
            guard let url = URL(string: config.url) else {
                throw MCPError.transportUnavailable("잘못된 URL입니다: \(config.url)")
            }
            transport = HTTPTransport(url: url, headers: config.headers)
        }
        self.transport = transport

        let initResult = try await request(
            method: "initialize",
            params: .object([
                "protocolVersion": .string("2025-06-18"),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("Lantern"), "version": .string("1.0")]),
            ])
        )
        if let info = initResult["serverInfo"] {
            let name = info["name"]?.stringValue ?? "server"
            let version = info["version"]?.stringValue ?? ""
            serverInfo = "\(name) \(version)".trimmingCharacters(in: .whitespaces)
        }
        try await transport.notify(method: "notifications/initialized", params: .object([:]))
        try await refreshTools()
    }

    func disconnect() async {
        await transport?.close()
        transport = nil
        tools = []
    }

    // MARK: 도구

    func refreshTools() async throws {
        let result = try await request(method: "tools/list", params: .object([:]))
        guard let list = result["tools"]?.arrayValue else {
            throw MCPError.malformed("tools 배열이 없습니다")
        }
        tools = list.compactMap { item in
            guard let name = item["name"]?.stringValue else { return nil }
            return MCPToolDescriptor(
                serverID: config.id,
                serverName: config.name,
                name: name,
                description: item["description"]?.stringValue ?? "",
                inputSchema: item["inputSchema"] ?? .object(["type": .string("object")])
            )
        }
    }

    /// 도구 호출. content 배열의 text 항목을 합쳐 문자열로 돌려준다.
    func callTool(name: String, arguments: JSONValue) async throws -> String {
        let result = try await request(
            method: "tools/call",
            params: .object(["name": .string(name), "arguments": arguments])
        )
        if result["isError"]?.boolValue == true {
            let text = Self.flattenContent(result["content"])
            throw MCPError.server(code: -1, message: text.isEmpty ? "도구 실행 실패" : text)
        }
        let text = Self.flattenContent(result["content"])
        if text.isEmpty, let structured = result["structuredContent"] {
            return structured.prettyText
        }
        return text
    }

    private static func flattenContent(_ content: JSONValue?) -> String {
        guard let items = content?.arrayValue else { return "" }
        return items.compactMap { item -> String? in
            switch item["type"]?.stringValue {
            case "text": return item["text"]?.stringValue
            case "image": return "[이미지 \(item["mimeType"]?.stringValue ?? "")]"
            case "resource": return item["resource"]?["text"]?.stringValue
            default: return item.prettyText
            }
        }.joined(separator: "\n")
    }

    // MARK: JSON-RPC

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard let transport else { throw MCPError.notConnected }
        let id = nextID
        nextID += 1
        let payload: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ])
        let response = try await transport.send(payload, expectingID: id)
        if let error = response["error"] {
            let code = Int(error["code"]?.numberValue ?? -1)
            throw MCPError.server(code: code, message: error["message"]?.stringValue ?? "알 수 없는 오류")
        }
        return response["result"] ?? .null
    }
}

// MARK: - 전송 계층

nonisolated protocol MCPTransport: Sendable {
    func send(_ payload: JSONValue, expectingID id: Int) async throws -> JSONValue
    func notify(method: String, params: JSONValue) async throws
    func close() async
}

nonisolated enum MCPCodec {
    static func encode(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

#if os(macOS)
/// 로컬 프로세스와 줄 단위 JSON-RPC로 통신한다.
nonisolated final class StdioTransport: MCPTransport, @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let reader: LineReader

    init(command: String, arguments: [String]) throws {
        guard !command.isEmpty else {
            throw MCPClient.MCPError.transportUnavailable("실행 명령이 비어 있습니다")
        }
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // npx 등 Homebrew 경로가 PATH에 없을 때를 대비한다.
        environment["PATH"] = (environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
        // Xcode 프리뷰/디버거가 주입하는 DYLD_* 변수는 자식 프로세스를 죽이므로 물려주지 않는다.
        for key in environment.keys where key.hasPrefix("DYLD_") { environment[key] = nil }
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        reader = LineReader(handle: stdoutPipe.fileHandleForReading)
        do {
            try process.run()
        } catch {
            throw MCPClient.MCPError.transportUnavailable("프로세스를 시작할 수 없습니다: \(error.localizedDescription)")
        }
    }

    func send(_ payload: JSONValue, expectingID id: Int) async throws -> JSONValue {
        var data = try MCPCodec.encode(payload)
        data.append(0x0A)
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        // 알림(notification)이 섞여 올 수 있으므로 id가 맞는 응답이 올 때까지 읽는다.
        while let line = try await reader.nextLine() {
            guard let lineData = line.data(using: .utf8), !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let message = try? MCPCodec.decode(lineData) else { continue }
            if let responseID = message["id"]?.numberValue, Int(responseID) == id {
                return message
            }
        }
        // 서버가 끝났다. stderr를 읽어 원인을 함께 알려준다.
        let stderrText = String(data: stderrPipe.fileHandleForReading.availableData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let status = process.isRunning ? "실행 중" : "종료 코드 \(process.terminationStatus)"
        throw MCPClient.MCPError.malformed("서버가 응답 없이 종료되었습니다 (\(status))" + (stderrText.isEmpty ? "" : "\n\(stderrText.prefix(300))"))
    }

    func notify(method: String, params: JSONValue) async throws {
        let payload: JSONValue = .object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params])
        var data = try MCPCodec.encode(payload)
        data.append(0x0A)
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    func close() async {
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

/// 파일 핸들에서 줄 단위로 비동기 읽기
nonisolated final class LineReader: @unchecked Sendable {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func nextLine() async throws -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(data: lineData, encoding: .utf8)
            }
            let chunk = await Task.detached(priority: .userInitiated) { [handle] in
                handle.availableData
            }.value
            if chunk.isEmpty { return buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8) }
            buffer.append(chunk)
        }
    }
}
#endif

/// Streamable HTTP 전송. 응답이 application/json이면 바로 파싱하고, text/event-stream이면 data: 줄을 모아 파싱한다.
nonisolated final class HTTPTransport: MCPTransport, @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private var sessionID: String?
    private let lock = NSLock()

    init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }

    private func makeRequest(body: Data) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let currentSession = lock.withLock({ sessionID }) {
            request.setValue(currentSession, forHTTPHeaderField: "Mcp-Session-Id")
        }
        return request
    }

    func send(_ payload: JSONValue, expectingID id: Int) async throws -> JSONValue {
        let request = makeRequest(body: try MCPCodec.encode(payload))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPClient.MCPError.malformed("HTTP 응답이 아닙니다")
        }
        if let newSession = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            lock.withLock { sessionID = newSession }
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPClient.MCPError.server(code: http.statusCode, message: String(data: data, encoding: .utf8) ?? "")
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/event-stream") {
            let text = String(data: data, encoding: .utf8) ?? ""
            for line in text.components(separatedBy: "\n") where line.hasPrefix("data:") {
                let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let jsonData = json.data(using: .utf8), let message = try? MCPCodec.decode(jsonData) else { continue }
                if let responseID = message["id"]?.numberValue, Int(responseID) == id {
                    return message
                }
            }
            throw MCPClient.MCPError.malformed("SSE 스트림에 응답이 없습니다")
        }
        return try MCPCodec.decode(data)
    }

    func notify(method: String, params: JSONValue) async throws {
        let payload: JSONValue = .object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params])
        let request = makeRequest(body: try MCPCodec.encode(payload))
        _ = try? await URLSession.shared.data(for: request)
    }

    func close() async {
        let currentSession = lock.withLock { sessionID }
        guard currentSession != nil else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(currentSession, forHTTPHeaderField: "Mcp-Session-Id")
        _ = try? await URLSession.shared.data(for: request)
    }
}
