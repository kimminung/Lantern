"""Korean pronunciation check with SenseVoice (sherpa-onnx): transcribe a wav and score CER against the script."""
import os, re, unicodedata
import numpy as np
import soundfile as sf
import sherpa_onnx

SV_DIR = os.environ.get(
    "SV_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "models", "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17")
)
_rec = None

# ASR may write some words in Latin script or digits; map them to the spoken Hangul used in the script.
EQUIV = [
    ("mcp", "엠씨피"), ("rag", "래그"), ("json", "제이슨"), ("langgraph", "랭그래프"),
    ("apple", "애플"), ("ai", "에이아이"),
    ("레그", "래그"), ("엠시피", "엠씨피"), ("랜턴는", "랜턴은"), ("제이선", "제이슨"), ("체점", "채점"), ("인베딩", "임베딩"),
]


def get_rec():
    global _rec
    if _rec is None:
        _rec = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=f"{SV_DIR}/model.int8.onnx",
            tokens=f"{SV_DIR}/tokens.txt",
            num_threads=2,
            language="ko",
            use_itn=False,
        )
    return _rec


def transcribe(path):
    rec = get_rec()
    audio, sr = sf.read(path, dtype="float32", always_2d=False)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    s = rec.create_stream()
    s.accept_waveform(sr, audio)
    rec.decode_stream(s)
    return s.result.text.strip()


def norm(text):
    t = unicodedata.normalize("NFC", text).lower()
    for a, b in EQUIV:
        t = t.replace(a, b)
    t = re.sub(r"[^0-9a-z가-힣]", "", t)
    return t


def lev(a, b):
    if a == b:
        return 0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def cer(ref, hyp):
    r, h = norm(ref), norm(hyp)
    return lev(r, h) / max(1, len(r))


if __name__ == "__main__":
    import sys
    hyp = transcribe(sys.argv[1])
    print(hyp)
    if len(sys.argv) > 2:
        print("CER", round(cer(sys.argv[2], hyp), 4))
