import SwiftUI

/// 사이드바 목적지
enum Destination: Hashable {
    case chat(UUID)
    case knowledge
    case graph
    case mcp
    case settings
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var destination: Destination?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .task {
            await model.bootstrap()
        }
        .onAppear {
            if destination == nil, let id = model.selectedConversationID {
                destination = .chat(id)
            }
            #if DEBUG
            // 스크린샷/디버그용: -open knowledge|graph|mcp|settings 또는 /tmp/lantern-launch.json 의 "open"
            if let target = DebugLaunch.current.open {
                switch target {
                case "knowledge": destination = .knowledge
                case "graph": destination = .graph
                case "mcp": destination = .mcp
                case "settings": destination = .settings
                default: break
                }
            }
            #endif
        }
        .onChange(of: destination) {
            if case .chat(let id) = destination {
                model.selectedConversationID = id
            }
        }
        .onChange(of: model.selectedConversationID) {
            if let id = model.selectedConversationID, destination != .chat(id), isChatDestination {
                destination = .chat(id)
            }
        }
    }

    private var isChatDestination: Bool {
        if case .chat = destination { return true }
        return destination == nil
    }

    private var sidebar: some View {
        List(selection: $destination) {
            Section("대화") {
                ForEach(model.conversations) { conversation in
                    Label(conversation.title, systemImage: "bubble.left.and.text.bubble.right")
                        .tag(Destination.chat(conversation.id))
                        .contextMenu {
                            Button("삭제", role: .destructive) { model.deleteConversation(conversation.id) }
                        }
                }
            }
            Section("작업 공간") {
                Label("지식 저장소", systemImage: "books.vertical").tag(Destination.knowledge)
                Label("그래프", systemImage: "point.3.filled.connected.trianglepath.dotted").tag(Destination.graph)
                Label("MCP 연결", systemImage: "cable.connector").tag(Destination.mcp)
                Label("설정", systemImage: "gearshape").tag(Destination.settings)
            }
        }
        .navigationTitle("Lantern")
        .toolbar {
            ToolbarItem {
                Button {
                    model.newConversation()
                    if let id = model.selectedConversationID { destination = .chat(id) }
                } label: {
                    Label("새 대화", systemImage: "square.and.pencil")
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }

    @ViewBuilder
    private var detail: some View {
        switch destination {
        case .chat, .none:
            ChatView()
        case .knowledge:
            KnowledgeView()
        case .graph:
            GraphView()
        case .mcp:
            MCPView()
        case .settings:
            SettingsView()
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}
