import Foundation

/// LangGraph 방식의 상태 그래프 엔진.
/// 노드는 상태를 읽고 고치는 비동기 함수이고, 간선은 고정 또는 조건부(상태를 보고 다음 노드 결정)다.
/// 실행 중 각 노드의 시작/종료가 TraceEvent로 보고되어 UI가 흐름을 그린다.
struct GraphNodeSpec<State>: Identifiable {
    let id: String
    let title: String
    /// 노드 본문. 상태를 수정하고 한 줄 요약을 돌려준다.
    let body: (inout State) async throws -> String
}

enum GraphEdge<State> {
    case to(String)
    case conditional((State) -> String)
    case end
}

@MainActor
final class StateGraph<State> {
    static var endID: String { "END" }

    private(set) var nodes: [String: GraphNodeSpec<State>] = [:]
    private(set) var edges: [String: GraphEdge<State>] = [:]
    private(set) var order: [String] = []
    private(set) var entryID: String?

    /// 다이어그램용: 가능한 모든 간선 (조건부 간선은 후보 목록을 선언적으로 받는다)
    private(set) var declaredTransitions: [(from: String, to: String, label: String?)] = []

    @discardableResult
    func addNode(_ id: String, title: String, body: @escaping (inout State) async throws -> String) -> Self {
        nodes[id] = GraphNodeSpec(id: id, title: title, body: body)
        order.append(id)
        if entryID == nil { entryID = id }
        return self
    }

    @discardableResult
    func addEdge(from: String, to: String) -> Self {
        edges[from] = .to(to)
        declaredTransitions.append((from, to, nil))
        return self
    }

    @discardableResult
    func addConditionalEdge(from: String, candidates: [(label: String, to: String)], decide: @escaping (State) -> String) -> Self {
        edges[from] = .conditional(decide)
        for candidate in candidates {
            declaredTransitions.append((from, candidate.to, candidate.label))
        }
        return self
    }

    @discardableResult
    func setEntry(_ id: String) -> Self {
        entryID = id
        return self
    }

    /// 그래프 실행. 노드마다 onEvent로 추적 이벤트를 보낸다. 무한 루프 방지를 위해 최대 스텝을 둔다.
    func run(_ initial: State, maxSteps: Int = 24, onEvent: @MainActor (TraceEvent) -> Void) async throws -> State {
        var state = initial
        guard var current = entryID else { return state }
        var steps = 0
        while current != Self.endID, steps < maxSteps {
            steps += 1
            guard let node = nodes[current] else { break }
            var event = TraceEvent(nodeID: node.id, title: node.title)
            onEvent(event)
            let started = Date()
            do {
                let summary = try await node.body(&state)
                event.status = summary.hasPrefix("⏭") ? .skipped : .succeeded
                event.summary = summary
            } catch {
                event.status = .failed
                event.summary = error.localizedDescription
                event.durationMS = Int(Date().timeIntervalSince(started) * 1000)
                onEvent(event)
                throw error
            }
            event.durationMS = Int(Date().timeIntervalSince(started) * 1000)
            onEvent(event)

            switch edges[current] {
            case .to(let next): current = next
            case .conditional(let decide): current = decide(state)
            case .end, .none: current = Self.endID
            }
        }
        return state
    }
}
