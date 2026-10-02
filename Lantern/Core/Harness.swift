import Foundation

/// 하네스: 모델 호출을 감싸 답변의 형식·근거·언어를 일관되게 유지하는 규칙 묶음.
/// 1) Instructions(페르소나+규칙) 고정  2) 컨텍스트 조립과 토큰 예산  3) 출력 검사와 자동 수정.
nonisolated struct HarnessPolicy: Codable, Hashable, Sendable {
    var persona: String
    var rules: [String]
    var requireCitations: Bool
    var answerLanguage: String
    var maxContextCharacters: Int
    var maxAnswerSentences: Int

    static let `default` = HarnessPolicy(
        persona: "당신은 'Lantern(랜턴)'입니다. 사용자의 기기 안에서만 동작하는 차분하고 정확한 지식 비서입니다.",
        rules: [
            "제공된 근거(출처 번호가 붙은 문서 조각, 그래프 사실, 도구 결과)만 사용해 답한다.",
            "근거에 없는 내용은 추측하지 말고 '제공된 자료에는 없습니다'라고 말한다.",
            "근거를 쓸 때 문장 끝에 [1], [2]처럼 출처 번호를 붙인다.",
            "질문과 직접 관련 없는 근거는 답변에 끌어오지 않는다.",
            "먼저 결론을 한 문장으로 말하고, 필요하면 짧은 목록으로 보충한다.",
            "사용자가 쓴 언어로 답한다. 기본은 한국어다.",
            "답변은 간결하게, 불필요한 서론과 사과는 생략한다.",
        ],
        requireCitations: true,
        answerLanguage: "한국어",
        maxContextCharacters: 2_400,
        maxAnswerSentences: 8
    )

    /// Foundation Models 세션에 넣을 Instructions 문자열
    var instructionsText: String {
        var lines = [persona, "", "규칙:"]
        for (index, rule) in rules.enumerated() {
            lines.append("\(index + 1). \(rule)")
        }
        return lines.joined(separator: "\n")
    }
}

/// 하네스가 조립한 컨텍스트 묶음
nonisolated struct AssembledContext: Sendable {
    var evidenceBlock: String
    var citations: [Citation]
    var usedCharacters: Int
}

/// 출력 검사 결과
nonisolated struct OutputCheck: Sendable {
    var passed: Bool
    var problems: [String]
}

nonisolated enum Harness {
    /// 검색 결과·그래프 사실·도구 결과를 토큰 예산 안에서 근거 블록으로 만든다.
    static func assembleContext(
        policy: HarnessPolicy,
        chunks: [RetrievedChunk],
        graphFacts: [String],
        toolResults: [String]
    ) -> AssembledContext {
        var block = ""
        var citations: [Citation] = []
        var budget = policy.maxContextCharacters

        for (offset, retrieved) in chunks.enumerated() {
            let index = offset + 1
            let snippet = String(retrieved.chunk.text.prefix(600))
            let entry = "[\(index)] (\(retrieved.chunk.documentTitle)) \(snippet)\n"
            guard entry.count <= budget else { break }
            block += entry
            budget -= entry.count
            citations.append(
                Citation(
                    index: index,
                    chunkID: retrieved.chunk.id,
                    documentTitle: retrieved.chunk.documentTitle,
                    snippet: String(retrieved.chunk.text.prefix(160)),
                    score: retrieved.score
                )
            )
        }

        if !graphFacts.isEmpty {
            let factsText = "지식 그래프 사실:\n" + graphFacts.prefix(6).map { "- \($0)" }.joined(separator: "\n") + "\n"
            if factsText.count <= budget {
                block += factsText
                budget -= factsText.count
            }
        }

        // 도구 결과도 출처 번호를 받는다. 그래야 답변이 문서 조각 번호를 빌려 쓰지 않고 정직하게 인용한다.
        for (offset, result) in toolResults.enumerated() {
            let index = citations.count + 1
            let snippet = String(result.prefix(500))
            let entry = "[\(index)] (MCP 도구 결과 \(offset + 1)) \(snippet)\n"
            guard entry.count <= budget else { break }
            block += entry
            budget -= entry.count
            citations.append(
                Citation(index: index, chunkID: "tool-\(offset + 1)", documentTitle: "MCP 도구 결과", snippet: String(result.prefix(160)), score: 1.0)
            )
        }

        return AssembledContext(
            evidenceBlock: block.isEmpty ? "(제공된 근거 없음)" : block,
            citations: citations,
            usedCharacters: policy.maxContextCharacters - budget
        )
    }

    /// 최종 답변 생성용 프롬프트
    static func answerPrompt(question: String, context: AssembledContext, imageNotes: [String], policy: HarnessPolicy) -> String {
        var parts: [String] = []
        parts.append("근거:\n\(context.evidenceBlock)")
        if !imageNotes.isEmpty {
            parts.append("첨부 이미지 분석:\n" + imageNotes.map { "- \($0)" }.joined(separator: "\n"))
        }
        parts.append("질문: \(question)")
        parts.append("위 근거만 사용해 \(policy.answerLanguage)로 \(policy.maxAnswerSentences)문장 이내로 답하세요. 근거를 인용한 문장 끝에 [번호]를 붙이세요.")
        return parts.joined(separator: "\n\n")
    }

    /// 출력 검사: 인용 누락, 금지 표현, 지나친 길이를 확인한다.
    static func check(answer: String, context: AssembledContext, policy: HarnessPolicy) -> OutputCheck {
        var problems: [String] = []
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            problems.append("빈 답변")
        }
        if policy.requireCitations, !context.citations.isEmpty {
            let hasCitation = trimmed.range(of: #"\[\d+\]"#, options: .regularExpression) != nil
            let saysUnknown = trimmed.contains("없습니다") || trimmed.contains("모릅니다") || trimmed.contains("알 수 없")
            if !hasCitation && !saysUnknown {
                problems.append("출처 번호 누락")
            }
        }
        // 존재하지 않는 출처 번호 인용
        let pattern = #"\[(\d+)\]"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            let numbers = regex.matches(in: trimmed, range: range).compactMap { match -> Int? in
                guard let numberRange = Range(match.range(at: 1), in: trimmed) else { return nil }
                return Int(trimmed[numberRange])
            }
            let valid = Set(context.citations.map(\.index))
            if numbers.contains(where: { !valid.contains($0) }) {
                problems.append("존재하지 않는 출처 번호 인용")
            }
        }
        let sentenceCount = trimmed.components(separatedBy: CharacterSet(charactersIn: ".!?。\n")).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if sentenceCount > policy.maxAnswerSentences * 2 {
            problems.append("답변이 지나치게 깁니다")
        }
        return OutputCheck(passed: problems.isEmpty, problems: problems)
    }

    /// 검사 실패 시 모델에 보낼 수정 요청
    static func repairPrompt(answer: String, problems: [String], policy: HarnessPolicy) -> String {
        """
        아래 답변에 문제가 있습니다: \(problems.joined(separator: ", ")).
        같은 근거만 사용해 문제를 고친 답변을 \(policy.answerLanguage)로 다시 쓰세요. 설명 없이 수정된 답변만 출력하세요.

        답변:
        \(answer)
        """
    }

    /// 사용자 메시지에서 언어를 거칠게 감지한다(한글 포함 여부).
    static func detectLanguage(_ text: String) -> String {
        let hasHangul = text.unicodeScalars.contains { 0xAC00...0xD7A3 ~= $0.value }
        return hasHangul ? "한국어" : "영어"
    }
}
