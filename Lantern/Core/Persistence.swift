import Foundation

/// Application Support/Lantern 아래에 JSON 파일로 상태를 저장하는 아주 작은 저장소.
/// 데이터베이스 없이도 지식·대화·설정이 투명하게 파일로 남는다.
nonisolated struct Persistence: Sendable {
    static let shared = Persistence()

    let rootURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        rootURL = base.appendingPathComponent("Lantern", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func url(for name: String) -> URL {
        rootURL.appendingPathComponent(name)
    }

    func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = url(for: name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    func save<T: Encodable>(_ value: T, to name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(for: name), options: .atomic)
    }

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }
}
