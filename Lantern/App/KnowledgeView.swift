import SwiftUI
import UniformTypeIdentifiers

/// 지식 저장소 화면: 문서 목록, 가져오기, 청크 보기, 검색 테스트
struct KnowledgeView: View {
    @Environment(AppModel.self) private var model
    @State private var showFileImporter = false
    @State private var showPasteSheet = false
    @State private var selectedDocument: KnowledgeDocument?
    @State private var searchQuery = ""
    @State private var searchResults: [RetrievedChunk] = []

    var body: some View {
        HSplitOrStack {
            documentList
                .frame(minWidth: 260)
        } detail: {
            detail
        }
        .navigationTitle("지식 저장소")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showFileImporter = true } label: { Label("파일 가져오기", systemImage: "doc.badge.plus") }
                Button { showPasteSheet = true } label: { Label("텍스트 추가", systemImage: "text.badge.plus") }
                Menu {
                    Button("전체 문서에서 트리플 추출 (LLM)") { Task { await model.extractGraphDeep(for: nil) } }
                } label: {
                    Label("지식 그래프", systemImage: "point.3.filled.connected.trianglepath.dotted")
                }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: AppModel.importableTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await model.importFiles(urls) }
            }
        }
        .sheet(isPresented: $showPasteSheet) {
            PasteTextSheet()
        }
    }

    private var documentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.documents.count)개 문서 · \(model.chunkCount)개 청크").font(.caption.bold())
                    Text(model.embedderName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if model.isIndexing {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(10)
            if model.isIndexing, !model.indexingNote.isEmpty {
                Text(model.indexingNote).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            }
            List(selection: $selectedDocument) {
                ForEach(model.documents) { document in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(document.title).font(.body).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(sourceLabel(document.source))
                            Text("청크 \(document.chunkCount)")
                            Text(document.addedAt, style: .date)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .tag(document)
                    .contextMenu {
                        Button("이 문서에서 트리플 추출 (LLM)") { Task { await model.extractGraphDeep(for: document) } }
                        Button("삭제", role: .destructive) {
                            Task {
                                await model.removeDocument(document)
                                if selectedDocument == document { selectedDocument = nil }
                            }
                        }
                    }
                }
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("검색 테스트 (하이브리드 점수 확인)", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                Button("검색") { runSearch() }
            }
            if !searchResults.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(searchResults) { result in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(result.chunk.documentTitle).font(.caption.bold())
                                    Spacer()
                                    Text(String(format: "합산 %.2f · 벡터 %.2f · 키워드 %.2f", result.score, result.vectorScore, result.keywordScore))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Text(result.chunk.text).font(.caption).lineLimit(4)
                            }
                            .padding(8)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            } else if let document = selectedDocument {
                DocumentChunksView(document: document)
            } else {
                ContentUnavailableView("문서를 선택하세요", systemImage: "doc.text.magnifyingglass", description: Text("왼쪽 목록에서 문서를 고르면 청크와 임베딩 정보를 볼 수 있습니다."))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding()
    }

    private func runSearch() {
        let query = searchQuery
        Task {
            searchResults = query.isEmpty ? [] : await model.testSearch(query)
        }
    }

    private func sourceLabel(_ source: KnowledgeDocument.Source) -> String {
        switch source {
        case .seed: return "내장"
        case .file: return "파일"
        case .pasted: return "붙여넣기"
        case .tool: return "도구 수집"
        case .memory: return "기억"
        }
    }
}

/// 문서의 청크 목록
struct DocumentChunksView: View {
    @Environment(AppModel.self) private var model
    let document: KnowledgeDocument
    @State private var chunks: [KnowledgeChunk] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(document.title).font(.title3.bold())
                Text(document.origin).font(.caption).foregroundStyle(.secondary)
                ForEach(chunks) { chunk in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("청크 \(chunk.ordinal + 1)").font(.caption.bold())
                            Spacer()
                            Text("\(chunk.vector.count)차원 · 키워드 \(chunk.keywords.count)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        Text(chunk.text).font(.callout).textSelection(.enabled)
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .task(id: document.id) {
            chunks = await model.chunks(for: document)
        }
    }
}

/// 텍스트 붙여넣기 시트
struct PasteTextSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("텍스트로 지식 추가").font(.headline)
            TextField("제목 (비우면 첫 줄 사용)", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("추가") {
                    let savedTitle = title
                    let savedText = text
                    dismiss()
                    Task { await model.addPastedText(title: savedTitle, text: savedText) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 360)
    }
}

/// macOS에선 좌우 분할, 좁은 화면에선 위아래 쌓기
struct HSplitOrStack<Primary: View, Detail: View>: View {
    @ViewBuilder var primary: () -> Primary
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                primary()
                Divider()
                detail()
                    .frame(minWidth: 400)
            }
            VStack(spacing: 0) {
                primary()
                Divider()
                detail()
            }
        }
    }
}
