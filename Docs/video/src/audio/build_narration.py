"""Assemble the chosen takes into one narration track and a timeline for the visuals.

writes build/narration.wav (48 kHz mono) and build/timeline.json
timeline: {duration, scenes:[{id, chapter, start, end}], lines:[{id, scene, start, end, cap, cues:{name: t}}]}
"""
import json, os, re, sys
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from asr import get_rec

SR = 48000
script = json.load(open(f"{HERE}/script.json"))
db = json.load(open(f"{HERE}/build/takes.json"))

# pacing (seconds)
START = 3.4            # first line after the lantern has lit
GAP_IN_SCENE = 0.45
GAP_SCENE = 1.1
EXTRA_BEFORE = {"private": 0.6, "outro": 1.0}   # breathing room before these scenes
SCENE_LEAD = 0.9       # scene visuals start this much before its first line
TAIL = 5.5             # music/visual tail after last line

# words whose spoken time drives on-screen highlights (matched against the ASR transcript, spaces removed)
CUES = {
    "L01": {"lantern": "랜턴", "knowledge": "지식", "lit": "켜지", "ondevice": "온디바이스", "agent": "에이전트"},
    "L02": {"apple": "애플", "json": "제이슨", "device": "기기안"},
    "L03": {"network": "네트워크", "zero": "번도", "docs": "문서도", "chats": "대화도", "leave": "떠나"},
    "L04": {"small": "작은", "rag": "[래레]그", "kg": "지식", "sg": "상태", "mcp": "엠[씨시]피", "harness": "하네스", "fill": "채웁"},
    "L05": {"fast": "빠른", "once": "한번", "direct": "바로", "time": "약"},
    "L06": {"deep": "심층", "rewrite": "다시", "grade": "근거", "verify": "검증", "time": "약"},
    "L07": {"langgraph": "랭", "eleven": "(11|열한)", "cond": "조건부", "trace": "추적"},
    "L08": {"hybrid": "하이브리드", "embed": "[임인]베딩", "cosine": "코", "keyword": "키워드", "pick": "고릅"},
    "L09": {"best": "최고", "thresh": "(045|영점사오|0\\.45)", "gap": "지식이", "judge": "판단"},
    "L10": {"subj": "주어", "pred": "술어", "obj": "목적어", "triple": "트리플", "neighbor": "이웃", "evidence": "근거"},
    "L11": {"gap": "지식이", "deep": "심층", "mcp": "엠[씨시]피", "tool": "도구", "call": "호출"},
    "L12": {"learned": "알아낸", "store": "저장", "next": "다음", "local": "기기"},
    "L13": {"harness": "하네스", "persona": "페르소나", "rules": "규칙", "cite": "출처번호", "ghost": "없는", "catch": "찾아", "rewrite": "다시"},
    "L14": {"image": "이미지", "sees": "직접", "voice": "말로", "transcribe": "받아"},
    "L15": {"mine": "내지식", "lamp": "등불", "lantern": "랜턴"},
}


def trim(a, sr, thr_db=-42, head=0.05, tail=0.16):
    env = np.abs(a)
    win = int(sr * 0.01)
    if len(env) > win:
        env = np.convolve(env, np.ones(win) / win, mode="same")
    thr = 10 ** (thr_db / 20)
    idx = np.where(env > thr)[0]
    if len(idx) == 0:
        return a, 0.0
    s = max(0, idx[0] - int(head * sr))
    e = min(len(a), idx[-1] + int(tail * sr))
    return a[s:e], s / sr


def asr_char_times(path):
    rec = get_rec()
    a, sr = sf.read(path, dtype="float32")
    st = rec.create_stream()
    st.accept_waveform(sr, a)
    rec.decode_stream(st)
    chars, times = [], []
    for tok, t in zip(st.result.tokens, st.result.timestamps):
        for ch in tok.replace(" ", ""):
            chars.append(ch)
            times.append(t)
    return "".join(chars), times


def find_cues(line_id, path, offset, dur, say):
    text, times = asr_char_times(path)
    cues = {}
    plain = re.sub(r"\s", "", say)
    for name, pat in CUES.get(line_id, {}).items():
        m = re.search(pat, text)
        if m:
            t = times[m.start()] - offset
        else:  # fall back to the position in the script text
            m2 = re.search(pat, plain)
            frac = (m2.start() / max(1, len(plain))) if m2 else 0.5
            t = frac * dur
            print(f"  [cue fallback] {line_id}.{name}")
        cues[name] = round(max(0.0, min(dur, t)), 3)
    return cues


def main():
    lines_out, scenes_out = [], []
    t = START
    track = []
    for si, scene in enumerate(script["scenes"]):
        if si > 0:
            t += GAP_SCENE + EXTRA_BEFORE.get(scene["id"], 0.0)
        scene_start = t - SCENE_LEAD if si > 0 else 0.0
        for li, line in enumerate(scene["lines"]):
            if li > 0:
                t += GAP_IN_SCENE
            take = db[line["id"]]["chosen"]
            a, sr = sf.read(take["file"], dtype="float32")
            a, off = trim(a, sr)
            if sr != SR:
                a = resample_poly(a, SR, sr).astype(np.float32)
            dur = len(a) / SR
            cues = find_cues(line["id"], take["file"], off, dur, line["say"])
            track.append((t, a))
            lines_out.append(dict(id=line["id"], scene=scene["id"], start=round(t, 3), end=round(t + dur, 3),
                                  cap=line["cap"], cues={k: round(t + v, 3) for k, v in cues.items()}))
            print(f"{line['id']} {t:7.2f} → {t + dur:7.2f}  ({dur:.2f}s)  cues {cues}")
            t += dur
        scenes_out.append(dict(id=scene["id"], chapter=scene.get("chapter", ""), start=round(scene_start, 3)))

    total = t + TAIL
    for i, s in enumerate(scenes_out):
        s["end"] = scenes_out[i + 1]["start"] if i + 1 < len(scenes_out) else round(total, 3)

    out = np.zeros(int(total * SR) + SR, dtype=np.float32)
    for st, a in track:
        i = int(round(st * SR))
        out[i:i + len(a)] += a
    out = out[: int(total * SR)]
    os.makedirs(f"{HERE}/build", exist_ok=True)
    sf.write(f"{HERE}/build/narration.wav", out, SR, subtype="FLOAT")
    json.dump(dict(duration=round(total, 3), scenes=scenes_out, lines=lines_out),
              open(f"{HERE}/build/timeline.json", "w"), ensure_ascii=False, indent=1)
    print(f"total {total:.2f}s")


if __name__ == "__main__":
    main()
