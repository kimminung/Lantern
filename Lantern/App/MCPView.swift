import SwiftUI

/// MCP 서버 관리 화면: 서버 추가/연결, 도구 목록, 수동 호출 테스트
struct MCPView: View {
    @Environment(AppModel.self) private var model
    @State private var showAddSheet = false
    @State private var selectedTool: MCPToolDescriptor?
    @State private var argumentsJSON = "{}"
    @State private var callResult = ""

    var body: some View {
        HSplitOrStack {
            serverList.frame(minWidth: 300)
        } detail: {
            toolDetail
        }
        .navigationTitle("MCP 연결")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddSheet = true } label: { Label("서버 추가", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddMCPServerSheet()
        }
    }

    private var serverList: some View {
        List {
            Section("서버") {
                if model.mcpServers.isEmpty {
                    Text("아직 서버가 없습니다. 오른쪽 위 + 로 추가하세요.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.mcpServers) { server in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Circle()
                                .fill(color(for: model.mcpStates[server.id] ?? .disconnected))
                                .frame(width: 8, height: 8)
                            Text(server.name).font(.body.bold())
                            Spacer()
                            Text(server.transport.rawValue).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(server.transport == .stdio ? "\(server.command) \(server.arguments.joined(separator: " "))" : server.url)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if let error = model.mcpErrors[server.id] {
                            Text(error).font(.caption2).foregroundStyle(.red)
                        }
                        HStack {
                            if model.mcpStates[server.id] == .connected {
                                Button("연결 해제") { Task { await model.disconnect(server) } }
                            } else {
                                Button("연결") { Task { await model.connect(server) } }
                                    .disabled(model.mcpStates[server.id] == .connecting)
                            }
                            Button("삭제", role: .destructive) { Task { await model.removeServer(server) } }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
            Section("도구 (\(model.mcpTools.count))") {
                ForEach(model.mcpTools) { tool in
                    Button {
                        selectedTool = tool
                        argumentsJSON = sampleArguments(for: tool)
                        callResult = ""
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name).font(.body)
                            Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(tool.serverName).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var toolDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let tool = selectedTool {
                Text(tool.name).font(.title3.bold())
                Text(tool.description).foregroundStyle(.secondary)
                Text("입력 스키마").font(.headline)
                ScrollView {
                    Text(tool.inputSchema.prettyText).font(.caption.monospaced()).textSelection(.enabled)
                }
                .frame(maxHeight: 160)
                Text("인자 (JSON)").font(.headline)
                TextEditor(text: $argumentsJSON)
                    .font(.callout.monospaced())
                    .frame(minHeight: 80, maxHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Button("도구 호출") {
                    Task { callResult = await model.callTool(tool, argumentsJSON: argumentsJSON) }
                }
                .buttonStyle(.borderedProminent)
                if !callResult.isEmpty {
                    Text("결과").font(.headline)
                    ScrollView {
                        Text(callResult).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            } else {
                ContentUnavailableView(
                    "도구를 선택하세요",
                    systemImage: "wrench.and.screwdriver",
                    description: Text("연결된 서버의 도구는 자동으로 모델에 제공됩니다. 여기서는 수동으로 호출해 볼 수 있습니다.\n\n예시 (macOS, Node 설치 필요):\n/opt/homebrew/bin/npx  -y @modelcontextprotocol/server-filesystem /Users/\(NSUserName())/Documents")
                )
            }
            Spacer()
        }
        .padding()
    }

    private func color(for state: MCPConnectionState) -> Color {
        switch state {
        case .disconnected: return .gray
        case .connecting: return .yellow
        case .connected: return .green
        case .failed: return .red
        }
    }

    /// 스키마의 필수 속성으로 샘플 JSON을 만든다.
    private func sampleArguments(for tool: MCPToolDescriptor) -> String {
        guard let properties = tool.inputSchema["properties"]?.objectValue else { return "{}" }
        var sample: [String: JSONValue] = [:]
        for (key, schema) in properties {
            switch schema["type"]?.stringValue {
            case "integer", "number": sample[key] = .number(1)
            case "boolean": sample[key] = .bool(true)
            case "array": sample[key] = .array([])
            default: sample[key] = .string("")
            }
        }
        return JSONValue.object(sample).prettyText
    }
}

/// 서버 추가 시트
struct AddMCPServerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var transport: MCPServerConfig.Transport = .http
    @State private var command = "/opt/homebrew/bin/npx"
    @State private var argumentsText = "-y @modelcontextprotocol/server-everything"
    @State private var url = "http://localhost:3000/mcp"
    @State private var authHeader = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MCP 서버 추가").font(.headline)
            Form {
                TextField("이름", text: $name)
                Picker("전송", selection: $transport) {
                    ForEach(MCPServerConfig.Transport.allCases) { transport in
                        Text(transport.title).tag(transport)
                    }
                }
                if transport == .stdio {
                    TextField("실행 파일 경로", text: $command)
                    TextField("인자 (공백 구분)", text: $argumentsText)
                    #if !os(macOS)
                    Text("stdio 전송은 macOS에서만 동작합니다.").font(.caption).foregroundStyle(.orange)
                    #endif
                } else {
                    TextField("엔드포인트 URL", text: $url)
                    TextField("Authorization 헤더 (선택)", text: $authHeader)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("추가") {
                    var headers: [String: String] = [:]
                    if !authHeader.isEmpty { headers["Authorization"] = authHeader }
                    let config = MCPServerConfig(
                        name: name.isEmpty ? (transport == .stdio ? "로컬 서버" : "HTTP 서버") : name,
                        transport: transport,
                        command: command,
                        arguments: argumentsText.split(separator: " ").map(String.init),
                        url: url,
                        headers: headers
                    )
                    model.addServer(config)
                    dismiss()
                    Task { await model.connect(config) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 320)
    }
}
