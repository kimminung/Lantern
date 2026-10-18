"""Generate several TTS takes per script line and keep the one the ASR understands best.

usage: python3 takes.py [n_takes] [sid] [speed]
writes build/takes/<line>_<seed>.wav and build/takes.json (all scores + chosen take per line)
"""
import sys, json, os
import numpy as np
import parselmouth

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tts import synth
from asr import transcribe, cer

N = int(sys.argv[1]) if len(sys.argv) > 1 else 6
SID = int(sys.argv[2]) if len(sys.argv) > 2 else 4
SPEED = float(sys.argv[3]) if len(sys.argv) > 3 else 0.97
ONLY = set(sys.argv[4].split(",")) if len(sys.argv) > 4 else None

os.makedirs(f"{HERE}/build/takes", exist_ok=True)
script = json.load(open(f"{HERE}/script.json"))
lines = [l for s in script["scenes"] for l in s["lines"]]
db_path = f"{HERE}/build/takes.json"
db = json.load(open(db_path)) if os.path.exists(db_path) else {}

for l in lines:
    if ONLY and l["id"] not in ONLY:
        continue
    rows = []
    for seed in range(1, N + 1):
        f = f"{HERE}/build/takes/{l['id']}_{seed}.wav"
        d, sr, _ = synth(l["say"], f, sid=SID, speed=SPEED, steps=8, seed=seed)
        hyp = transcribe(f)
        c = min(cer(l["say"], hyp), cer(l["cap"], hyp))
        p = parselmouth.Sound(f).to_pitch(time_step=0.01, pitch_floor=60, pitch_ceiling=500).selected_array["frequency"]
        p = p[p > 0]
        sd = float(np.std(12 * np.log2(p / np.median(p)))) if len(p) else 0.0
        rows.append(dict(seed=seed, file=f, dur=round(d, 3), cer=round(c, 4), f0sd=round(sd, 2), hyp=hyp))
    med = float(np.median([r["dur"] for r in rows]))
    # lowest CER first; then closest to the median duration (no rushed/dragging takes); then more pitch movement
    rows.sort(key=lambda r: (round(r["cer"], 3), abs(r["dur"] - med) / med > 0.06, -r["f0sd"]))
    db[l["id"]] = dict(say=l["say"], cap=l["cap"], sid=SID, speed=SPEED, chosen=rows[0], takes=rows)
    print(f"{l['id']}  best seed {rows[0]['seed']}  cer {rows[0]['cer']:.3f}  dur {rows[0]['dur']:.2f}s  | {rows[0]['hyp']}", flush=True)
    json.dump(db, open(db_path, "w"), ensure_ascii=False, indent=1)
