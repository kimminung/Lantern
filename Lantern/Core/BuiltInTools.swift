import Foundation
import FoundationModels

/// 모델이 직접 지식 저장소를 검색할 수 있게 하는 도구. 그래프 노드가 미리 검색을 하지만,
/// 모델이 후속 질문을 스스로 조회해야 할 때(심층 모드) 사용한다.
nonisolated struct KnowledgeSearchTool: Tool {
    let name = "search_knowledge"
    let description = "로컬 지식 저장소에서 질문과 관련된 문서 조각을 찾는다."

    let store: VectorStore
    let onCall: (@Sendable (String, String) -> Void)?

    @Generable
    struct Arguments {
        @Guide(description: "검색할 짧은 질의")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        let results = await store.search(arguments.query, limit: 3)
        let text = results.isEmpty
            ? "관련 문서를 찾지 못했습니다."
            : results.map { "(\($0.chunk.documentTitle)) \($0.chunk.text.prefix(300))" }.joined(separator: "\n---\n")
        onCall?(name, String(text.prefix(300)))
        return text
    }
}

/// 지식 그래프에서 개념 주변 사실을 꺼내는 도구
nonisolated struct KnowledgeGraphTool: Tool {
    let name = "graph_facts"
    let description = "지식 그래프에서 개념과 연결된 사실(주어-관계-목적어)을 찾는다."

    let graph: KnowledgeGraph
    let onCall: (@Sendable (String, String) -> Void)?

    @Generable
    struct Arguments {
        @Guide(description: "조회할 개념이나 이름")
        var concept: String
    }

    func call(arguments: Arguments) async throws -> String {
        let facts = await graph.facts(relatedTo: arguments.concept, limit: 8)
        let text = facts.isEmpty ? "그래프에 관련 사실이 없습니다." : facts.joined(separator: "\n")
        onCall?(name, String(text.prefix(300)))
        return text
    }
}

/// 현재 날짜·시간. 작은 모델은 날짜를 모르므로 자주 필요하다.
nonisolated struct DateTimeTool: Tool {
    let name = "current_datetime"
    let description = "현재 날짜와 시간을 알려준다."

    @Generable
    struct Arguments {
        @Guide(description: "표시 형식: 'date' 또는 'datetime'")
        var format: String
    }

    func call(arguments: Arguments) async throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateStyle = .full
        formatter.timeStyle = arguments.format == "date" ? .none : .short
        return formatter.string(from: .now)
    }
}

/// 사칙연산 계산기. NSExpression으로 안전하게 평가한다.
nonisolated struct CalculatorTool: Tool {
    let name = "calculate"
    let description = "수식을 계산한다. 예: (3 + 4) * 2"

    @Generable
    struct Arguments {
        @Guide(description: "숫자와 + - * / ( ) 만 포함한 수식")
        var expression: String
    }

    func call(arguments: Arguments) async throws -> String {
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/() ")
        let cleaned = arguments.expression.unicodeScalars.filter { allowed.contains($0) }
        let expressionText = String(String.UnicodeScalarView(cleaned))
        guard !expressionText.isEmpty else { return "계산할 수 없는 식입니다." }
        let expression = NSExpression(format: expressionText)
        if let value = expression.expressionValue(with: nil, context: nil) as? NSNumber {
            return "\(expressionText) = \(value)"
        }
        return "계산할 수 없는 식입니다."
    }
}

/// 대화 중 알게 된 사실을 장기 기억(지식 저장소)에 적는 도구. "기억해 줘" 류의 요청에 쓴다.
nonisolated struct RememberTool: Tool {
    let name = "remember"
    let description = "사용자가 기억해 달라고 한 사실을 장기 기억에 저장한다."

    let store: VectorStore
    let onCall: (@Sendable (String, String) -> Void)?

    @Generable
    struct Arguments {
        @Guide(description: "저장할 사실 한 문장")
        var fact: String
    }

    func call(arguments: Arguments) async throws -> String {
        await store.addDocument(title: "기억: \(arguments.fact.prefix(24))", text: arguments.fact, source: .memory, origin: "remember tool")
        onCall?(name, arguments.fact)
        return "기억했습니다: \(arguments.fact)"
    }
}
