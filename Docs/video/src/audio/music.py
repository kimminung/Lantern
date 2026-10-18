"""Original score for the Lantern intro — "Lantern Nocturne".

Warm, slow night piece in D-flat major at 72 BPM: felt-like piano arpeggios, a warm pad, slow strings,
soft upright bass, a hushed shaker/kick pulse in the middle, and celesta sparkles that land exactly on the
visual "light-up" events exported by the renderer (build/events.json, already snapped to the 8th-note grid).

Composed here as MIDI (mido), rendered per stem with FluidSynth + MuseScore General, processed with pedalboard.
Outputs build/music.wav (48 kHz stereo) and build/music_stems/*.wav.
"""
import json
import os
import random
import subprocess
from pathlib import Path

import mido
import numpy as np
import soundfile as sf
from pedalboard import Compressor, HighpassFilter, HighShelfFilter, LowpassFilter, LowShelfFilter, Pedalboard, Reverb, Chorus

HERE = Path(__file__).resolve().parent
BUILD = HERE / "build"
STEMS = BUILD / "music_stems"
STEMS.mkdir(parents=True, exist_ok=True)
SF = os.environ.get("SOUNDFONT", "/usr/share/sounds/sf3/MuseScore_General.sf3")
SR = 48000
BPM = 72
BEAT = 60 / BPM            # 0.8333 s
BAR = 4 * BEAT             # 3.3333 s
TPB = 480

tl = json.load(open(BUILD / "timeline.json"))
EV = json.load(open(BUILD / "events.json"))["events"]
DUR = tl["duration"]
random.seed(1018)

# ------------------------------------------------------------------ harmony (MIDI note numbers)
# Db=49(Db3)  Eb=51  F=53  Gb=54  Ab=56  Bb=58  C=60
CH = {
    "Dbmaj9": dict(root=37, v=[56, 60, 63, 65], arp=[49, 56, 63, 65, 72, 65, 63, 56], top=[68, 72, 75, 77]),
    "Bbm9":   dict(root=34, v=[56, 61, 65, 72], arp=[46, 53, 61, 65, 72, 65, 61, 53], top=[65, 68, 72, 73]),
    "Gbmaj9": dict(root=30, v=[58, 61, 65, 68], arp=[42, 49, 58, 61, 65, 61, 58, 49], top=[65, 68, 70, 73]),
    "Absus":  dict(root=32, v=[58, 61, 63, 65], arp=[44, 51, 58, 61, 63, 61, 58, 51], top=[63, 65, 68, 70]),
    "Ab":     dict(root=32, v=[56, 60, 63, 66], arp=[44, 51, 56, 60, 63, 60, 56, 51], top=[63, 66, 68, 72]),
    "Fm7":    dict(root=29, v=[56, 60, 63, 65], arp=[41, 48, 56, 60, 63, 60, 56, 48], top=[63, 65, 68, 72]),
    "Ebm9":   dict(root=27, v=[54, 58, 61, 65], arp=[39, 46, 54, 58, 65, 58, 54, 46], top=[61, 65, 66, 70]),
    "Ab13":   dict(root=32, v=[54, 60, 65, 66], arp=[44, 51, 54, 60, 65, 60, 54, 51], top=[60, 65, 66, 72]),
}
# one chord per bar
PROG = (["Dbmaj9", "Dbmaj9", "Gbmaj9"] +                                   # 0-2   intro
        ["Dbmaj9", "Bbm9", "Gbmaj9", "Absus"] * 2 +                         # 3-10  A
        ["Gbmaj9", "Ab", "Fm7", "Bbm9", "Ebm9", "Ab13", "Dbmaj9", "Absus"] +  # 11-18 B
        ["Dbmaj9", "Bbm9", "Gbmaj9", "Absus", "Dbmaj9", "Bbm9", "Ebm9", "Ab13"] +  # 19-26 C
        ["Gbmaj9", "Fm7", "Ebm9", "Absus", "Ab13"] +                        # 27-31 D
        ["Dbmaj9", "Dbmaj9", "Dbmaj9"])                                    # 32-34 end
NBARS = len(PROG)


def chord_at(t):
    return CH[PROG[max(0, min(NBARS - 1, int(t // BAR)))]]


# ------------------------------------------------------------------ note helpers
class Track:
    def __init__(self, name, program, channel, volume=100, tie=False):
        self.name, self.program, self.channel, self.volume, self.tie = name, program, channel, volume, tie
        self.notes = []  # (t_on, dur, note, vel)

    def resolved(self):
        """Same pitch overlapping itself: tie (pads/strings) or re-articulate (others), so a later note-off
        never silences a re-struck note."""
        out = []
        by = {}
        for t, d, n, v in sorted(self.notes):
            by.setdefault(n, []).append([t, t + d, v])
        for n, lst in by.items():
            cur = None
            for on, off, v in lst:
                if cur and on <= cur[1]:
                    if self.tie and self.channel != 9:
                        cur[1] = max(cur[1], off)
                        continue
                    cur[1] = on - 0.006
                if cur:
                    out.append((cur[0], cur[1] - cur[0], n, cur[2]))
                cur = [on, off, v]
            if cur:
                out.append((cur[0], cur[1] - cur[0], n, cur[2]))
        return sorted(out)

    def add(self, t, dur, note, vel):
        if t < 0 or t >= DUR:
            return
        self.notes.append((t, dur, int(note), int(max(1, min(127, vel)))))

    def write(self, path):
        mid = mido.MidiFile(ticks_per_beat=TPB)
        tr = mido.MidiTrack()
        mid.tracks.append(tr)
        tr.append(mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(BPM), time=0))
        msgs = [(0, mido.Message("control_change", channel=self.channel, control=7, value=self.volume))]
        msgs.append((0, mido.Message("control_change", channel=self.channel, control=91, value=0)))
        msgs.append((0, mido.Message("control_change", channel=self.channel, control=93, value=0)))
        if self.channel != 9:
            msgs.append((0, mido.Message("program_change", channel=self.channel, program=self.program)))
        for t, d, n, v in self.resolved():
            on = int(round(t / BEAT * TPB))
            off = int(round((t + d) / BEAT * TPB))
            msgs.append((on, mido.Message("note_on", channel=self.channel, note=n, velocity=v)))
            msgs.append((max(on + 1, off), mido.Message("note_off", channel=self.channel, note=n, velocity=0)))
        msgs.sort(key=lambda x: (x[0], 0 if x[1].type == "note_off" else 1))
        last = 0
        for tick, m in msgs:
            tr.append(m.copy(time=tick - last))
            last = tick
        mid.save(path)


hum = lambda s=0.008: random.uniform(-s, s)
piano = Track("piano", 0, 0, 100)
pad = Track("pad", 89, 1, 92, tie=True)   # Pad 2 (warm)
strings = Track("strings", 49, 2, 88, tie=True)  # String Ensemble 2 (slow)
bass = Track("bass", 32, 3, 96)        # Acoustic bass
cel = Track("celesta", 8, 4, 100)      # Celesta
perc = Track("perc", 0, 9, 92)         # GM drum kit


def bar_t(b, beat=0.0):
    return b * BAR + beat * BEAT


# ------------------------------------------------------------------ arrangement
for b, name in enumerate(PROG):
    c = CH[name]
    t0 = bar_t(b)
    last_bar = b >= 32
    # pad: whole bar, every bar (swells in the intro)
    pv = 34 if b < 1 else 44 if b < 3 else 48
    if b >= 29 and b < 32:
        pv = 44
    for n in c["v"]:
        pad.add(t0 + 0.02, BAR + 0.15, n, pv)
    if b < 3:
        pad.add(t0 + 0.02, BAR + 0.15, c["root"] + 12, pv - 6)
    # piano
    if b == 0:
        pass
    elif b in (1, 2):
        # sparse: a low root and a soft high dyad on the downbeat, a lone note on beat 3
        piano.add(t0 + hum(), 3.0, c["root"] + 12, 40)
        piano.add(t0 + 0.04 + hum(), 2.6, c["top"][1], 34)
        piano.add(t0 + 0.07 + hum(), 2.6, c["top"][2], 30)
        piano.add(bar_t(b, 2.0) + hum(), 1.6, c["top"][0], 28)
    elif not last_bar:
        # gentle 8th-note arpeggio; quieter in A, a touch fuller in B/C, thinning in D
        base = 36 if b < 11 else 42 if b < 27 else 36
        for i, n in enumerate(c["arp"]):
            if b >= 29 and i % 2 == 1:
                continue  # thin out toward the end
            accent = 6 if i == 0 else (3 if i == 4 else 0)
            piano.add(bar_t(b, i * 0.5) + hum(), 0.9 if i else 1.8, n, base + accent + random.randint(-3, 3))
        if 11 <= b < 27 and b % 2 == 1:
            piano.add(bar_t(b, 3.0) + hum(), 0.8, c["top"][3], base - 4)  # a little answering note
    # bass from bar 5: root on 1, fifth/root on 3
    if 5 <= b < 32:
        bv = 50 if b < 11 else 56 if b < 27 else 48
        piano_root = c["root"] + 12 if c["root"] < 36 else c["root"]
        bass.add(t0 + hum(0.004), 1.7, piano_root, bv)
        bass.add(bar_t(b, 2.0) + hum(0.004), 1.5, piano_root + (7 if b % 2 else 0), bv - 6)
    # strings in B and C, long and low in the mix
    if 11 <= b < 31:
        sv = 40 if b < 19 else 48 if b < 27 else 38
        for n in c["top"][:3]:
            strings.add(t0 + 0.05, BAR + 0.1, n, sv)
        strings.add(t0 + 0.05, BAR + 0.1, c["root"] + 24, sv - 6)
    # hushed pulse in B and C (shaker 8ths, soft kick on 1, side-stick on 3)
    if 12 <= b < 29:
        for i in range(8):
            perc.add(bar_t(b, i * 0.5) + hum(0.006), 0.1, 82, (30 if i % 2 == 0 else 22) + random.randint(-3, 3))
        perc.add(t0, 0.2, 36, 46)
        perc.add(bar_t(b, 2.0) + hum(0.004), 0.1, 37, 30)
        if b % 4 == 3:
            perc.add(bar_t(b, 3.5), 0.1, 37, 24)

# ending: rolled Dbmaj9 on bar 32 (lands with the spoken "랜턴"), long ring
tE = bar_t(32)
for i, n in enumerate([37, 44, 53, 60, 63, 68, 72]):
    piano.add(tE + i * 0.045, 6.2, n, 46 - i)
for n in [56, 60, 63, 65, 68]:
    strings.add(tE + 0.05, 6.3, n, 40)
for i, n in enumerate([72, 75, 77, 80, 84, 89]):
    cel.add(tE + 0.4 + i * BEAT / 4, 2.5, n, 46 - i * 3)

# ------------------------------------------------------------------ sparkles on visual events
def upper(c, k):
    pool = sorted(set([n + 12 for n in c["top"]] + [n + 24 for n in c["top"][:2]]))
    return pool[k % len(pool)]


# the lantern igniting (first 2.5 s): a rising 16th arpeggio
for i, n in enumerate([73, 77, 80, 84, 87]):
    cel.add(1.25 + i * BEAT / 4, 1.8, n, 34 + i * 3)
SPEECH = [(l["start"] - 0.2, l["end"] + 0.1) for l in tl["lines"]]
in_speech = lambda t: any(a <= t <= b for a, b in SPEECH)
for e in EV:
    t, kind, i = e["t"], e["kind"], e["i"]
    c = chord_at(t + 0.01)
    soft = -7 if in_speech(t) or in_speech(t + 0.5) else 0   # keep bright sparkles from masking consonants
    ln = 1.0 if soft else 1.8
    if kind == "title":
        cel.add(t, 2.0, 80, 44 + soft)
        cel.add(t + 0.02, 2.0, 85, 40 + soft)
    elif kind == "star":
        cel.add(t, ln, upper(c, i), 42 + (i % 3) * 2 + soft)
    elif kind == "node":
        cel.add(t, min(ln, 1.2), upper(c, i), 36 + (i % 2) * 4 + soft)
    elif kind in ("kg", "result", "learn", "pass"):
        cel.add(t, ln, upper(c, 2), 44 + soft)
        cel.add(t + BEAT / 4, ln, upper(c, 4), 40 + soft)

# ------------------------------------------------------------------ render stems
tracks = [piano, pad, strings, bass, cel, perc]
for tr in tracks:
    mp = STEMS / f"{tr.name}.mid"
    tr.write(mp)
    wav = STEMS / f"{tr.name}_raw.wav"
    subprocess.run(["fluidsynth", "-ni", "-q", "-R", "0", "-C", "0", "-g", "0.7", "-r", str(SR), "-F", str(wav), SF, str(mp)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

N = int((DUR + 0.05) * SR)


def load(name):
    x, sr = sf.read(STEMS / f"{name}_raw.wav", dtype="float32", always_2d=True)
    assert sr == SR
    x = x.T
    out = np.zeros((2, N), np.float32)
    m = min(N, x.shape[1])
    out[:, :m] = x[:, :m]
    return out


FX = {
    "piano":   (Pedalboard([HighpassFilter(55), LowpassFilter(6200), LowShelfFilter(220, 1.5), Reverb(room_size=0.78, damping=0.6, wet_level=0.30, dry_level=0.78, width=0.9)]), 1.00),
    "pad":     (Pedalboard([HighpassFilter(90), LowpassFilter(5200), Chorus(rate_hz=0.25, depth=0.2, mix=0.3), Reverb(room_size=0.9, damping=0.5, wet_level=0.35, dry_level=0.7)]), 0.52),
    "strings": (Pedalboard([HighpassFilter(110), LowpassFilter(6500), Reverb(room_size=0.92, damping=0.45, wet_level=0.4, dry_level=0.65)]), 0.42),
    "bass":    (Pedalboard([HighpassFilter(38), LowpassFilter(2400), Compressor(threshold_db=-24, ratio=2.5, attack_ms=15, release_ms=200)]), 0.62),
    "celesta": (Pedalboard([HighpassFilter(300), HighShelfFilter(7000, -4.0), Reverb(room_size=0.88, damping=0.35, wet_level=0.45, dry_level=0.6, width=1.0)]), 0.50),
    "perc":    (Pedalboard([HighpassFilter(45), HighShelfFilter(8000, -5.0), Reverb(room_size=0.5, damping=0.7, wet_level=0.15, dry_level=0.85)]), 0.40),
}
mix = np.zeros((2, N), np.float32)
for tr in tracks:
    x = load(tr.name)
    fx, g = FX[tr.name]
    y = fx(x, SR)
    if tr.name == "celesta":  # a slight stereo spread for the sparkles
        y[0] *= 1.08; y[1] *= 0.92
    sf.write(STEMS / f"{tr.name}.wav", (y * g).T, SR, subtype="FLOAT")
    mix += y * g

# gentle glue + fades
mix = Pedalboard([Compressor(threshold_db=-20, ratio=1.8, attack_ms=40, release_ms=400)])(mix, SR)
fi = int(2.2 * SR)
mix[:, :fi] *= np.linspace(0, 1, fi)
fo0 = int((DUR - 2.8) * SR)
mix[:, fo0:] *= np.linspace(1, 0, N - fo0) ** 1.5
peak = float(np.abs(mix).max())
mix *= 0.5 / max(peak, 1e-6)  # leave level decisions to mix.py
sf.write(BUILD / "music.wav", mix.T, SR, subtype="FLOAT")
print(f"music.wav {DUR:.2f}s  bars {NBARS}  events {len(EV)}  raw peak {peak:.3f}")
