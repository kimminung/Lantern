import SwiftUI

/// 그래프 화면: 지식 그래프(엔티티·관계)와 에이전트 그래프(노드·간선) 두 탭
struct GraphView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("그래프", selection: $tab) {
                Text("지식 그래프").tag(0)
                Text("에이전트 그래프").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()
            if tab == 0 {
                KnowledgeGraphCanvas()
            } else {
                AgentGraphDiagram(lastTrace: model.currentTrace)
            }
        }
        .navigationTitle("그래프")
    }
}

/// 지식 그래프를 원형 배치로 그린다. 엔티티를 누르면 이웃 관계를 보여준다.
struct KnowledgeGraphCanvas: View {
    @Environment(AppModel.self) private var model
    @State private var selectedEntityID: String?
    @State private var neighbors: [GraphRelation] = []
    private let maxNodes = 40

    var body: some View {
        let entities = Array(model.graphEntities.prefix(maxNodes))
        let visibleIDs = Set(entities.map(\.id))
        let relations = model.graphRelations.filter { visibleIDs.contains($0.subjectID) && visibleIDs.contains($0.objectID) }

        HStack(spacing: 0) {
            GeometryReader { geometry in
                let positions = layout(entities: entities, in: geometry.size)
                ZStack {
                    Canvas { context, _ in
                        for relation in relations {
                            guard let from = positions[relation.subjectID], let to = positions[relation.objectID] else { continue }
                            var path = Path()
                            path.move(to: from)
                            path.addLine(to: to)
                            let highlighted = relation.subjectID == selectedEntityID || relation.objectID == selectedEntityID
                            context.stroke(path, with: .color(highlighted ? .accentColor : .gray.opacity(0.35)), lineWidth: highlighted ? 2 : 1)
                            let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
                            if highlighted {
                                context.draw(Text(relation.predicate).font(.caption2).foregroundStyle(.secondary), at: mid)
                            }
                        }
                    }
                    ForEach(entities) { entity in
                        if let point = positions[entity.id] {
                            Button {
                                selectedEntityID = entity.id
                                Task { neighbors = await model.neighbors(of: entity.id) }
                            } label: {
                                Text(entity.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(entity.id == selectedEntityID ? Color.accentColor.opacity(0.3) : Color.teal.opacity(0.15), in: Capsule())
                                    .overlay(Capsule().stroke(entity.id == selectedEntityID ? Color.accentColor : .clear))
                            }
                            .buttonStyle(.plain)
                            .position(point)
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                Text("\(model.graphEntities.count)개 개념 · \(model.graphRelations.count)개 관계 (상위 \(min(maxNodes, model.graphEntities.count))개 표시)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            Divider()
            neighborPanel
                .frame(width: 280)
        }
    }

    private var neighborPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selectedEntityID, let entity = model.graphEntities.first(where: { $0.id == selectedEntityID }) {
                Text(entity.name).font(.headline)
                Text("\(entity.kind) · 언급 \(entity.mentions)회").font(.caption).foregroundStyle(.secondary)
                Divider()
                if neighbors.isEmpty {
                    Text("연결된 관계가 없습니다.").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(neighbors) { relation in
                            let subject = model.graphEntities.first { $0.id == relation.subjectID }?.name ?? relation.subjectID
                            let object = model.graphEntities.first { $0.id == relation.objectID }?.name ?? relation.objectID
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(subject) → \(relation.predicate) → \(object)").font(.caption)
                                Text("출처 청크 \(relation.sourceChunkID) · 가중치 \(relation.weight)").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } else {
                Text("개념을 선택하세요").font(.headline)
                Text("지식 그래프는 문서를 가져올 때 자동(NLTagger)으로 만들어지고, 지식 저장소에서 'LLM 트리플 추출'을 실행하면 더 정확해집니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    /// 언급 수가 많은 엔티티일수록 안쪽 원에 배치한다.
    private func layout(entities: [GraphEntity], in size: CGSize) -> [String: CGPoint] {
        guard !entities.isEmpty else { return [:] }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outerRadius = max(40, min(size.width, size.height) / 2 - 50)
        var positions: [String: CGPoint] = [:]
        let innerCount = min(8, entities.count)
        for (index, entity) in entities.enumerated() {
            let isInner = index < innerCount
            let ringCount = isInner ? innerCount : max(1, entities.count - innerCount)
            let ringIndex = isInner ? index : index - innerCount
            let radius = isInner ? outerRadius * 0.45 : outerRadius
            let angle = (Double(ringIndex) / Double(ringCount)) * 2 * .pi - .pi / 2
            positions[entity.id] = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
        return positions
    }
}

/// 에이전트 상태 그래프 다이어그램. 노드를 세로로 배치하고 조건부 간선을 표시한다.
struct AgentGraphDiagram: View {
    @Environment(AppModel.self) private var model
    let lastTrace: [TraceEvent]

    var body: some View {
        let statusByNode = Dictionary(lastTrace.map { ($0.nodeID, $0.status) }, uniquingKeysWith: { _, new in new })
        let transitions = model.agent?.declaredTransitions ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("StateGraph: 입력 → 검색 → (지식 부족 시 MCP 도구·학습) → 생성 → 검증 → 마무리")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(LanternAgent.nodeTitles, id: \.id) { node in
                    let outgoing = transitions.filter { $0.from == node.id }
                    HStack(alignment: .top, spacing: 12) {
                        Text(node.title)
                            .font(.callout.bold())
                            .frame(width: 140, alignment: .leading)
                            .padding(10)
                            .background(background(for: statusByNode[node.id]), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("id: \(node.id)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            ForEach(Array(outgoing.enumerated()), id: \.offset) { _, edge in
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.turn.down.right").font(.caption2)
                                    Text(titleFor(edge.to)).font(.caption)
                                    if let label = edge.label {
                                        Text("[\(label)]").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if let summary = lastTrace.last(where: { $0.nodeID == node.id })?.summary, !summary.isEmpty {
                                Text("마지막 실행: \(summary)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
            }
            .padding()
        }
    }

    private func titleFor(_ id: String) -> String {
        if id == StateGraph<AgentState>.endID { return "END" }
        return LanternAgent.nodeTitles.first { $0.id == id }?.title ?? id
    }

    private func background(for status: TraceEvent.Status?) -> Color {
        switch status {
        case .running: return .blue.opacity(0.25)
        case .succeeded: return .green.opacity(0.2)
        case .skipped: return .gray.opacity(0.12)
        case .failed: return .red.opacity(0.25)
        case .none: return .teal.opacity(0.1)
        }
    }
}
