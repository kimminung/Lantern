# Lantern 소개 영상

| 파일 | 내용 |
|---|---|
| `lantern-intro.mp4` | 1분 53초, 1920×1080 30fps, H.264 + AAC. 한국어 내레이션·자막과 배경 음악 포함 |
| `lantern-intro.gif` | 약 35초 하이라이트, 1120px 15fps. 소리 없이 짧은 자막만 표시 |

## 화면에 나오는 값의 출처

- **앱 화면**: `Docs/screenshots/`의 실제 스크린샷(빠른 답변, 심층 검색, 지식 부족 → MCP, 설정)을 그대로 쓰고 위에 강조 표시만 얹었습니다. 추적 패널의 소요 시간(질의 재작성 3,598ms, 관련성 채점 7,200ms, 외부 도구 2,136ms 등)과 `add: 5555`는 스크린샷 속 실제 실행 기록입니다.
- **수치**: 하이브리드 가중치 0.65/0.35, 지식 부족 문턱 0.45, 청크 360자·겹침 60자, 상위 4/6개, 근거 2,400자, 노드 11개, 최대 24스텝은 `Core/VectorStore.swift`, `Core/LanternAgent.swift`, `Core/StateGraph.swift`, `Core/Harness.swift`의 값입니다. 지연 8.7초·약 15초, 관련 문서 0.57~0.71·무관 문서 약 0.41은 `Docs/Tasks.md`와 `Docs/TechPRD.md`의 측정값입니다.
- **지식 그래프 장면**: `Docs/screenshots/graph.png`의 18개 개념·13개 관계를 같은 배치로 다시 그렸습니다. 관계 이름 "함께 언급"은 `KnowledgeGraph.extractCheap`이 만드는 관계입니다.
- **저장 파일 목록**: `Application Support/Lantern/` 아래 실제 파일 이름(`chunks.json`, `graph-relations.json`, `harness-policy.json` 등)입니다.
- **하네스 장면의 답변 초안**은 `Harness.check`가 "존재하지 않는 출처 번호 인용"을 잡아내는 과정을 보여 주는 예시입니다.

## 구성

```
src/
├── index.html · scenes.js     장면 (모든 프레임이 시간 t의 순수 함수 window.seek(t))
├── data_tl.js                 내레이션 타임라인 (audio/make_tl.py가 생성)
├── render.js                  Playwright 프레임 캡처 → ffmpeg 마스터 (video / stills / events)
├── render_gif.js · make_gif.py  GIF 하이라이트 구간 → 팔레트 GIF
├── encode.sh                  마스터 + 믹스 → MP4 (2패스, 10MB 미만)
└── audio/                     script.json(대본), tts.py(Supertonic 3), asr.py(SenseVoice 검사),
                               takes.py · pick_under_music.py, build_narration.py, music.py, mix.py
```

- **내레이션**: [Supertonic 3](https://github.com/supertone-inc/supertonic) 한국어 여성 음성(sherpa-onnx, 화자 4). 줄마다 여러 테이크를 만들고 SenseVoice 음성 인식으로 발음을 검사했습니다. 마지막에는 음악을 깐 상태로 다시 검사해 가장 또렷한 테이크를 골랐습니다.
- **음악**: 직접 작곡한 "Lantern Nocturne". D♭장조, 72 BPM이고, 피아노·따뜻한 패드·느린 현악·첼레스타로 편성했습니다. `music.py`가 MIDI로 쓰고 FluidSynth와 MuseScore General 사운드폰트로 렌더링합니다. 등불이 켜지거나 노드에 불이 들어오는 순간이 8분음표 박자에 맞도록 화면 이벤트를 정렬했고, 그 자리에 첼레스타가 울립니다. 내레이션이 나오는 동안에는 음악이 자동으로 작아집니다.
- **디자인**: 앱 아이콘의 밤하늘 남색과 등불 호박색을 그대로 썼습니다. 글꼴은 Pretendard, Fraunces, IBM Plex Mono입니다.

## 다시 만들기

`src/render.js`는 저장소 루트를 웹 서버로 열고 `Docs/screenshots`, `Docs/diagrams`, 앱 아이콘을 그대로 읽습니다.

```bash
cd Docs/video/src
npm install                                    # 글꼴 + gsap + playwright (npx playwright install chromium)

# 1) 오디오 (선택)
pip install sherpa-onnx soundfile pyloudnorm pedalboard mido scipy praat-parselmouth
brew install fluid-synth                       # + MuseScore_General.sf3 (SOUNDFONT 환경 변수로 경로 지정)
audio/get_models.sh
python3 audio/takes.py 5 4 1.05                # 줄마다 5테이크 → ASR로 선택
python3 audio/build_narration.py               # → audio/build/narration.wav, timeline.json
python3 audio/make_tl.py                       # → data_tl.js
node render.js events audio/build/events.json  # 화면 이벤트(박자에 맞춘 시점)
python3 audio/music.py                         # → audio/build/music.wav
python3 audio/mix.py                           # → audio/build/mix.wav (-16 LUFS, -1 dBTP 이하)

# 2) 영상과 GIF
node render.js video ../master.mkv
./encode.sh ../master.mkv audio/build/mix.wav ../lantern-intro.mp4 580
node render_gif.js ../gif_frames && python3 make_gif.py ../gif_frames ../lantern-intro.gif 1120
```

화면만 고칠 때는 1단계를 건너뛰고 기존 영상의 오디오를 그대로 쓰면 됩니다.

```bash
ffmpeg -i ../lantern-intro.mp4 -vn -c copy audio/build/mix.m4a
./encode.sh ../master.mkv audio/build/mix.m4a ../lantern-intro.mp4 580
```

`node render.js stills ../stills 30 50.5`처럼 원하는 시점의 정지 화면만 뽑아 볼 수 있습니다.
