import Foundation
import NaturalLanguage

/// 텍스트를 벡터로 바꾸는 엔진 인터페이스.
/// 기본 구현은 Apple NaturalLanguage의 NLContextualEmbedding(온디바이스, 한국어 CJK 지원).
/// 자산이 없거나 실패하면 해싱 기반 폴백으로 내려가 항상 동작한다.
nonisolated protocol EmbeddingEngine: Sendable {
    var name: String { get }
    var dimension: Int { get }
    func embed(_ text: String) async throws -> [Float]
}

/// Apple NLContextualEmbedding 기반 임베딩. 서브워드 벡터를 평균 풀링해 문장 벡터를 만든다.
nonisolated final class AppleContextualEmbedding: EmbeddingEngine, @unchecked Sendable {
    let name: String
    let dimension: Int
    private let model: NLContextualEmbedding
    private let language: NLLanguage
    private let lock = NSLock()

    /// 자산 준비까지 끝난 인스턴스를 돌려준다. 준비 실패 시 nil.
    static func make(language: NLLanguage = .korean) async -> AppleContextualEmbedding? {
        guard let model = NLContextualEmbedding(language: language) else { return nil }
        if !model.hasAvailableAssets {
            let result = try? await model.requestAssets()
            guard result == .available else { return nil }
        }
        do {
            try model.load()
        } catch {
            return nil
        }
        return AppleContextualEmbedding(model: model, language: language)
    }

    private init(model: NLContextualEmbedding, language: NLLanguage) {
        self.model = model
        self.language = language
        self.name = "Apple NLContextualEmbedding (\(model.modelIdentifier))"
        self.dimension = model.dimension
    }

    func embed(_ text: String) async throws -> [Float] {
        let trimmed = String(text.prefix(2_000))
        guard !trimmed.isEmpty else { return [Float](repeating: 0, count: dimension) }
        // NLContextualEmbedding은 동시 접근에 안전하지 않으므로 직렬화한다.
        let (sum, count) = try lock.withLock { () throws -> ([Double], Int) in
            let result = try model.embeddingResult(for: trimmed, language: language)
            var sum = [Double](repeating: 0, count: dimension)
            var count = 0
            result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
                for (index, value) in vector.enumerated() where index < sum.count {
                    sum[index] += value
                }
                count += 1
                return true
            }
            return (sum, count)
        }
        guard count > 0 else { return [Float](repeating: 0, count: dimension) }
        let mean = sum.map { Float($0 / Double(count)) }
        return VectorMath.normalized(mean)
    }
}

/// 네트워크/자산 없이도 동작하는 폴백. 문자 n-gram 해싱(feature hashing)으로 희소 벡터를 만든다.
/// 의미 임베딩만큼 똑똑하진 않지만 키워드 일치에는 충분하다.
nonisolated struct HashingEmbedding: EmbeddingEngine {
    let name = "Hashing n-gram (폴백)"
    let dimension = 512

    func embed(_ text: String) async throws -> [Float] {
        var vector = [Float](repeating: 0, count: dimension)
        let normalized = text.lowercased()
        let characters = Array(normalized.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        guard !characters.isEmpty else { return vector }
        for n in [2, 3] {
            guard characters.count >= n else { continue }
            for start in 0...(characters.count - n) {
                var hasher = Hasher()
                for offset in 0..<n { hasher.combine(characters[start + offset]) }
                let bucket = abs(hasher.finalize()) % dimension
                vector[bucket] += 1
            }
        }
        return VectorMath.normalized(vector)
    }
}

/// 벡터 유틸
nonisolated enum VectorMath {
    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for index in 0..<a.count {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return Double(dot / (sqrt(normA) * sqrt(normB)))
    }
}

/// 간단한 토크나이저. 한국어/영어 혼용 텍스트에서 키워드를 뽑는다(NLTokenizer 단어 단위).
nonisolated enum Tokenizer {
    static let stopwords: Set<String> = [
        "the", "a", "an", "is", "are", "to", "of", "and", "or", "in", "on", "for", "with", "it", "this", "that",
        "그리고", "그러나", "하지만", "또는", "및", "에서", "으로", "에게", "그것", "이것", "저것", "대한", "위해", "있다", "없다", "합니다", "입니다",
    ]

    static func keywords(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = text[range].lowercased()
            if token.count >= 2, !stopwords.contains(token), token.rangeOfCharacter(from: .alphanumerics) != nil, !isKoreanPredicate(token) {
                let stripped = stripKoreanParticles(token)
                if !stopwords.contains(stripped) { result.append(stripped) }
            }
            return true
        }
        return result
    }

    /// 동사·형용사 활용형(…합니다, …하는, …되며)은 키워드/엔티티로 쓰지 않는다.
    private static let predicateEndings = ["합니다", "입니다", "습니다", "됩니다", "집니다", "합니다.", "하는", "되는", "있는", "없는", "하고", "되고", "하며", "되며", "으며", "해서", "되어", "하면", "되면", "한다", "된다", "이다", "였다", "했다"]

    private static func isKoreanPredicate(_ token: String) -> Bool {
        guard token.unicodeScalars.contains(where: { 0xAC00...0xD7A3 ~= $0.value }) else { return false }
        return predicateEndings.contains { token.hasSuffix($0) && token.count > $0.count }
    }

    /// 아주 거친 한국어 조사 제거. ("랜턴은" → "랜턴", "그래프를" → "그래프")
    private static func stripKoreanParticles(_ token: String) -> String {
        let particles = ["은", "는", "이", "가", "을", "를", "의", "에", "와", "과", "도", "로", "으로", "에서", "에게", "에서는", "에서도", "까지", "부터", "처럼", "보다", "이며", "이고", "이라", "이란"]
        guard token.unicodeScalars.contains(where: { 0xAC00...0xD7A3 ~= $0.value }), token.count > 2 else { return token }
        for particle in particles.sorted(by: { $0.count > $1.count }) where token.hasSuffix(particle) {
            let stripped = String(token.dropLast(particle.count))
            if stripped.count >= 2 { return stripped }
        }
        return token
    }
}
