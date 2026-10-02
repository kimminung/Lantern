import Foundation

/// 온디바이스 벡터 저장소. 코사인 유사도 + 키워드 점수를 섞은 하이브리드 검색을 제공한다.
/// 모든 데이터는 Application Support/Lantern/chunks.json 에 평문 JSON으로 저장된다.
actor VectorStore {
    private(set) var chunks: [KnowledgeChunk] = []
    private(set) var documents: [KnowledgeDocument] = []
    private var embedder: any EmbeddingEngine
    private let persistence = Persistence.shared

    /// 하이브리드 점수 가중치
    private let vectorWeight = 0.65
    private let keywordWeight = 0.35

    init(embedder: any EmbeddingEngine) {
        self.embedder = embedder
        self.chunks = persistence.load([KnowledgeChunk].self, from: "chunks.json") ?? []
        self.documents = persistence.load([KnowledgeDocument].self, from: "documents.json") ?? []
    }

    var embedderName: String { embedder.name }
    var chunkCount: Int { chunks.count }

    /// 임베딩 엔진이 바뀌면(예: 폴백 → Apple) 기존 벡터를 전부 다시 계산한다.
    func replaceEmbedder(_ newEmbedder: any EmbeddingEngine) async {
        embedder = newEmbedder
        var updated: [KnowledgeChunk] = []
        updated.reserveCapacity(chunks.count)
        for var chunk in chunks {
            if let vector = try? await newEmbedder.embed(chunk.text) {
                chunk.vector = vector
            }
            updated.append(chunk)
        }
        chunks = updated
        persist()
    }

    // MARK: 추가/삭제

    /// 문서를 청크로 쪼개 임베딩하고 저장한다. 반환값은 저장된 문서 메타데이터.
    @discardableResult
    func addDocument(title: String, text: String, source: KnowledgeDocument.Source, origin: String) async -> KnowledgeDocument {
        let pieces = Chunker.split(text)
        let documentID = UUID()
        var newChunks: [KnowledgeChunk] = []
        for (ordinal, piece) in pieces.enumerated() {
            let vector = (try? await embedder.embed(piece)) ?? []
            newChunks.append(
                KnowledgeChunk(
                    id: "\(documentID.uuidString.prefix(8))-\(ordinal)",
                    documentID: documentID,
                    documentTitle: title,
                    ordinal: ordinal,
                    text: piece,
                    vector: vector,
                    keywords: Tokenizer.keywords(in: piece)
                )
            )
        }
        let document = KnowledgeDocument(id: documentID, title: title, source: source, origin: origin, chunkCount: newChunks.count)
        chunks.append(contentsOf: newChunks)
        documents.append(document)
        persist()
        return document
    }

    func removeDocument(id: UUID) {
        chunks.removeAll { $0.documentID == id }
        documents.removeAll { $0.id == id }
        persist()
    }

    func removeAll() {
        chunks.removeAll()
        documents.removeAll()
        persist()
    }

    func chunks(for documentID: UUID) -> [KnowledgeChunk] {
        chunks.filter { $0.documentID == documentID }.sorted { $0.ordinal < $1.ordinal }
    }

    func chunk(id: String) -> KnowledgeChunk? {
        chunks.first { $0.id == id }
    }

    // MARK: 검색

    /// 하이브리드 검색. 벡터 점수와 키워드 겹침 점수를 가중 합산한다.
    func search(_ query: String, limit: Int = 5) async -> [RetrievedChunk] {
        guard !chunks.isEmpty else { return [] }
        let queryVector = (try? await embedder.embed(query)) ?? []
        let queryKeywords = Set(Tokenizer.keywords(in: query))
        var scored: [RetrievedChunk] = []
        scored.reserveCapacity(chunks.count)
        for chunk in chunks {
            let vectorScore = max(0, VectorMath.cosine(queryVector, chunk.vector))
            let keywordScore = keywordOverlap(queryKeywords, chunk)
            let combined = vectorWeight * vectorScore + keywordWeight * keywordScore
            scored.append(RetrievedChunk(chunk: chunk, vectorScore: vectorScore, keywordScore: keywordScore, score: combined))
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// 질의 키워드가 청크 키워드/본문에 얼마나 등장하는지(0~1)
    private func keywordOverlap(_ queryKeywords: Set<String>, _ chunk: KnowledgeChunk) -> Double {
        guard !queryKeywords.isEmpty else { return 0 }
        let haystack = chunk.text.lowercased()
        let chunkKeywords = Set(chunk.keywords)
        var hits = 0.0
        for keyword in queryKeywords {
            if chunkKeywords.contains(keyword) {
                hits += 1
            } else if haystack.contains(keyword) {
                hits += 0.7
            }
        }
        return min(1, hits / Double(queryKeywords.count))
    }

    private func persist() {
        persistence.save(chunks, to: "chunks.json")
        persistence.save(documents, to: "documents.json")
    }
}

/// 문단 기준으로 자르고, 너무 길면 문장 단위로 다시 묶는 청커.
nonisolated enum Chunker {
    static let targetLength = 360
    static let overlap = 60

    static func split(_ text: String) -> [String] {
        let paragraphs = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var chunks: [String] = []
        var buffer = ""
        for paragraph in paragraphs {
            if paragraph.count > targetLength {
                flush(&buffer, into: &chunks)
                chunks.append(contentsOf: splitLong(paragraph))
                continue
            }
            if buffer.count + paragraph.count + 1 > targetLength {
                flush(&buffer, into: &chunks)
            }
            buffer += buffer.isEmpty ? paragraph : "\n" + paragraph
        }
        flush(&buffer, into: &chunks)
        return chunks
    }

    private static func flush(_ buffer: inout String, into chunks: inout [String]) {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { chunks.append(trimmed) }
        buffer = ""
    }

    /// 긴 문단은 글자 수 기준으로 자르되 앞 청크 꼬리를 조금 겹친다.
    private static func splitLong(_ paragraph: String) -> [String] {
        var result: [String] = []
        let characters = Array(paragraph)
        var start = 0
        while start < characters.count {
            let end = min(characters.count, start + targetLength)
            result.append(String(characters[start..<end]))
            if end == characters.count { break }
            start = max(end - overlap, start + 1)
        }
        return result
    }
}
