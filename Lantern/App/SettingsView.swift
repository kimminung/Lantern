import SwiftUI

/// 설정 화면: 모델 상태, 백엔드, 하네스 정책, 임베딩, 음성 엔진
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var newRule = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section("언어 모델") {
                LabeledContent("온디바이스 모델", value: model.llm.readiness.message)
                LabeledContent("Private Cloud Compute", value: model.llm.pccReadiness.message)
                Picker("생성 백엔드", selection: Binding(
                    get: { model.llm.backend },
                    set: { model.llm.backend = $0 }
                )) {
                    ForEach(ModelBackend.allCases) { backend in
                        Text(backend.title).tag(backend)
                    }
                }
                Button("가용성 다시 확인") { model.llm.refreshAvailability() }
            }

            Section("하네스 정책") {
                TextField("페르소나", text: $model.policy.persona, axis: .vertical)
                Toggle("출처 번호 강제", isOn: $model.policy.requireCitations)
                Stepper("근거 최대 글자 수: \(model.policy.maxContextCharacters)", value: $model.policy.maxContextCharacters, in: 800...6_000, step: 200)
                Stepper("답변 최대 문장 수: \(model.policy.maxAnswerSentences)", value: $model.policy.maxAnswerSentences, in: 2...20)
                ForEach(Array(model.policy.rules.enumerated()), id: \.offset) { index, rule in
                    HStack {
                        Text("\(index + 1). \(rule)").font(.callout)
                        Spacer()
                        Button(role: .destructive) {
                            model.policy.rules.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("새 규칙", text: $newRule)
                    Button("추가") {
                        guard !newRule.isEmpty else { return }
                        model.policy.rules.append(newRule)
                        newRule = ""
                    }
                }
                Button("기본값으로 되돌리기") { model.policy = .default }
            }

            Section("임베딩 / 지식") {
                LabeledContent("임베딩 엔진", value: model.embedderName)
                LabeledContent("문서 / 청크", value: "\(model.documents.count) / \(model.chunkCount)")
                LabeledContent("그래프", value: "\(model.graphEntities.count) 개념 · \(model.graphRelations.count) 관계")
                LabeledContent("저장 위치", value: Persistence.shared.rootURL.path)
            }

            Section("음성 입력 (STT)") {
                Picker("엔진", selection: $model.selectedSpeechEngineIndex) {
                    ForEach(Array(model.speechEngines.enumerated()), id: \.offset) { index, engine in
                        Text(engine.displayName).tag(index)
                    }
                }
                .onChange(of: model.selectedSpeechEngineIndex) {
                    Task { await model.refreshSpeechNote() }
                }
                Text(model.speechNote).font(.caption).foregroundStyle(.secondary)
                if model.selectedSpeechEngineIndex == 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hugging Face 모델 넣는 곳").font(.caption.bold())
                        Text(HuggingFaceWhisperEngine.modelDirectory.path).font(.caption2.monospaced()).textSelection(.enabled)
                        ForEach(HuggingFaceWhisperEngine.suggestedRepositories, id: \.self) { repo in
                            Text("• \(repo)").font(.caption2)
                        }
                    }
                }
            }

            Section("정보") {
                LabeledContent("앱", value: "Lantern 1.0")
                LabeledContent("라이선스", value: "Apache-2.0")
                Text("모든 추론·검색·저장은 기기 안에서 이루어집니다. MCP 서버에 연결하거나 Private Cloud Compute를 켤 때만 데이터가 기기를 떠납니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("설정")
    }
}
