import Foundation
import AVFoundation
import Speech

/// 음성 → 텍스트 엔진 인터페이스. 기본 구현은 Apple Speech(SpeechAnalyzer/SpeechTranscriber, 온디바이스).
/// 사용자가 Hugging Face에서 받은 Whisper 계열 Core ML 모델을 꽂을 수 있도록 두 번째 구현 슬롯을 둔다.
@MainActor
protocol TranscriptionEngine: AnyObject {
    var displayName: String { get }
    /// 엔진이 바로 쓸 수 있는지. 자산 다운로드가 필요하면 false와 안내 문구.
    func availability() async -> (ready: Bool, note: String)
    /// 마이크에서 받아쓰기 시작. 부분 결과와 최종 결과를 콜백으로 전달한다.
    func start(onPartial: @escaping @MainActor (String) -> Void, onFinal: @escaping @MainActor (String) -> Void) async throws
    func stop() async
}

enum SpeechError: LocalizedError {
    case microphoneDenied
    case unsupportedLocale
    case engineNotInstalled(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "마이크 권한이 없습니다. 시스템 설정에서 허용해 주세요."
        case .unsupportedLocale: return "현재 언어는 온디바이스 음성 인식을 지원하지 않습니다."
        case .engineNotInstalled(let note): return note
        }
    }
}

// MARK: - Apple Speech (기본)

/// SpeechAnalyzer + SpeechTranscriber로 실시간 받아쓰기. AVAudioEngine 입력 탭을 AnalyzerInput으로 변환해 흘려보낸다.
@MainActor
final class AppleSpeechEngine: TranscriptionEngine {
    let displayName = "Apple SpeechTranscriber (온디바이스)"

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var audioEngine: AVAudioEngine?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var committedText = ""

    func availability() async -> (ready: Bool, note: String) {
        guard SpeechTranscriber.isAvailable else {
            return (false, "이 기기는 SpeechTranscriber를 지원하지 않습니다.")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            return (false, "현재 언어(\(Locale.current.identifier))는 지원되지 않습니다.")
        }
        let probe = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            _ = request
            return (true, "첫 사용 시 음성 모델 자산(\(locale.identifier))을 내려받습니다.")
        }
        return (true, "음성 모델 준비됨 (\(locale.identifier))")
    }

    func start(onPartial: @escaping @MainActor (String) -> Void, onFinal: @escaping @MainActor (String) -> Void) async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw SpeechError.microphoneDenied
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw SpeechError.unsupportedLocale
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechError.unsupportedLocale
        }

        let (inputSequence, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let converter = AnalyzerInputConverter(analyzerFormat: analyzerFormat)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { buffer, _ in
            // 오디오 스레드에서 호출된다. 변환 후 스트림에 넣는다.
            if let inputs = try? converter.convert(buffer, at: nil) {
                for input in inputs { builder.yield(input) }
            }
        }

        committedText = ""
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard let self else { return }
                    if result.isFinal {
                        self.committedText += (self.committedText.isEmpty ? "" : " ") + text
                        onFinal(self.committedText)
                    } else {
                        let preview = self.committedText.isEmpty ? text : self.committedText + " " + text
                        onPartial(preview)
                    }
                }
            } catch {
                // 분석기가 종료되면 스트림도 끝난다.
            }
        }

        try await analyzer.start(inputSequence: inputSequence)
        engine.prepare()
        try engine.start()

        self.analyzer = analyzer
        self.transcriber = transcriber
        self.audioEngine = engine
        self.inputBuilder = builder
    }

    func stop() async {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        inputBuilder?.finish()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        resultsTask?.cancel()
        analyzer = nil
        transcriber = nil
        audioEngine = nil
        inputBuilder = nil
    }
}

// MARK: - Hugging Face 모델 슬롯 (탑재 예정)

/// Hugging Face에서 내려받은 Whisper 계열 Core ML 모델을 위한 자리.
/// 모델 파일을 `Application Support/Lantern/models/whisper/` 에 넣으면 `availability()`가 감지한다.
/// 실제 추론 코드는 모델 포맷(예: whisperkit-coreml, openai/whisper-*.mlpackage)에 맞춰 `start`에 채우면 된다.
@MainActor
final class HuggingFaceWhisperEngine: TranscriptionEngine {
    let displayName = "Hugging Face Whisper (Core ML, 탑재 예정)"

    /// 모델을 둘 폴더. 예: whisper-base.mlmodelc, tokenizer.json
    static let modelDirectory: URL = Persistence.shared.rootURL.appendingPathComponent("models/whisper", isDirectory: true)

    /// 추천 다운로드 출처. 설정 화면에서 안내로 보여 준다.
    static let suggestedRepositories = [
        "argmaxinc/whisperkit-coreml",
        "openai/whisper-base (Core ML 변환 필요)",
    ]

    func availability() async -> (ready: Bool, note: String) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: Self.modelDirectory, withIntermediateDirectories: true)
        let contents = (try? fileManager.contentsOfDirectory(atPath: Self.modelDirectory.path)) ?? []
        let hasModel = contents.contains { $0.hasSuffix(".mlmodelc") || $0.hasSuffix(".mlpackage") }
        if hasModel {
            return (false, "모델 파일을 찾았지만 추론 코드는 아직 연결되지 않았습니다(탑재 예정).")
        }
        return (false, "모델 탑재 예정. \(Self.modelDirectory.path) 에 Core ML 모델을 넣어 주세요.")
    }

    func start(onPartial: @escaping @MainActor (String) -> Void, onFinal: @escaping @MainActor (String) -> Void) async throws {
        // TODO: 모델 로드 → 16kHz 모노 PCM 캡처 → 멜 스펙트로그램 → 디코딩 루프.
        // 1. let model = try MLModel(contentsOf: Self.modelDirectory.appendingPathComponent("whisper-base.mlmodelc"))
        // 2. AVAudioEngine 입력을 16kHz Float32로 변환해 30초 윈도로 모은다.
        // 3. 인코더/디코더를 돌려 토큰을 텍스트로 바꾼 뒤 onPartial/onFinal로 전달한다.
        throw SpeechError.engineNotInstalled("Hugging Face Whisper 모델은 탑재 예정입니다. 현재는 Apple SpeechTranscriber를 사용하세요.")
    }

    func stop() async {}
}
