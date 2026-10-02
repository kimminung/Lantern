import Foundation

/// 첫 실행 때 지식 저장소에 심는 기본 문서. 앱 자체 설명서라서 "Lantern이 뭐야?" 같은 질문에 바로 답할 수 있다.
nonisolated enum SeedKnowledge {
    static let title = "Lantern(랜턴) 사용 안내"

    static let text = """
    Lantern(랜턴)은 Apple 기기 안에서만 동작하는 온디바이스 RAG 에이전트입니다. 이름은 어두운 곳을 비추는 등불에서 따왔습니다. 내 기기 안에 들고 다니는 지식이 질문하는 순간 환하게 켜진다는 뜻입니다. 모든 대화와 문서는 기기를 떠나지 않습니다.

    Lantern의 언어 모델은 Apple Foundation Models 프레임워크의 온디바이스 시스템 언어 모델(SystemLanguageModel)입니다. 약 30억 매개변수의 작은 모델이라 빠르고 가볍지만, 모르는 사실은 RAG(검색 증강 생성)로 보완합니다. 심층 모드에서는 Private Cloud Compute 모델을 선택적으로 켤 수 있습니다.

    Lantern의 검색은 하이브리드입니다. Apple NaturalLanguage의 NLContextualEmbedding으로 문장 벡터를 만들어 코사인 유사도를 계산하고, 키워드 겹침 점수를 더합니다. 임베딩 자산이 없으면 해싱 n-gram 폴백으로 동작합니다.

    Lantern은 LangGraph 방식의 상태 그래프(StateGraph)로 에이전트 흐름을 관리합니다. 노드는 입력 분석, 이미지 이해, 질의 재작성, 검색, 채점, 그래프 확장, 외부 도구 호출, 초안 생성, 검증, 마무리 순서로 이어지며, 조건부 간선이 다음 노드를 고릅니다. 각 노드의 실행 기록은 추적 패널에 표시됩니다.

    Lantern의 지식 그래프는 주어-술어-목적어 트리플로 사실을 저장합니다. 심층 모드에서는 언어 모델이 트리플을 추출하고, 빠른 모드에서는 NLTagger 고유명사 동시 출현으로 저렴하게 관계를 만듭니다. 질문에 등장한 개념의 1홉 이웃 사실을 답변 근거에 보탭니다.

    Lantern은 MCP(Model Context Protocol) 클라이언트를 내장합니다. macOS에서는 stdio 전송으로 로컬 MCP 서버 프로세스를 띄울 수 있고, 모든 플랫폼에서 Streamable HTTP 전송으로 원격 MCP 서버에 연결할 수 있습니다. 서버의 tools/list 결과는 Foundation Models의 Tool로 감싸져 모델이 직접 호출합니다.

    Lantern의 하네스(Harness)는 답변의 일관성을 지키는 규칙 묶음입니다. 페르소나와 답변 규칙을 Instructions로 고정하고, 출처 번호 표기를 강제하며, 근거가 없으면 모른다고 말하게 합니다. 심층 모드에서는 검증 노드가 초안이 근거에 충실한지 판정하고 필요하면 한 번 더 고칩니다.

    Lantern은 이미지 첨부를 지원합니다. Foundation Models의 Attachment로 이미지를 모델에 직접 전달하고, Vision 프레임워크의 OCR 도구와 이미지 분류로 보조 설명을 만듭니다.

    Lantern의 음성 입력은 Apple Speech 프레임워크의 SpeechAnalyzer와 SpeechTranscriber를 사용합니다. 온디바이스 모델 자산을 내려받아 실시간으로 받아쓰기하며, Hugging Face에서 받은 Whisper 계열 Core ML 모델을 꽂을 수 있는 슬롯도 마련되어 있습니다.

    Lantern은 Apache-2.0 라이선스로 공개됩니다. 소스 코드는 SwiftUI와 Swift로만 작성되었으며, Combine 대신 async/await를 사용합니다.
    """
}
