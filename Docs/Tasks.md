# Lantern(랜턴) — 태스크 문서

상태: ✅ 완료 · 🔄 진행/검증 중 · ⬜ 미착수. 날짜는 2026-10-02 기준.

## 에픽 1. 프로젝트 기반

| ID | 태스크 | 상태 | 비고 |
|---|---|---|---|
| T1.1 | Xcode 멀티플랫폼 타깃 설정(macOS/iOS/visionOS 27), 표시 이름 "Lantern" | ✅ | `INFOPLIST_KEY_CFBundleDisplayName` |
| T1.2 | 샌드박스 해제, 마이크·음성 인식 사용 설명 추가 | ✅ | MCP stdio·HTTP 때문에 샌드박스 OFF |
| T1.3 | 데이터 모델(대화·지식·그래프·MCP·JSONValue) | ✅ | `Core/Models.swift`, 전부 `nonisolated` |
| T1.4 | JSON 저장소 | ✅ | `Core/Persistence.swift` |
| T1.5 | Apache-2.0 LICENSE, NOTICE, .gitignore | ✅ | apache.org 원문 |

## 에픽 2. 언어 모델과 하네스

| ID | 태스크 | 상태 | 비고 |
|---|---|---|---|
| T2.1 | FoundationModels 가용성 확인·에러 번역 | ✅ | `LanguageModelService` |
| T2.2 | 텍스트/스트리밍/구조화 생성 래퍼 | ✅ | `respond`, `stream`, `generate` |
| T2.3 | 멀티모달 Attachment 프롬프트 | ✅ | `respond(_:prompt:images:)` |
| T2.4 | HarnessPolicy + Instructions 조립 | ✅ | 설정 화면에서 편집 가능 |
| T2.5 | 근거 블록 조립(글자 예산, 도구 결과 번호 부여) | ✅ | `Harness.assembleContext` |
| T2.6 | 출력 검사(출처 누락·유령 인용·길이) + 자동 수정 | ✅ | `Harness.check`, `repairPrompt` |
| T2.7 | 심층 근거 검증(GroundingVerdict) | ✅ | 실측: 검증 통과/수정 1회 모두 관찰 |
| T2.8 | Private Cloud Compute 백엔드(엔타이틀먼트 필요) | 🔄 | 코드 완료, 엔타이틀먼트 미신청이라 사용 불가 상태 |

## 에픽 3. RAG

| ID | 태스크 | 상태 | 비고 |
|---|---|---|---|
| T3.1 | NLContextualEmbedding 엔진(자산 요청·평균 풀링) | ✅ | ko 모델 512차원, 스니펫으로 벡터 생성 확인 |
| T3.2 | 해싱 n-gram 폴백 | ✅ | 자산 없을 때 자동 |
| T3.3 | 청커(문단 기준 360자, 겹침) | ✅ | 480→360으로 조정 |
| T3.4 | 하이브리드 검색(코사인+키워드) | ✅ | 가중치 0.65/0.35 |
| T3.5 | 파일 가져오기(txt/md/pdf), 붙여넣기 | ✅ | PDFKit |
| T3.6 | 임베딩 엔진 교체 시 재색인 | ✅ | `embedder.json`으로 변경 감지 |
| T3.7 | 한국어 조사·활용형 제거 토크나이저 | ✅ | 엔티티 노이즈("모드에서","사용합니다") 제거 |
| T3.8 | 지식 부족 판정(문턱 0.45 + GapAssessment) | ✅ | 무관 질문 0.41 vs 관련 0.57~0.71 실측 |

## 에픽 4. 지식 그래프

| ID | 태스크 | 상태 | 비고 |
|---|---|---|---|
| T4.1 | 트리플 저장소(actor) + 영속화 | ✅ | `KnowledgeGraph` |
| T4.2 | NLTagger 저렴 추출(가져오기 시 자동) | ✅ | "함께 언급" 관계 |
| T4.3 | LLM 트리플 추출(ExtractedTriples) | ✅ | 지식 저장소 메뉴에서 실행 |
| T4.4 | 질문 관련 1홉 사실을 근거에 포함 | ✅ | 그래프 확장 노드 |
| T4.5 | 그래프 뷰(원형 배치 Canvas, 이웃 패널) | ✅ | 상위 40개 표시 |
| T4.6 | force-directed 레이아웃, 확대/이동 | ⬜ | v1.1 |

## 에픽 5. 에이전트 그래프

| ID | 태스크 | 상태 | 비고 |
|---|---|---|---|
| T5.1 | StateGraph 엔진(노드·고정/조건부 간선·추적·최대 스텝) | ✅ | `Core/StateGraph.swift` |
| T5.2 | 11개 노드 구현과 조건부 분기 | ✅ | `Core/LanternAgent.swift` |
| T5.3 | 빠른/심층 모드 | ✅ | 실측 8.7초 / 15.2초 |
| T5.4 | 실행 추적 패널 + 에이전트 그래프 탭 | ✅ | 노드 상태 색상, 소요 ms |
| T5.5 | 대화 기억(최근 4턴 주입) | ✅ | 세션은 요청마다 새로 생성 |
| T5.6 | 디버그 실행 인자(-autoAsk, -deep, -open) + `/tmp/lantern-launch.json` 지시 파일(ask/deep/open/mcpURL) | ✅ | 스크린샷·검증 자동화에 사용. 터미널 직접 실행은 macOS "다른 앱 데이터" 보호로 멈출 수 있어 Xcode 실행 + 지시 파일을 권장 |

## 에픽 6. MCP

| ID | 태스크 | 상태 | 비고 |
|---|---|---|---|
| T6.1 | JSON-RPC 2.0 클라이언트(initialize/tools) | ✅ | `MCPClient` |
| T6.2 | stdio 전송(macOS) | ✅ | DYLD_* 제거, stderr 진단 포함. Python 스텁으로 확인 |
| T6.3 | Streamable HTTP 전송(JSON/SSE, 세션 ID) | ✅ | Python 스텁으로 확인 |
| T6.4 | JSON Schema → DynamicGenerationSchema 브리지 | ✅ | 모델이 `add` 도구 호출 성공 |
| T6.5 | MCP 화면(서버 추가/연결, 도구 목록, 수동 호출) | ✅ | |
| T6.6 | 지식 부족 → 도구 조사 → 학습 노드 | ✅ | 앱 내 실행 확인(5555) |
| T6.7 | OAuth/인증 흐름, 리소스·프롬프트 기능 | ⬜ | v1.1 (현재는 Authorization 헤더만) |
| T6.8 | 실제 공개 MCP 서버(npx 기반)로 검증 | 🔄 | 이 Mac에 Node 미설치. 설치 후 `@modelcontextprotocol/server-everything`으로 확인 필요 |

## 에픽 7. 멀티모달·음성

| ID | 태스크 | 상태 | 비고 |
|---|---|---|---|
| T7.1 | 이미지 첨부 UI + Attachment 전달 | ✅ | `fileImporter` |
| T7.2 | Vision 분류·OCR 사전 분석 | ✅ | `ImageUnderstanding` |
| T7.3 | OCRTool 세션 도구(macOS) | ✅ | iOS 시뮬레이터에선 심볼 없어 `#if os(macOS)` |
| T7.4 | Apple SpeechTranscriber 실시간 받아쓰기 | 🔄 | 코드 완료, 빌드 확인. 실제 마이크 세션은 사용자 환경에서 확인 필요 |
| T7.5 | Hugging Face Whisper 슬롯(폴더 감지, 안내, TODO) | ✅ | "모델 탑재 예정" 안내 표시 |
| T7.6 | HF Whisper 추론 연결 | ⬜ | 모델 포맷 결정 후 |
| T7.7 | `installTap` 사용 중단(macOS 27) 대응 | ⬜ | `installAudioTap(onBus:bufferSize:format:tapProvider:)`로 교체 |

## 에픽 8. 문서·배포

| ID | 태스크 | 상태 | 비고 |
|---|---|---|---|
| T8.1 | README(한/영 요약), 스크린샷 7종, 다이어그램 4종 | ✅ | `Docs/` |
| T8.2 | Tech PRD, Tasks | ✅ | 이 문서 |
| T8.3 | git 저장소 초기화 | ✅ | 커밋은 GitHub Desktop에서 |
| T8.4 | Swift Testing 단위 테스트(Chunker, Tokenizer, Harness.check, SchemaConverter) | ⬜ | 테스트 타깃 추가 필요 |
| T8.5 | iOS 실기기/시뮬레이터 UI 확인 | ⬜ | 빌드만 확인됨 |

## 검증 로그 (2026-10-02)

| 시나리오 | 결과 |
|---|---|
| macOS 빌드 | 성공, 경고 1(installTap deprecated) |
| iOS 시뮬레이터 빌드 | 성공 |
| 빠른 모드 "랜턴의 검색은 어떻게 동작해?" | 8.7초, 출처 3개, 규칙 통과 |
| 심층 모드 "랜턴의 하네스는 답변 일관성을 어떻게 지켜?" | 15.2초, 재작성 4질의, 채점 유지 3/제외 2, 근거 검증 통과, 출처 1개(0.71) |
| 심층 모드 + MCP 스텁 "1234 더하기 4321은 얼마야?" | 지식 부족 감지 → add 도구 호출 → "5555" 답변 |
| MCP stdio/HTTP 스텁 왕복 | echo/add 성공, 스키마 변환 성공 |
| NLContextualEmbedding ko | 512차원 벡터 생성 |
