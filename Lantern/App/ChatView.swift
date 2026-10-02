import SwiftUI
import UniformTypeIdentifiers

/// 대화 화면: 메시지 목록 + 입력창 + (선택) 추적 패널
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var showTrace = true
    @State private var showImageImporter = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                messageList
                Divider()
                ComposerView(showImageImporter: $showImageImporter)
            }
            if showTrace {
                Divider()
                TracePanel(events: model.currentTrace, toolLog: model.toolCallLog)
                    .frame(width: 300)
            }
        }
        .navigationTitle(model.selectedConversation?.title ?? "Lantern")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ModelStatusBadge()
                Button {
                    withAnimation { showTrace.toggle() }
                } label: {
                    Label("추적 패널", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .help("그래프 실행 추적 패널 표시/숨김")
            }
        }
        .fileImporter(isPresented: $showImageImporter, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                if let data = try? Data(contentsOf: url) { model.attachImage(data: data) }
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let conversation = model.selectedConversation, conversation.messages.isEmpty {
                        EmptyChatHint()
                    }
                    ForEach(model.selectedConversation?.messages ?? []) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: model.selectedConversation?.messages.last?.text) {
                if let last = model.selectedConversation?.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

/// 빈 대화 안내
struct EmptyChatHint: View {
    @Environment(AppModel.self) private var model

    private let samples = [
        "랜턴은 어떤 앱이야?",
        "랜턴의 검색은 어떻게 동작해?",
        "MCP 서버는 어떻게 연결해?",
        "하네스가 하는 일을 설명해 줘",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("안녕하세요, Lantern(랜턴)입니다.")
                .font(.title2.bold())
            Text("기기 안에서만 동작하는 지식 비서예요. 문서를 가져오면 그 내용을 근거로 답하고, 출처 번호를 붙여 드립니다.")
                .foregroundStyle(.secondary)
            Text("이렇게 물어보세요")
                .font(.headline)
                .padding(.top, 6)
            ForEach(samples, id: \.self) { sample in
                Button {
                    model.composerText = sample
                } label: {
                    Label(sample, systemImage: "text.bubble")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 메시지 말풍선
struct MessageBubble: View {
    let message: ChatMessage
    @State private var showTrace = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.role == .user ? "person.circle.fill" : "brain.head.profile")
                .font(.title2)
                .foregroundStyle(message.role == .user ? Color.accentColor : Color.teal)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(message.role == .user ? "나" : "Lantern")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    if let mode = message.mode {
                        Label(mode.title, systemImage: mode.systemImage)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    if message.isStreaming {
                        ProgressView().controlSize(.mini)
                    }
                }
                if !message.images.isEmpty {
                    HStack {
                        ForEach(message.images) { attachment in
                            AttachmentThumbnail(attachment: attachment, size: 96)
                        }
                    }
                }
                if message.text.isEmpty && message.isStreaming {
                    Text("생각하는 중…").foregroundStyle(.secondary)
                } else {
                    Text(message.text)
                        .textSelection(.enabled)
                }
                if !message.citations.isEmpty {
                    CitationList(citations: message.citations)
                }
                if !message.trace.isEmpty {
                    DisclosureGroup(isExpanded: $showTrace) {
                        TraceTimeline(events: message.trace)
                            .padding(.top, 4)
                    } label: {
                        Label("실행 경로 \(message.trace.count)단계", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(message.role == .user ? Color.accentColor.opacity(0.08) : Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// 출처 목록
struct CitationList: View {
    let citations: [Citation]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("출처").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(citations) { citation in
                HStack(alignment: .top, spacing: 6) {
                    Text("[\(citation.index)]")
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(citation.documentTitle).font(.caption.bold())
                        Text(citation.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Text(String(format: "%.2f", citation.score))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 첨부 이미지 썸네일
struct AttachmentThumbnail: View {
    let attachment: ImageAttachment
    let size: CGFloat

    var body: some View {
        Group {
            if let cgImage = ImageUnderstanding.cgImage(from: attachment.pngData) {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// 입력창: 모드 선택, 이미지 첨부, 음성 입력, 전송
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @Binding var showImageImporter: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            if !model.pendingImages.isEmpty {
                HStack {
                    ForEach(model.pendingImages) { attachment in
                        ZStack(alignment: .topTrailing) {
                            AttachmentThumbnail(attachment: attachment, size: 64)
                            Button {
                                model.removePendingImage(attachment.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .offset(x: 6, y: -6)
                        }
                    }
                }
            }
            if model.isListening {
                HStack(spacing: 6) {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative)
                    Text(model.dictationPreview.isEmpty ? "듣는 중…" : model.dictationPreview)
                        .lineLimit(2)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Picker("모드", selection: $model.mode) {
                    ForEach(AgentMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 140)
                .help("빠른 답변: 검색 1회 → 생성. 심층 검색: 재작성·채점·그래프·MCP·검증까지 수행")

                Button {
                    showImageImporter = true
                } label: {
                    Image(systemName: "photo.badge.plus")
                }
                .help("이미지 첨부 (온디바이스 모델이 직접 봅니다)")

                Button {
                    Task { await model.toggleDictation() }
                } label: {
                    Image(systemName: model.isListening ? "mic.fill" : "mic")
                        .foregroundStyle(model.isListening ? .red : .primary)
                }
                .help(model.speechNote.isEmpty ? "음성 입력" : model.speechNote)

                TextField("질문을 입력하세요…", text: $model.composerText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .onSubmit { Task { await model.send() } }

                Button {
                    Task { await model.send() }
                } label: {
                    Image(systemName: model.isGenerating ? "hourglass" : "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(model.isGenerating || (model.composerText.trimmingCharacters(in: .whitespaces).isEmpty && model.pendingImages.isEmpty))
                .keyboardShortcut(.return, modifiers: .command)
            }
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
    }
}

/// 모델 상태 뱃지(툴바)
struct ModelStatusBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ready = model.llm.readiness.isReady
        Label(ready ? "온디바이스" : "모델 없음", systemImage: ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(ready ? .green : .orange)
            .help(model.llm.readiness.message)
    }
}

/// 실행 추적 패널(우측)
struct TracePanel: View {
    let events: [TraceEvent]
    let toolLog: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("그래프 실행 추적").font(.headline)
                AgentFlowStrip(events: events)
                if events.isEmpty {
                    Text("질문을 보내면 각 노드의 실행 결과가 여기에 나타납니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TraceTimeline(events: events)
                }
                if !toolLog.isEmpty {
                    Divider()
                    Text("도구 호출 로그").font(.headline)
                    ForEach(Array(toolLog.suffix(8).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).lineLimit(3)
                    }
                }
            }
            .padding()
        }
        .background(.background.secondary)
    }
}

/// 노드 실행 타임라인
struct TraceTimeline: View {
    let events: [TraceEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(events) { event in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(for: event.status))
                        .foregroundStyle(color(for: event.status))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(event.title).font(.caption.bold())
                            Spacer()
                            if event.status != .running {
                                Text("\(event.durationMS) ms").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            }
                        }
                        if !event.summary.isEmpty {
                            Text(event.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func icon(for status: TraceEvent.Status) -> String {
        switch status {
        case .running: return "circle.dotted"
        case .succeeded: return "checkmark.circle.fill"
        case .skipped: return "arrow.turn.down.right"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func color(for status: TraceEvent.Status) -> Color {
        switch status {
        case .running: return .blue
        case .succeeded: return .green
        case .skipped: return .gray
        case .failed: return .red
        }
    }
}

/// 그래프 노드를 한 줄로 그리고 실행된 경로를 강조한다.
struct AgentFlowStrip: View {
    let events: [TraceEvent]

    var body: some View {
        let statusByNode = Dictionary(events.map { ($0.nodeID, $0.status) }, uniquingKeysWith: { _, new in new })
        FlowLayout(spacing: 4) {
            ForEach(Array(LanternAgent.nodeTitles.enumerated()), id: \.element.id) { index, node in
                HStack(spacing: 4) {
                    Text(node.title)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(background(for: statusByNode[node.id]), in: Capsule())
                        .foregroundStyle(statusByNode[node.id] == nil ? .secondary : .primary)
                    if index < LanternAgent.nodeTitles.count - 1 {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func background(for status: TraceEvent.Status?) -> Color {
        switch status {
        case .running: return .blue.opacity(0.25)
        case .succeeded: return .green.opacity(0.25)
        case .skipped: return .gray.opacity(0.15)
        case .failed: return .red.opacity(0.25)
        case .none: return .gray.opacity(0.08)
        }
    }
}

/// 줄바꿈되는 간단한 플로우 레이아웃
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 300
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
