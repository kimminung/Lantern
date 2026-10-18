"""Narration + ducked music → build/mix.wav (-16 LUFS integrated, ≤ -1 dBTP).

- narration: high-pass, light EQ, gentle compression, every line levelled to -19 LUFS
- music: sits ~5 dB under the voice level in the gaps and ducks under speech
  (-9 dB broadband plus a further -4 dB above 1.2 kHz, slow release so short gaps don't pump)
"""
import json
from pathlib import Path

import numpy as np
import pyloudnorm as pyln
import soundfile as sf
from pedalboard import Compressor, HighpassFilter, PeakFilter, Pedalboard
from scipy.ndimage import maximum_filter1d
from scipy.signal import butter, resample_poly, sosfiltfilt

HERE = Path(__file__).resolve().parent
BUILD = HERE / "build"
SR = 48000
tl = json.load(open(BUILD / "timeline.json"))
meter = pyln.Meter(SR)

# ---------------------------------------------------------------- narration
nar, sr = sf.read(BUILD / "narration.wav", dtype="float32")
assert sr == SR
voice_fx = Pedalboard([
    HighpassFilter(cutoff_frequency_hz=75),
    PeakFilter(cutoff_frequency_hz=200, gain_db=-1.2, q=0.9),
    PeakFilter(cutoff_frequency_hz=3300, gain_db=1.8, q=0.8),
    Compressor(threshold_db=-22, ratio=2.2, attack_ms=8, release_ms=120),
])
nar = voice_fx(nar[None, :], SR)[0]
for l in tl["lines"]:
    a, b = int((l["start"] - 0.05) * SR), int((l["end"] + 0.1) * SR)
    seg = nar[a:b]
    loud = meter.integrated_loudness(np.concatenate([seg, np.zeros(int(0.5 * SR), np.float32)]))
    nar[a:b] = seg * 10 ** ((-19.0 - loud) / 20)

# ---------------------------------------------------------------- music + ducking
mus, sr = sf.read(BUILD / "music.wav", dtype="float32", always_2d=True)
mus = mus.T
N = max(len(nar), mus.shape[1])
nar = np.pad(nar, (0, N - len(nar)))
mus = np.pad(mus, ((0, 0), (0, N - mus.shape[1])))
mloud = meter.integrated_loudness(mus.T)
mus *= 10 ** ((-24.0 - mloud) / 20)

# speech activity 0..1 from the narration envelope: fast attack, hold, slow release
hop = 240  # 5 ms
n = N // hop
env = np.sqrt((nar[: n * hop].reshape(n, hop) ** 2).mean(1))
act = (env > 10 ** (-42 / 20)).astype(np.float32)
act = maximum_filter1d(act, size=int(0.45 / 0.005))      # hold ~0.45 s across word gaps
sm = np.zeros_like(act)
a_up, a_dn = np.exp(-0.005 / 0.08), np.exp(-0.005 / 0.9)
v = 0.0
for i, x in enumerate(act):
    v = a_up * v + (1 - a_up) * x if x > v else a_dn * v + (1 - a_dn) * x
    sm[i] = v
duck = np.repeat(sm, hop)
duck = np.pad(duck, (0, N - len(duck)), mode="edge")
g_all = 10 ** (-9.0 * duck / 20)
g_hi = 10 ** (-4.0 * duck / 20)
sos_lo = butter(4, 1200, "low", fs=SR, output="sos")
sos_hi = butter(4, 1200, "high", fs=SR, output="sos")
lo = sosfiltfilt(sos_lo, mus, axis=1)
hi = sosfiltfilt(sos_hi, mus, axis=1)
mus_d = (lo + hi * g_hi) * g_all

# ---------------------------------------------------------------- sum, loudness, true-peak limit
mix = mus_d + nar[None, :]
loud = meter.integrated_loudness(mix.T)
mix *= 10 ** ((-16.0 - loud) / 20)


def true_peak(x):
    up = resample_poly(x, 4, 1, axis=1)
    return float(np.abs(up).max())


ceiling = 10 ** (-1.2 / 20)
tp = true_peak(mix)
if tp > ceiling:
    # look-ahead limiter on the 4x-oversampled peak envelope
    up = np.abs(resample_poly(mix, 4, 1, axis=1)).max(0)
    pk = up.reshape(-1, 4).max(1)[:N] if len(up) >= 4 * N else np.pad(up, (0, 4 * N - len(up))).reshape(-1, 4).max(1)
    need = np.minimum(1.0, ceiling / np.maximum(pk, 1e-9))
    la = int(0.004 * SR)
    need = -maximum_filter1d(-need, size=2 * la + 1)
    g = np.empty_like(need)
    rel = np.exp(-1 / (0.08 * SR))
    cur = 1.0
    for i, x in enumerate(need):
        cur = x if x < cur else rel * cur + (1 - rel) * x
        g[i] = cur
    mix *= g[None, :]
print(f"mix: {loud:.1f} → {meter.integrated_loudness(mix.T):.1f} LUFS, true peak {20 * np.log10(true_peak(mix)):.2f} dBTP")
sf.write(BUILD / "mix.wav", mix.T, SR, subtype="PCM_24")
sf.write(BUILD / "voice_only.wav", (nar * 10 ** ((-16.0 - loud) / 20)), SR, subtype="PCM_24")
sf.write(BUILD / "music_ducked.wav", (mus_d * 10 ** ((-16.0 - loud) / 20)).T, SR, subtype="FLOAT")
print("gain", 10 ** ((-16.0 - loud) / 20))
