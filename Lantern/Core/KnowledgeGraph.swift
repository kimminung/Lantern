import Foundation
import NaturalLanguage

/// 지식 그래프 저장소. 주어-술어-목적어 트리플을 모아 질의 주변 사실을 꺼내 준다.
/// LLM이 뽑아낸 트리플(정확)과 NLTagger 고유명사 동시 출현(저렴) 두 경로로 채워진다.
actor KnowledgeGraph {
    private(set) var entities: [String: GraphEntity] = [:]
    private(set) var relations: [String: GraphRelation] = [:]
    private let persistence = Persistence.shared

    init() {
        if let stored = persistence.load([GraphEntity].self, from: "graph-entities.json") {
            entities = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        }
        if let stored = persistence.load([GraphRelation].self, from: "graph-relations.json") {
            relations = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        }
    }

    var entityList: [GraphEntity] { Array(entities.values).sorted { $0.mentions > $1.mentions } }
    var relationList: [GraphRelation] { Array(relations.values) }

    static func entityID(_ name: String) -> String {
        name.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
    }

    /// 트리플 추가. 같은 트리플이 또 오면 가중치만 올린다.
    func add(subject: String, predicate: String, object: String, kind: String = "개념", sourceChunkID: String) {
        let subjectID = Self.entityID(subject)
        let objectID = Self.entityID(object)
        guard !subjectID.isEmpty, !objectID.isEmpty, subjectID != objectID else { return }
        upsertEntity(id: subjectID, name: subject, kind: kind)
        upsertEntity(id: objectID, name: object, kind: kind)
        let relation = GraphRelation(subjectID: subjectID, predicate: predicate, objectID: objectID, sourceChunkID: sourceChunkID, weight: 1)
        if var existing = relations[relation.id] {
            existing.weight += 1
            relations[relation.id] = existing
        } else {
            relations[relation.id] = relation
        }
    }

    private func upsertEntity(id: String, name: String, kind: String) {
        if var existing = entities[id] {
            existing.mentions += 1
            entities[id] = existing
        } else {
            entities[id] = GraphEntity(id: id, name: name, kind: kind, mentions: 1)
        }
    }

    func persist() {
        persistence.save(Array(entities.values), to: "graph-entities.json")
        persistence.save(Array(relations.values), to: "graph-relations.json")
    }

    func removeAll() {
        entities.removeAll()
        relations.removeAll()
        persist()
    }

    func remove(sourceChunkIDs: Set<String>) {
        relations = relations.filter { !sourceChunkIDs.contains($0.value.sourceChunkID) }
        let referenced = Set(relations.values.flatMap { [$0.subjectID, $0.objectID] })
        entities = entities.filter { referenced.contains($0.key) }
        persist()
    }

    // MARK: 질의

    /// 질문에 등장하는 엔티티를 찾고 1홉 이웃 사실을 문장으로 돌려준다.
    func facts(relatedTo query: String, limit: Int = 8) -> [String] {
        let lowered = query.lowercased()
        let queryKeywords = Set(Tokenizer.keywords(in: query))
        let matched = entities.values.filter { entity in
            let name = entity.name.lowercased()
            return lowered.contains(name) || queryKeywords.contains(name) || queryKeywords.contains(where: { name.contains($0) && $0.count >= 2 })
        }
        guard !matched.isEmpty else { return [] }
        let matchedIDs = Set(matched.map(\.id))
        let related = relations.values
            .filter { matchedIDs.contains($0.subjectID) || matchedIDs.contains($0.objectID) }
            .sorted { $0.weight > $1.weight }
            .prefix(limit)
        return related.compactMap { relation in
            guard let subject = entities[relation.subjectID], let object = entities[relation.objectID] else { return nil }
            return "\(subject.name) —\(relation.predicate)→ \(object.name)"
        }
    }

    /// 특정 엔티티의 이웃(그래프 뷰에서 선택 시 사용)
    func neighbors(of entityID: String) -> [GraphRelation] {
        relations.values.filter { $0.subjectID == entityID || $0.objectID == entityID }
    }

    // MARK: 저렴한 추출(NLTagger)

    /// LLM 없이 고유명사 동시 출현으로 "함께 언급" 관계를 만든다. 심층 모드가 아닐 때의 기본 경로.
    func extractCheap(from chunk: KnowledgeChunk) {
        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])
        tagger.string = chunk.text
        var names: [String] = []
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        tagger.enumerateTags(in: chunk.text.startIndex..<chunk.text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
                names.append(String(chunk.text[range]))
            }
            return true
        }
        // 고유명사가 적으면 자주 등장하는 명사 키워드로 보강한다.
        if names.count < 2 {
            let frequent = Dictionary(grouping: chunk.keywords, by: { $0 })
                .mapValues(\.count)
                .filter { $0.key.count >= 2 }
                .sorted { $0.value > $1.value }
                .prefix(3)
                .map(\.key)
            names.append(contentsOf: frequent)
        }
        let unique = Array(Set(names)).prefix(5)
        guard unique.count >= 2 else { return }
        let anchor = unique[unique.startIndex]
        for other in unique.dropFirst() {
            add(subject: anchor, predicate: "함께 언급", object: other, kind: "용어", sourceChunkID: chunk.id)
        }
    }
}
