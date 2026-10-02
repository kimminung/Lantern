import Foundation
import CoreGraphics

// MARK: - 대화 모델

/// 대화 참여자 역할
nonisolated enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

/// 에이전트 동작 모드. Fast는 단일 패스, Deep은 그래프 전체(재작성·채점·검증·외부 도구)를 돈다.
nonisolated enum AgentMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case fast
    case deep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: return "빠른 답변"
        case .deep: return "심층 검색"
        }
    }

    var systemImage: String {
        switch self {
        case .fast: return "bolt.fill"
        case .deep: return "magnifyingglass.circle.fill"
        }
    }
}

/// 답변에 붙는 출처 표기
nonisolated struct Citation: Codable, Hashable, Sendable, Identifiable {
    var id: String { chunkID }
    let index: Int
    let chunkID: String
    let documentTitle: String
    let snippet: String
    let score: Double
}

/// 이미지 첨부. 원본 PNG 데이터를 보관해 세션 복원과 멀티모달 프롬프트에 재사용한다.
nonisolated struct ImageAttachment: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let pngData: Data
    var caption: String?

    init(id: UUID = UUID(), pngData: Data, caption: String? = nil) {
        self.id = id
        self.pngData = pngData
        self.caption = caption
    }
}

/// 채팅 메시지 한 건
nonisolated struct ChatMessage: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let role: ChatRole
    var text: String
    var images: [ImageAttachment]
    var citations: [Citation]
    var trace: [TraceEvent]
    var mode: AgentMode?
    let createdAt: Date
    var isStreaming: Bool

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        images: [ImageAttachment] = [],
        citations: [Citation] = [],
        trace: [TraceEvent] = [],
        mode: AgentMode? = nil,
        createdAt: Date = .now,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.images = images
        self.citations = citations
        self.trace = trace
        self.mode = mode
        self.createdAt = createdAt
        self.isStreaming = isStreaming
    }
}

/// 대화 세션(스레드)
nonisolated struct Conversation: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String = "새 대화", messages: [ChatMessage] = []) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = .now
        self.updatedAt = .now
    }
}

// MARK: - 그래프 실행 추적

/// 그래프의 노드 하나가 실행된 기록. UI 타임라인과 그래프 하이라이트에 쓴다.
nonisolated struct TraceEvent: Codable, Hashable, Sendable, Identifiable {
    enum Status: String, Codable, Sendable {
        case running
        case succeeded
        case skipped
        case failed
    }

    let id: UUID
    let nodeID: String
    let title: String
    var status: Status
    var summary: String
    let startedAt: Date
    var durationMS: Int

    init(nodeID: String, title: String, status: Status = .running, summary: String = "", startedAt: Date = .now, durationMS: Int = 0) {
        self.id = UUID()
        self.nodeID = nodeID
        self.title = title
        self.status = status
        self.summary = summary
        self.startedAt = startedAt
        self.durationMS = durationMS
    }
}

// MARK: - 지식 모델

/// 원본 문서(파일, 붙여넣기 텍스트, MCP로 가져온 자료 등)
nonisolated struct KnowledgeDocument: Codable, Hashable, Sendable, Identifiable {
    enum Source: String, Codable, Sendable {
        case seed
        case file
        case pasted
        case tool
        case memory
    }

    let id: UUID
    var title: String
    var source: Source
    var origin: String
    var chunkCount: Int
    let addedAt: Date

    init(id: UUID = UUID(), title: String, source: Source, origin: String, chunkCount: Int) {
        self.id = id
        self.title = title
        self.source = source
        self.origin = origin
        self.chunkCount = chunkCount
        self.addedAt = .now
    }
}

/// 임베딩된 텍스트 조각
nonisolated struct KnowledgeChunk: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let documentID: UUID
    let documentTitle: String
    let ordinal: Int
    let text: String
    var vector: [Float]
    var keywords: [String]
}

/// 검색 결과
nonisolated struct RetrievedChunk: Codable, Hashable, Sendable, Identifiable {
    var id: String { chunk.id }
    let chunk: KnowledgeChunk
    let vectorScore: Double
    let keywordScore: Double
    let score: Double
    var graded: Bool?
}

/// 지식 그래프의 노드
nonisolated struct GraphEntity: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var name: String
    var kind: String
    var mentions: Int
}

/// 지식 그래프의 간선(주어-술어-목적어)
nonisolated struct GraphRelation: Codable, Hashable, Sendable, Identifiable {
    var id: String { "\(subjectID)|\(predicate)|\(objectID)" }
    let subjectID: String
    let predicate: String
    let objectID: String
    var sourceChunkID: String
    var weight: Int
}

// MARK: - MCP 모델

/// MCP 서버 접속 설정. stdio는 macOS에서만, HTTP(Streamable)는 모든 플랫폼에서 쓸 수 있다.
nonisolated struct MCPServerConfig: Codable, Hashable, Sendable, Identifiable {
    enum Transport: String, Codable, CaseIterable, Sendable, Identifiable {
        case stdio
        case http

        var id: String { rawValue }
        var title: String {
            switch self {
            case .stdio: return "stdio (로컬 프로세스)"
            case .http: return "Streamable HTTP"
            }
        }
    }

    let id: UUID
    var name: String
    var transport: Transport
    /// stdio: 실행 파일 경로 (예: /usr/local/bin/npx)
    var command: String
    /// stdio: 인자들 (예: -y @modelcontextprotocol/server-filesystem /tmp)
    var arguments: [String]
    /// http: 엔드포인트 URL
    var url: String
    /// http: Authorization 헤더 등 추가 헤더
    var headers: [String: String]
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        transport: Transport,
        command: String = "",
        arguments: [String] = [],
        url: String = "",
        headers: [String: String] = [:],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.url = url
        self.headers = headers
        self.isEnabled = isEnabled
    }
}

/// MCP 서버가 공개한 도구 정의
nonisolated struct MCPToolDescriptor: Codable, Hashable, Sendable, Identifiable {
    var id: String { "\(serverID.uuidString)/\(name)" }
    let serverID: UUID
    let serverName: String
    let name: String
    let description: String
    /// JSON Schema (object) 원문
    let inputSchema: JSONValue
}

/// 서버 연결 상태
nonisolated enum MCPConnectionState: String, Codable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed
}

// MARK: - JSON 범용 값

/// JSON-RPC와 JSON Schema를 다루기 위한 느슨한 JSON 표현
nonisolated indirect enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "지원하지 않는 JSON 값")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// 사람이 읽기 좋은 평문. 도구 결과를 모델에 넘길 때 사용.
    var prettyText: String {
        switch self {
        case .string(let value): return value
        case .number(let value):
            return value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) {
                return text
            }
            return "\(self)"
        }
    }

    /// Foundation JSON 객체(Any)로부터 변환
    init(any: Any) {
        switch any {
        case let value as String: self = .string(value)
        case let value as Bool: self = .bool(value)
        case let value as NSNumber:
            // NSNumber는 Bool과 구분이 필요하다.
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as [Any]: self = .array(value.map(JSONValue.init(any:)))
        case let value as [String: Any]: self = .object(value.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }
}
