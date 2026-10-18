"""Re-pick each line's take by how well the ASR understands it *on top of the real ducked music*.
Takes of one line share the same length, so the timeline does not move."""
import json, sys
from pathlib import Path
import numpy as np, soundfile as sf, pyloudnorm as pyln
from scipy.signal import resample_poly
from pedalboard import Compressor, HighpassFilter, PeakFilter, Pedalboard
HERE = Path(__file__).resolve().parent; BUILD = HERE / "build"
sys.path.insert(0, str(HERE))
import asr
from build_narration import trim
SR = 48000
meter = pyln.Meter(SR)
fx = Pedalboard([HighpassFilter(cutoff_frequency_hz=75), PeakFilter(cutoff_frequency_hz=200, gain_db=-1.2, q=0.9),
                 PeakFilter(cutoff_frequency_hz=3300, gain_db=1.8, q=0.8), Compressor(threshold_db=-22, ratio=2.2, attack_ms=8, release_ms=120)])
tl = json.load(open(BUILD / "timeline.json")); db = json.load(open(BUILD / "takes.json"))
mus, _ = sf.read(BUILD / "music_ducked.wav", dtype="float32", always_2d=True); mus = mus.mean(1)
gain = float(sys.argv[1])
changed = 0
for l in tl["lines"]:
    d = db[l["id"]]
    i0 = int(l["start"] * SR)
    res = []
    for tk in d["takes"]:
        x, sr = sf.read(tk["file"], dtype="float32")
        y, off = trim(x, sr)
        y = resample_poly(y, SR, sr).astype(np.float32)
        y = fx(y[None, :], SR)[0]
        lo = meter.integrated_loudness(np.concatenate([y, np.zeros(int(0.5 * SR), np.float32)]))
        y = y * 10 ** ((-19 - lo) / 20) * gain
        cs = []
        for ctx in (0.1, 0.3):
            a = i0 - int(ctx * SR)
            seg = mus[a: a + len(y) + int((ctx + 0.1) * SR)].copy()
            seg[int(ctx * SR): int(ctx * SR) + len(y)] += y[: len(seg) - int(ctx * SR)]
            st = asr.get_rec().create_stream(); st.accept_waveform(SR, seg); asr.get_rec().decode_stream(st)
            cs.append(min(asr.cer(d["say"], st.result.text), asr.cer(d["cap"], st.result.text)))
        res.append((round(max(cs), 4), round(tk["cer"], 4), tk["seed"], tk))
    res.sort(key=lambda r: (r[0], r[1]))
    best = res[0][3]
    if best["seed"] != d["chosen"]["seed"]:
        changed += 1
        print(f"{l['id']}: seed {d['chosen']['seed']} → {best['seed']}  (under-music CER {res[0][0]})")
    d["chosen"] = best
    print(l["id"], [(r[2], r[0]) for r in res])
json.dump(db, open(BUILD / "takes.json", "w"), ensure_ascii=False, indent=1)
print("changed", changed)
