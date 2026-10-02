import Foundation
import FoundationModels
import CoreGraphics

/// 언어 모델 가용 상태를 UI용으로 요약한 값
enum ModelReadiness: Equatable, Sendable {
    case ready
    case notReady(reason: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .ready: return "온디바이스 모델 준비됨"
        case .notReady(let reason): return reason
        }
    }
}

/// 생성에 쓸 모델 종류. 기본은 온디바이스, 심층 모드에서 사용자가 켜면 Private Cloud Compute.
enum ModelBackend: String, Codable, CaseIterable, Sendable, Identifiable {
    case onDevice
    case privateCloudCompute

    var id: String { rawValue }
    var title: String {
        switch self {
        case .onDevice: return "온디바이스 (Apple Intelligence)"
        case .privateCloudCompute: return "Private Cloud Compute"
        }
    }
}

/// Foundation Models 세션을 감싸는 얇은 서비스. 하네스가 만든 Instructions와 도구 목록으로 세션을 만들고,
/// 짧은 생성·구조화 생성·멀티모달 프롬프트를 한 곳에서 처리한다.
@MainActor
final class LanguageModelService {
    private(set) var readiness: ModelReadiness = .notReady(reason: "확인 중")
    private(set) var pccReadiness: ModelReadiness = .notReady(reason: "미확인 (백엔드를 PCC로 바꾸면 확인)")
    var backend: ModelBackend = .onDevice {
        didSet { if backend == .privateCloudCompute { probePrivateCloudCompute() } }
    }

    func refreshAvailability() {
        switch SystemLanguageModel.default.availability {
        case .available:
            readiness = .ready
        case .unavailable(let reason):
            readiness = .notReady(reason: Self.describe(reason))
        }
    }

    /// Private Cloud Compute는 `com.apple.developer.private-cloud-compute` 엔타이틀먼트가 있어야 쓸 수 있다.
    /// 엔타이틀먼트 없이 모델을 만들면 시스템 로그에 fault가 남으므로 사용자가 선택했을 때만 확인한다.
    func probePrivateCloudCompute() {
        let pcc = PrivateCloudComputeLanguageModel()
        switch pcc.availability {
        case .available:
            pccReadiness = .ready
        case .unavailable:
            pccReadiness = .notReady(reason: "사용 불가 — PCC 엔타이틀먼트와 Apple Intelligence가 필요합니다")
        }
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "이 기기는 Apple Intelligence를 지원하지 않습니다"
        case .appleIntelligenceNotEnabled:
            return "설정에서 Apple Intelligence를 켜 주세요"
        case .modelNotReady:
            return "모델을 내려받는 중입니다. 잠시 후 다시 시도하세요"
        @unknown default:
            return "온디바이스 모델을 사용할 수 없습니다"
        }
    }

    /// 새 세션. 도구와 지시문을 넘긴다.
    func makeSession(instructions: String, tools: [any Tool] = []) -> LanguageModelSession {
        switch backend {
        case .onDevice:
            return LanguageModelSession(model: .default, tools: tools, instructions: instructions)
        case .privateCloudCompute:
            if pccReadiness.isReady {
                return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, instructions: instructions)
            }
            return LanguageModelSession(model: .default, tools: tools, instructions: instructions)
        }
    }

    /// 텍스트 프롬프트 → 텍스트 응답
    func respond(_ session: LanguageModelSession, prompt: String, temperature: Double = 0.3) async throws -> String {
        let options = GenerationOptions(temperature: temperature)
        let response = try await session.respond(to: prompt, options: options)
        return response.content
    }

    /// 텍스트 + 이미지 프롬프트. Attachment로 이미지를 모델에 직접 넘긴다(OS 27 멀티모달).
    func respond(_ session: LanguageModelSession, prompt text: String, images: [CGImage], temperature: Double = 0.3) async throws -> String {
        let options = GenerationOptions(temperature: temperature)
        let response = try await session.respond(options: options) {
            text
            for (index, image) in images.enumerated() {
                Attachment(image).label("image-\(index + 1)")
            }
        }
        return response.content
    }

    /// 스트리밍 텍스트 응답. 부분 문자열을 콜백으로 전달한다.
    func stream(_ session: LanguageModelSession, prompt: String, temperature: Double = 0.3, onPartial: @MainActor (String) -> Void) async throws -> String {
        let options = GenerationOptions(temperature: temperature)
        let stream = session.streamResponse(to: prompt, options: options)
        var latest = ""
        for try await snapshot in stream {
            latest = snapshot.content
            onPartial(latest)
        }
        return latest
    }

    /// 구조화 생성(@Generable)
    func generate<T: Generable>(_ session: LanguageModelSession, prompt: String, as type: T.Type, temperature: Double = 0.1) async throws -> T {
        let options = GenerationOptions(temperature: temperature)
        let response = try await session.respond(to: prompt, generating: type, options: options)
        return response.content
    }

    /// 에러를 사용자 문장으로 번역한다.
    nonisolated static func describe(_ error: any Error) -> String {
        if let modelError = error as? LanguageModelError {
            switch modelError {
            case .contextSizeExceeded:
                return "대화가 모델의 컨텍스트 한도를 넘었습니다. 새 대화를 시작해 주세요."
            case .refusal:
                return "모델이 이 요청에 대한 답변을 거부했습니다."
            case .rateLimited:
                return "요청이 너무 잦습니다. 잠시 후 다시 시도하세요."
            case .unsupportedLanguageOrLocale:
                return "모델이 지원하지 않는 언어입니다."
            default:
                return "모델 오류: \(modelError.localizedDescription)"
            }
        }
        return error.localizedDescription
    }
}

// MARK: - 구조화 생성 타입

/// 질의 재작성 결과(심층 모드). 검색용으로 바꾼 질문 여러 개.
@Generable
struct QueryRewrite {
    @Guide(description: "원 질문을 검색에 유리하게 바꾼 짧은 질의 2~3개", .count(3))
    var queries: [String]
}

/// 검색 청크 관련성 채점
@Generable
struct RelevanceGrade {
    @Guide(description: "이 문서 조각이 질문에 답하는 데 도움이 되면 true")
    var relevant: Bool
}

/// 근거만으로 답할 수 있는지(지식 부족 판정)
@Generable
struct GapAssessment {
    @Guide(description: "제공된 근거만으로 질문에 정확히 답할 수 있으면 true, 근거가 질문과 무관하거나 부족하면 false")
    var answerable: Bool
}

/// 초안 검증 결과
@Generable
struct GroundingVerdict {
    @Guide(description: "초안이 제공된 근거에만 기반하면 true")
    var grounded: Bool
    @Guide(description: "근거 없는 주장이나 누락이 있으면 한 줄로 설명, 없으면 빈 문자열")
    var issue: String
}

/// 지식 그래프용 트리플 추출
@Generable
struct ExtractedTriple {
    @Guide(description: "주어(개념, 사람, 제품 이름)")
    var subject: String
    @Guide(description: "관계를 나타내는 짧은 동사구(예: 사용한다, 포함한다, 만들었다)")
    var predicate: String
    @Guide(description: "목적어")
    var object: String
}

@Generable
struct ExtractedTriples {
    @Guide(description: "본문에서 뽑은 핵심 사실 트리플", .maximumCount(6))
    var triples: [ExtractedTriple]
}
