import Foundation
import CoreGraphics
import ImageIO
import Vision

/// 이미지 보조 분석. Foundation Models가 이미지를 직접 보지만(Attachment),
/// 작은 모델을 돕기 위해 Vision으로 분류 라벨과 OCR 텍스트를 미리 뽑아 근거에 보탠다.
nonisolated enum ImageUnderstanding {
    struct Analysis: Sendable {
        var labels: [String]
        var recognizedText: String

        var summaryLine: String {
            var parts: [String] = []
            if !labels.isEmpty { parts.append("분류: " + labels.joined(separator: ", ")) }
            if !recognizedText.isEmpty { parts.append("이미지 속 텍스트: " + String(recognizedText.prefix(400))) }
            return parts.isEmpty ? "특별한 내용을 감지하지 못함" : parts.joined(separator: " / ")
        }
    }

    static func cgImage(from pngData: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func analyze(_ image: CGImage) async -> Analysis {
        var labels: [String] = []
        var text = ""
        if let observations = try? await ClassifyImageRequest().perform(on: image) {
            labels = observations
                .filter { $0.confidence > 0.3 }
                .prefix(5)
                .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "ko-KR"), Locale.Language(identifier: "en-US")]
        if let observations = try? await request.perform(on: image) {
            text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }
        return Analysis(labels: labels, recognizedText: text)
    }
}
