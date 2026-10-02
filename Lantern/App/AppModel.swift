import Foundation
import SwiftUI
import FoundationModels
import PDFKit
import UniformTypeIdentifiers

#if DEBUG
/// 디버그 실행 지시. 실행 인자와 /tmp/lantern-launch.json 을 합친다(인자가 우선).
nonisolated struct DebugLaunch: Decodable {
    var ask: String?
    var deep: Bool?
    var open: String?
    var mcpURL: String?

    static let fileURL = URL(fileURLWithPath: "/tmp/lantern-launch.json")

    static var current: DebugLaunch {
        var directive = (try? JSONDecoder().decode(DebugLaunch.self, from: Data(contentsOf: fileURL))) ?? DebugLaunch()
        let arguments = CommandLine.arguments
        if arguments.contains("-deep") { directive.deep = true }
        if let index = arguments.firstIndex(of: "-autoAsk"), index + 1 < arguments.count { directive.ask = arguments[index + 1] }
        if let index = arguments.firstIndex(of: "-open"), index + 1 < arguments.count { directive.open = arguments[index + 1] }
        return directive
    }
}
#endif

/// 앱 전체 상태. 모델·지식·MCP·음성·대화를 한 곳에서 묶고 뷰에 노출한다.
@Observable
@MainActor
final class AppModel {
    // MARK: 하위 서비스
    let llm = LanguageModelService()
    let store: VectorStore
    let graph = KnowledgeGraph()
    private(set) var agent: LanternAgent!
    private let persistence = Persistence.shared

    // MARK: 대화
    var conversations: [Conversation] = []
    var selectedConversationID: UUID?
    var composerText = ""
    var pendingImages: [ImageAttachment] = []
    var mode: AgentMode = .fast
    var isGenerating = false
    var currentTrace: [TraceEvent] = []
    var lastError: String?

    // MARK: 지식
    var documents: [KnowledgeDocument] = []
    var chunkCount = 0
    var embedderName = "준비 중"
    var graphEntities: [GraphEntity] = []
    var graphRelations: [GraphRelation] = []
    var isIndexing = false
    var indexingNote = ""

    // MARK: 하네스
    var policy: HarnessPolicy {
        didSet { persistence.save(policy, to: "harness-policy.json") }
    }

    // MARK: MCP
    var mcpServers: [MCPServerConfig] = [] {
        didSet { persistence.save(mcpServers, to: "mcp-servers.json") }
    }
    var mcpStates: [UUID: MCPConnectionState] = [:]
    var mcpErrors: [UUID: String] = [:]
    var mcpTools: [MCPToolDescriptor] = []
    var toolCallLog: [String] = []
    private var mcpClients: [UUID: MCPClient] = [:]

    // MARK: 음성
    var speechEngines: [any TranscriptionEngine] = [AppleSpeechEngine(), HuggingFaceWhisperEngine()]
    var selectedSpeechEngineIndex = 0
    var speechNote = ""
    var isListening = false
    var dictationPreview = ""

    // MARK: 초기화

    init() {
        policy = persistence.load(HarnessPolicy.self, from: "harness-policy.json") ?? .default
        store = VectorStore(embedder: HashingEmbedding())
        conversations = persistence.load([Conversation].self, from: "conversations.json") ?? []
        mcpServers = persistence.load([MCPServerConfig].self, from: "mcp-servers.json") ?? []
        if conversations.isEmpty {
            let conversation = Conversation()
            conversations = [conversation]
            selectedConversationID = conversation.id
        } else {
            selectedConversationID = conversations.first?.id
        }
    }

    /// 앱 시작 시 한 번. 모델 가용성, 임베딩 자산, 시드 문서, 음성 엔진 상태를 준비한다.
    func bootstrap() async {
        configureAgentIfNeeded()
        llm.refreshAvailability()
        await refreshKnowledgeCaches()

        if documents.isEmpty {
            isIndexing = true
            indexingNote = "기본 안내 문서를 색인하는 중"
            let document = await store.addDocument(title: SeedKnowledge.title, text: SeedKnowledge.text, source: .seed, origin: "내장")
            for chunk in await store.chunks(for: document.id) { await graph.extractCheap(from: chunk) }
            await graph.persist()
            isIndexing = false
        }

        // Apple 임베딩이 가능하면 교체하고, 엔진이 바뀌었을 때만 재색인한다.
        if let apple = await AppleContextualEmbedding.make() {
            let previous = persistence.load(String.self, from: "embedder.json")
            if previous != apple.name {
                isIndexing = true
                indexingNote = "Apple 임베딩으로 재색인하는 중"
                await store.replaceEmbedder(apple)
                persistence.save(apple.name, to: "embedder.json")
                isIndexing = false
            } else {
                await store.replaceEmbedder(apple)
            }
        } else {
            persistence.save(HashingEmbedding().name, to: "embedder.json")
        }
        await refreshKnowledgeCaches()
        await refreshSpeechNote()
        for server in mcpServers where server.isEnabled {
            await connect(server)
        }
        await runLaunchArgumentsIfNeeded()
    }

    /// 디버그용 실행 지시. 실행 인자(`-autoAsk "질문"`, `-deep`) 또는 `/tmp/lantern-launch.json`
    /// (`{"ask":"…","deep":true,"open":"graph","mcpURL":"http://…"}`)로 자동 질문·모드·MCP 임시 연결을 지정한다.
    private func runLaunchArgumentsIfNeeded() async {
        #if DEBUG
        let directive = DebugLaunch.current
        if directive.deep == true { mode = .deep }
        if let urlString = directive.mcpURL {
            // 저장하지 않는 임시 서버. 스크린샷·검증용.
            let config = MCPServerConfig(name: "임시 MCP (디버그)", transport: .http, url: urlString)
            await connect(config)
        }
        if let question = directive.ask, !question.isEmpty {
            composerText = question
            await send()
        }
        #endif
    }

    /// 에이전트는 self를 참조하는 클로저를 들고 있으므로 init 이후에 만든다.
    /// (AppModel은 앱 수명 동안 하나만 존재하므로 강한 참조 순환은 문제가 되지 않는다.)
    func configureAgentIfNeeded() {
        guard agent == nil else { return }
        agent = LanternAgent(
            llm: llm,
            store: store,
            graph: graph,
            policy: { self.policy },
            externalTools: { self.bridgedTools() },
            onToolCall: { name, result in
                Task { @MainActor in self.toolCallLog.append("\(name): \(result)") }
            }
        )
    }

    func refreshKnowledgeCaches() async {
        documents = await store.documents.sorted { $0.addedAt > $1.addedAt }
        chunkCount = await store.chunkCount
        embedderName = await store.embedderName
        graphEntities = await graph.entityList
        graphRelations = await graph.relationList
    }

    // MARK: 대화

    var selectedConversation: Conversation? {
        guard let selectedConversationID else { return nil }
        return conversations.first { $0.id == selectedConversationID }
    }

    func newConversation() {
        let conversation = Conversation()
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        currentTrace = []
        persistConversations()
    }

    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if selectedConversationID == id { selectedConversationID = conversations.first?.id }
        if conversations.isEmpty { newConversation() }
        persistConversations()
    }

    private func persistConversations() {
        persistence.save(conversations, to: "conversations.json")
    }

    private func updateConversation(_ id: UUID, _ mutate: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        mutate(&conversations[index])
        conversations[index].updatedAt = .now
    }

    private func updateMessage(conversationID: UUID, messageID: UUID, _ mutate: (inout ChatMessage) -> Void) {
        updateConversation(conversationID) { conversation in
            guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
            mutate(&conversation.messages[index])
        }
    }

    /// 사용자 메시지를 보내고 에이전트 그래프를 실행한다.
    func send() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty, !isGenerating else { return }
        guard let conversationID = selectedConversationID else { return }
        guard llm.readiness.isReady else {
            lastError = llm.readiness.message
            return
        }

        let images = pendingImages
        let question = text.isEmpty ? "첨부한 이미지를 설명해 주세요." : text
        composerText = ""
        pendingImages = []
        lastError = nil
        currentTrace = []
        isGenerating = true

        let userMessage = ChatMessage(role: .user, text: question, images: images)
        let assistantMessage = ChatMessage(role: .assistant, text: "", mode: mode, isStreaming: true)
        let history = selectedConversation?.messages ?? []
        updateConversation(conversationID) { conversation in
            conversation.messages.append(userMessage)
            conversation.messages.append(assistantMessage)
            if conversation.messages.count == 2 {
                conversation.title = String(question.prefix(28))
            }
        }

        let cgImages = images.compactMap { ImageUnderstanding.cgImage(from: $0.pngData) }
        configureAgentIfNeeded()
        do {
            let result = try await agent.answer(
                question: question,
                images: cgImages,
                mode: mode,
                history: history,
                onEvent: { [weak self] event in
                    guard let self else { return }
                    if let index = self.currentTrace.firstIndex(where: { $0.nodeID == event.nodeID && $0.status == .running }) {
                        self.currentTrace[index] = event
                    } else {
                        self.currentTrace.append(event)
                    }
                },
                onPartial: { [weak self] partial in
                    self?.updateMessage(conversationID: conversationID, messageID: assistantMessage.id) { $0.text = partial }
                }
            )
            updateMessage(conversationID: conversationID, messageID: assistantMessage.id) { message in
                message.text = result.answer.isEmpty ? "답변을 만들지 못했습니다." : result.answer
                message.citations = result.citations
                message.trace = currentTrace
                message.isStreaming = false
            }
        } catch {
            let description = LanguageModelService.describe(error)
            lastError = description
            updateMessage(conversationID: conversationID, messageID: assistantMessage.id) { message in
                message.text = message.text.isEmpty ? "⚠️ \(description)" : message.text + "\n\n⚠️ \(description)"
                message.trace = currentTrace
                message.isStreaming = false
            }
        }
        isGenerating = false
        persistConversations()
        await refreshKnowledgeCaches()
    }

    // MARK: 첨부

    func attachImage(data: Data) {
        guard ImageUnderstanding.cgImage(from: data) != nil else {
            lastError = "이미지를 읽을 수 없습니다."
            return
        }
        pendingImages.append(ImageAttachment(pngData: data))
    }

    func removePendingImage(_ id: UUID) {
        pendingImages.removeAll { $0.id == id }
    }

    // MARK: 지식 가져오기

    static let importableTypes: [UTType] = [.plainText, .utf8PlainText, .text, .pdf, UTType(filenameExtension: "md") ?? .plainText]

    func importFiles(_ urls: [URL]) async {
        isIndexing = true
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            indexingNote = "\(url.lastPathComponent) 색인 중"
            guard let text = Self.extractText(from: url), !text.isEmpty else {
                lastError = "\(url.lastPathComponent)에서 텍스트를 읽지 못했습니다."
                continue
            }
            let document = await store.addDocument(title: url.deletingPathExtension().lastPathComponent, text: text, source: .file, origin: url.path)
            for chunk in await store.chunks(for: document.id) { await graph.extractCheap(from: chunk) }
        }
        await graph.persist()
        isIndexing = false
        indexingNote = ""
        await refreshKnowledgeCaches()
    }

    func addPastedText(title: String, text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isIndexing = true
        indexingNote = "붙여넣은 텍스트 색인 중"
        let resolvedTitle = title.isEmpty ? String(text.prefix(24)) : title
        let document = await store.addDocument(title: resolvedTitle, text: text, source: .pasted, origin: "붙여넣기")
        for chunk in await store.chunks(for: document.id) { await graph.extractCheap(from: chunk) }
        await graph.persist()
        isIndexing = false
        indexingNote = ""
        await refreshKnowledgeCaches()
    }

    func removeDocument(_ document: KnowledgeDocument) async {
        let chunkIDs = Set(await store.chunks(for: document.id).map(\.id))
        await store.removeDocument(id: document.id)
        await graph.remove(sourceChunkIDs: chunkIDs)
        await refreshKnowledgeCaches()
    }

    /// 심층 트리플 추출(LLM). 문서 하나 또는 전체.
    func extractGraphDeep(for document: KnowledgeDocument?) async {
        guard llm.readiness.isReady else {
            lastError = llm.readiness.message
            return
        }
        configureAgentIfNeeded()
        isIndexing = true
        let chunks: [KnowledgeChunk]
        if let document {
            chunks = await store.chunks(for: document.id)
        } else {
            chunks = await store.chunks
        }
        await agent.extractTriples(for: chunks) { [weak self] done, total in
            self?.indexingNote = "지식 그래프 추출 \(done)/\(total)"
        }
        isIndexing = false
        indexingNote = ""
        await refreshKnowledgeCaches()
    }

    func chunks(for document: KnowledgeDocument) async -> [KnowledgeChunk] {
        await store.chunks(for: document.id)
    }

    func testSearch(_ query: String) async -> [RetrievedChunk] {
        await store.search(query, limit: 5)
    }

    func neighbors(of entityID: String) async -> [GraphRelation] {
        await graph.neighbors(of: entityID)
    }

    private static func extractText(from url: URL) -> String? {
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url) else { return nil }
            var pages: [String] = []
            for index in 0..<pdf.pageCount {
                if let text = pdf.page(at: index)?.string { pages.append(text) }
            }
            return pages.joined(separator: "\n\n")
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        return try? String(contentsOf: url, encoding: .utf16)
    }

    // MARK: MCP

    func addServer(_ config: MCPServerConfig) {
        mcpServers.append(config)
        mcpStates[config.id] = .disconnected
    }

    func removeServer(_ config: MCPServerConfig) async {
        await disconnect(config)
        mcpServers.removeAll { $0.id == config.id }
        mcpStates[config.id] = nil
        mcpErrors[config.id] = nil
    }

    func connect(_ config: MCPServerConfig) async {
        mcpStates[config.id] = .connecting
        mcpErrors[config.id] = nil
        let client = MCPClient(config: config)
        do {
            try await client.connect()
            mcpClients[config.id] = client
            mcpStates[config.id] = .connected
            await refreshMCPTools()
        } catch {
            mcpStates[config.id] = .failed
            mcpErrors[config.id] = error.localizedDescription
        }
    }

    func disconnect(_ config: MCPServerConfig) async {
        if let client = mcpClients[config.id] {
            await client.disconnect()
        }
        mcpClients[config.id] = nil
        mcpStates[config.id] = .disconnected
        await refreshMCPTools()
    }

    func refreshMCPTools() async {
        var tools: [MCPToolDescriptor] = []
        for client in mcpClients.values {
            tools.append(contentsOf: await client.tools)
        }
        mcpTools = tools.sorted { $0.name < $1.name }
    }

    /// 연결된 모든 MCP 도구를 Foundation Models Tool로 감싼 목록(모델 컨텍스트를 아끼려 5개까지)
    func bridgedTools() -> [any Tool] {
        var tools: [any Tool] = []
        for descriptor in mcpTools {
            guard let client = mcpClients[descriptor.serverID] else { continue }
            tools.append(MCPBridgedTool(descriptor: descriptor, client: client, onCall: { name, result in
                Task { @MainActor in self.toolCallLog.append("\(name): \(result)") }
            }))
            if tools.count >= 5 { break }
        }
        return tools
    }

    /// 수동 도구 호출(MCP 화면에서 테스트용)
    func callTool(_ descriptor: MCPToolDescriptor, argumentsJSON: String) async -> String {
        guard let client = mcpClients[descriptor.serverID] else { return "서버가 연결되어 있지 않습니다." }
        let arguments = (try? JSONDecoder().decode(JSONValue.self, from: Data(argumentsJSON.utf8))) ?? .object([:])
        do {
            return try await client.callTool(name: descriptor.name, arguments: arguments)
        } catch {
            return "오류: \(error.localizedDescription)"
        }
    }

    // MARK: 음성

    var selectedSpeechEngine: any TranscriptionEngine {
        speechEngines[min(selectedSpeechEngineIndex, speechEngines.count - 1)]
    }

    func refreshSpeechNote() async {
        let availability = await selectedSpeechEngine.availability()
        speechNote = availability.note
    }

    func toggleDictation() async {
        if isListening {
            await selectedSpeechEngine.stop()
            isListening = false
            if !dictationPreview.isEmpty {
                appendDictation(dictationPreview)
            }
            dictationPreview = ""
            return
        }
        do {
            try await selectedSpeechEngine.start(
                onPartial: { [weak self] text in self?.dictationPreview = text },
                onFinal: { [weak self] text in self?.dictationPreview = text }
            )
            isListening = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func appendDictation(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        composerText = composerText.isEmpty ? trimmed : composerText + " " + trimmed
    }
}
