import SwiftUI

/// Lantern(랜턴) — 온디바이스 RAG 에이전트
@main
struct MyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        #endif
    }
}
