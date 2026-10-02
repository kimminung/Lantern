import Foundation
import CoreGraphics
import FoundationModels
import Vision

/// 그래프를 흐르는 상태. 각 노드가 읽고 채운다.
struct AgentState {
    let question: String
    let images: [CGImage]
    let mode: AgentMode
    let history: [ChatMessage]

    var language = "한국어"
    var imageNotes: [String] = []
    var queries: [String] = []
    var retrieved: [RetrievedChunk] = []
    var graphFacts: [String] = []
    var toolResults: [String] = []
    var toolCallLog: [String] = []
    var knowledgeGap = false
    var context: AssembledContext?
    var draft = ""
    var repairCount = 0
    var verdict: GroundingVerdict?
    var answer = ""
    var citations: [Citation] = []
}

/// 랜턴 에이전트: StateGraph 위에 RAG·지식 그래프·MCP 도구·하네스를 노드로 올린다.
@MainActor
final class LanternAgent {
    /// 그래프 노드 식별자(다이어그램과 추적 UI가 공유)
    enum NodeID {
        static let intake = "intake"
        static let vision = "vision"
        static let rewrite = "rewrite"
        static let retrieve = "retrieve"
        static let grade = "grade"
        static let graph = "graph"
        static let tools = "tools"
        static let learn = "learn"
        static let generate = "generate"
        static let verify = "verify"
        static let finalize = "finalize"
    }

    /// 다이어그램용 정적 노드 목록(순서 포함)
    static let nodeTitles: [(id: String, title: String)] = [
        (NodeID.intake, "입력 분석"),
        (NodeID.vision, "이미지 이해"),
        (NodeID.rewrite, "질의 재작성"),
        (NodeID.retrieve, "하이브리드 검색"),
        (NodeID.grade, "관련성 채점"),
        (NodeID.graph, "그래프 확장"),
        (NodeID.tools, "외부 도구(MCP)"),
        (NodeID.learn, "지식 학습"),
        (NodeID.generate, "초안 생성"),
        (NodeID.verify, "하네스 검증"),
        (NodeID.finalize, "마무리"),
    ]

    private let llm: LanguageModelService
    private let store: VectorStore
    private let graph: KnowledgeGraph
    private let policy: () -> HarnessPolicy
    private let externalTools: () -> [any Tool]
    private let onToolCall: @Sendable (String, String) -> Void

    /// 지식 부족으로 판단하는 하이브리드 점수 문턱.
    /// NLContextualEmbedding은 무관한 문장끼리도 코사인 0.6 안팎이 나오므로(하이브리드 ≈ 0.41), 관련 문서(0.57~0.71)와 갈라지는 0.45를 쓴다.
    private let gapThreshold = 0.45

    init(
        llm: LanguageModelService,
        store: VectorStore,
        graph: KnowledgeGraph,
        policy: @escaping () -> HarnessPolicy,
        externalTools: @escaping () -> [any Tool],
        onToolCall: @escaping @Sendable (String, String) -> Void
    ) {
        self.llm = llm
        self.store = store
        self.graph = graph
        self.policy = policy
        self.externalTools = externalTools
        self.onToolCall = onToolCall
    }

    // MARK: 그래프 조립

    func buildGraph(onPartial: @escaping @MainActor (String) -> Void) -> StateGraph<AgentState> {
        let graphEngine = StateGraph<AgentState>()
        let policy = policy()

        graphEngine.addNode(NodeID.intake, title: "입력 분석") { state in
            state.language = Harness.detectLanguage(state.question)
            state.queries = [state.question]
            return "언어 \(state.language), 모드 \(state.mode.title)"
        }

        graphEngine.addNode(NodeID.vision, title: "이미지 이해") { state in
            guard !state.images.isEmpty else { return "⏭ 첨부 이미지 없음" }
            for (index, image) in state.images.enumerated() {
                let analysis = await ImageUnderstanding.analyze(image)
                state.imageNotes.append("image-\(index + 1): \(analysis.summaryLine)")
            }
            return "이미지 \(state.images.count)장 분석"
        }

        graphEngine.addNode(NodeID.rewrite, title: "질의 재작성") { [llm] state in
            guard state.mode == .deep else { return "⏭ 빠른 모드" }
            let session = llm.makeSession(instructions: "너는 검색 질의를 다듬는 도우미다. 질문의 핵심 명사를 유지하고 짧게 쓴다.")
            do {
                let rewrite = try await llm.generate(session, prompt: "질문: \(state.question)", as: QueryRewrite.self)
                let extra = rewrite.queries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && $0 != state.question }
                state.queries.append(contentsOf: extra.prefix(3))
                return "질의 \(state.queries.count)개: " + state.queries.joined(separator: " | ")
            } catch {
                return "재작성 실패, 원 질문만 사용 (\(LanguageModelService.describe(error)))"
            }
        }

        graphEngine.addNode(NodeID.retrieve, title: "하이브리드 검색") { [store] state in
            let limit = state.mode == .deep ? 6 : 4
            var merged: [String: RetrievedChunk] = [:]
            for query in state.queries {
                for result in await store.search(query, limit: limit) {
                    if let existing = merged[result.id], existing.score >= result.score { continue }
                    merged[result.id] = result
                }
            }
            state.retrieved = Array(merged.values.sorted { $0.score > $1.score }.prefix(limit))
            let best = state.retrieved.first.map { String(format: "%.2f", $0.score) } ?? "-"
            return "청크 \(state.retrieved.count)개, 최고 점수 \(best)"
        }

        graphEngine.addNode(NodeID.grade, title: "관련성 채점") { [llm] state in
            guard state.mode == .deep, !state.retrieved.isEmpty else { return "⏭ 채점 생략" }
            let session = llm.makeSession(instructions: "문서 조각이 질문에 답하는 데 도움이 되는지 엄격하게 판단한다.")
            var kept: [RetrievedChunk] = []
            for var item in state.retrieved.prefix(5) {
                let prompt = "질문: \(state.question)\n\n문서 조각: \(item.chunk.text.prefix(500))"
                if let grade = try? await llm.generate(session, prompt: prompt, as: RelevanceGrade.self) {
                    item.graded = grade.relevant
                    if grade.relevant { kept.append(item) }
                } else {
                    kept.append(item)
                }
            }
            if kept.isEmpty, let top = state.retrieved.first {
                // 전부 탈락하면 최고 점수 하나는 남겨 사용자가 근거를 볼 수 있게 한다.
                kept = [top]
            }
            let dropped = state.retrieved.count - kept.count
            state.retrieved = kept
            return "유지 \(kept.count)개, 제외 \(max(0, dropped))개"
        }

        graphEngine.addNode(NodeID.graph, title: "그래프 확장") { [graph, llm, gapThreshold] state in
            state.graphFacts = await graph.facts(relatedTo: state.question, limit: 8)
            let best = state.retrieved.first?.score ?? 0
            state.knowledgeGap = state.retrieved.isEmpty || best < gapThreshold
            var note = "사실 \(state.graphFacts.count)개, 최고 점수 \(String(format: "%.2f", best))"
            // 심층 모드: 점수가 애매해도 모델에게 "이 근거로 답할 수 있는가"를 한 번 더 묻는다.
            if state.mode == .deep, !state.knowledgeGap, !state.retrieved.isEmpty {
                let evidence = state.retrieved.prefix(3).map { String($0.chunk.text.prefix(300)) }.joined(separator: "\n---\n")
                let judge = llm.makeSession(instructions: "근거가 질문에 답하기에 충분한지 엄격하게 판단한다. 주제가 다르면 false다.")
                if let assessment = try? await llm.generate(judge, prompt: "질문: \(state.question)\n\n근거:\n\(evidence)", as: GapAssessment.self) {
                    state.knowledgeGap = !assessment.answerable
                    note += assessment.answerable ? ", 근거 충분" : ", 근거 불충분"
                }
            }
            return note + (state.knowledgeGap ? " → 지식 부족 감지" : "")
        }

        graphEngine.addNode(NodeID.tools, title: "외부 도구(MCP)") { [llm, externalTools, store, onToolCall] state in
            let mcpTools = externalTools()
            let searchTool = KnowledgeSearchTool(store: store, onCall: onToolCall)
            let tools: [any Tool] = mcpTools + [searchTool]
            let names = mcpTools.map(\.name).joined(separator: ", ")
            let session = llm.makeSession(
                instructions: """
                너는 조사 담당이다. 사용 가능한 도구를 호출해 질문에 답하는 데 필요한 사실을 모은다.
                도구 결과를 바탕으로 알게 된 사실만 3~6문장으로 요약하고, 출처(도구 이름)를 함께 적는다. 모르면 모른다고 쓴다.
                """,
                tools: tools
            )
            do {
                let summary = try await llm.respond(session, prompt: "질문: \(state.question)", temperature: 0.2)
                state.toolResults.append(summary)
                return "도구 [\(names)] 조사 완료"
            } catch {
                return "도구 조사 실패: \(LanguageModelService.describe(error))"
            }
        }

        graphEngine.addNode(NodeID.learn, title: "지식 학습") { [store, graph, gapThreshold] state in
            guard let newFacts = state.toolResults.last, newFacts.count > 20, !newFacts.contains("모른다"), !newFacts.contains("모릅니다") else { return "⏭ 학습할 내용 없음" }
            let title = "도구 조사: \(state.question.prefix(30))"
            let document = await store.addDocument(title: title, text: newFacts, source: .tool, origin: "MCP 도구 결과")
            for chunk in await store.chunks(for: document.id) {
                await graph.extractCheap(from: chunk)
            }
            await graph.persist()
            // 방금 배운 내용을 근거의 맨 앞에 두고, 지식 부족을 일으킨 무관한 청크(문턱 미만)는 뺀다.
            let fresh = await store.search(state.question, limit: 3).filter { $0.chunk.documentID == document.id }
            let stillRelevant = state.retrieved.filter { $0.score >= gapThreshold }
            let removed = state.retrieved.count - stillRelevant.count
            state.retrieved = fresh + stillRelevant
            // 도구 요약은 학습 문서로 인용되므로 중복 블록은 비운다.
            state.toolResults.removeAll()
            return "문서 '\(title)' 저장, 청크 \(document.chunkCount)개 · 무관 청크 \(removed)개 제외"
        }

        graphEngine.addNode(NodeID.generate, title: "초안 생성") { [llm] state in
            var effectivePolicy = policy
            effectivePolicy.answerLanguage = state.language
            let context = Harness.assembleContext(policy: effectivePolicy, chunks: state.retrieved, graphFacts: state.graphFacts, toolResults: state.toolResults)
            state.context = context
            var prompt = Harness.answerPrompt(question: state.question, context: context, imageNotes: state.imageNotes, policy: effectivePolicy)
            let recent = state.history.suffix(4).filter { $0.role != .system }
            if !recent.isEmpty {
                let historyText = recent.map { "\($0.role == .user ? "사용자" : "Lantern"): \($0.text.prefix(200))" }.joined(separator: "\n")
                prompt = "이전 대화(참고용):\n\(historyText)\n\n" + prompt
            }
            // Vision의 OCRTool은 macOS에서만 세션 도구로 붙인다. 다른 플랫폼은 vision 노드가 미리 뽑은 OCR 텍스트(imageNotes)를 쓴다.
            var tools: [any Tool] = []
            #if os(macOS)
            if !state.images.isEmpty { tools.append(OCRTool()) }
            #endif
            let session = llm.makeSession(instructions: effectivePolicy.instructionsText, tools: tools)
            if state.images.isEmpty {
                state.draft = try await llm.stream(session, prompt: prompt, onPartial: onPartial)
            } else {
                state.draft = try await llm.respond(session, prompt: prompt, images: state.images)
                onPartial(state.draft)
            }
            return "초안 \(state.draft.count)자, 근거 \(context.usedCharacters)자"
        }

        graphEngine.addNode(NodeID.verify, title: "하네스 검증") { [llm] state in
            guard let context = state.context else { return "⏭ 컨텍스트 없음" }
            var effectivePolicy = policy
            effectivePolicy.answerLanguage = state.language
            var notes: [String] = []

            // 1) 규칙 기반 검사
            var check = Harness.check(answer: state.draft, context: context, policy: effectivePolicy)
            if !check.passed, state.repairCount < 1 {
                let session = llm.makeSession(instructions: effectivePolicy.instructionsText)
                let repairPrompt = "근거:\n\(context.evidenceBlock)\n\n" + Harness.repairPrompt(answer: state.draft, problems: check.problems, policy: effectivePolicy)
                if let repaired = try? await llm.respond(session, prompt: repairPrompt, temperature: 0.2) {
                    state.draft = repaired
                    state.repairCount += 1
                    onPartial(repaired)
                    notes.append("규칙 수정 1회(\(check.problems.joined(separator: ", ")))")
                    check = Harness.check(answer: state.draft, context: context, policy: effectivePolicy)
                }
            }
            notes.append(check.passed ? "규칙 통과" : "규칙 경고: \(check.problems.joined(separator: ", "))")

            // 2) 심층 모드: 모델 판정
            if state.mode == .deep {
                let judge = llm.makeSession(instructions: "너는 사실 검증관이다. 초안이 근거에만 기반했는지 판단한다.")
                let prompt = "근거:\n\(context.evidenceBlock)\n\n초안:\n\(state.draft)"
                if let verdict = try? await llm.generate(judge, prompt: prompt, as: GroundingVerdict.self) {
                    state.verdict = verdict
                    if !verdict.grounded, state.repairCount < 2 {
                        let session = llm.makeSession(instructions: effectivePolicy.instructionsText)
                        let repairPrompt = "근거:\n\(context.evidenceBlock)\n\n" + Harness.repairPrompt(answer: state.draft, problems: [verdict.issue.isEmpty ? "근거 없는 내용" : verdict.issue], policy: effectivePolicy)
                        if let repaired = try? await llm.respond(session, prompt: repairPrompt, temperature: 0.2) {
                            state.draft = repaired
                            state.repairCount += 1
                            onPartial(repaired)
                            notes.append("근거 검증 수정 1회")
                        }
                    } else {
                        notes.append(verdict.grounded ? "근거 검증 통과" : "근거 경고: \(verdict.issue)")
                    }
                }
            }
            return notes.joined(separator: " · ")
        }

        graphEngine.addNode(NodeID.finalize, title: "마무리") { state in
            state.answer = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            let referenced = Set(Self.citedIndexes(in: state.answer))
            let all = state.context?.citations ?? []
            state.citations = referenced.isEmpty ? [] : all.filter { referenced.contains($0.index) }
            return "출처 \(state.citations.count)개 첨부"
        }

        // 간선: 선형 흐름 + 지식 부족 시 도구 분기
        graphEngine
            .addEdge(from: NodeID.intake, to: NodeID.vision)
            .addEdge(from: NodeID.vision, to: NodeID.rewrite)
            .addEdge(from: NodeID.rewrite, to: NodeID.retrieve)
            .addEdge(from: NodeID.retrieve, to: NodeID.grade)
            .addEdge(from: NodeID.grade, to: NodeID.graph)
            .addConditionalEdge(
                from: NodeID.graph,
                candidates: [("지식 부족 + 심층", NodeID.tools), ("충분", NodeID.generate)]
            ) { [externalTools] state in
                let hasExternal = !externalTools().isEmpty
                return (state.mode == .deep && state.knowledgeGap && hasExternal) ? NodeID.tools : NodeID.generate
            }
            .addEdge(from: NodeID.tools, to: NodeID.learn)
            .addEdge(from: NodeID.learn, to: NodeID.generate)
            .addEdge(from: NodeID.generate, to: NodeID.verify)
            .addEdge(from: NodeID.verify, to: NodeID.finalize)
            .addEdge(from: NodeID.finalize, to: StateGraph<AgentState>.endID)

        return graphEngine
    }

    /// 그래프 실행 진입점
    func answer(
        question: String,
        images: [CGImage],
        mode: AgentMode,
        history: [ChatMessage],
        onEvent: @escaping @MainActor (TraceEvent) -> Void,
        onPartial: @escaping @MainActor (String) -> Void
    ) async throws -> AgentState {
        let graphEngine = buildGraph(onPartial: onPartial)
        let initial = AgentState(question: question, images: images, mode: mode, history: history)
        return try await graphEngine.run(initial, onEvent: onEvent)
    }

    /// 다이어그램용 간선 목록
    var declaredTransitions: [(from: String, to: String, label: String?)] {
        buildGraph(onPartial: { _ in }).declaredTransitions
    }

    nonisolated static func citedIndexes(in text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d+)\]"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let numberRange = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[numberRange])
        }
    }

    // MARK: 지식 그래프 추출(심층)

    /// 문서 청크에서 LLM으로 트리플을 뽑아 그래프에 넣는다. 느리므로 사용자가 요청할 때만 실행한다.
    func extractTriples(for chunks: [KnowledgeChunk], onProgress: @MainActor (Int, Int) -> Void) async {
        let session = llm.makeSession(instructions: "본문에서 사실 관계를 (주어, 관계, 목적어) 트리플로 뽑는다. 본문에 없는 내용은 만들지 않는다.")
        for (index, chunk) in chunks.enumerated() {
            onProgress(index + 1, chunks.count)
            guard let extracted = try? await llm.generate(session, prompt: "본문:\n\(chunk.text.prefix(700))", as: ExtractedTriples.self) else { continue }
            for triple in extracted.triples where !triple.subject.isEmpty && !triple.object.isEmpty {
                await graph.add(subject: triple.subject, predicate: triple.predicate, object: triple.object, kind: "개념", sourceChunkID: chunk.id)
            }
        }
        await graph.persist()
    }
}
