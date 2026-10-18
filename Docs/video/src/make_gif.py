"""Compose the README GIF from render_gif.js frames: short crossfades between segments, a seamless loop
back to the first frame, downscale, then palette GIF with ffmpeg (+ gifsicle if present).
usage: python3 make_gif.py <framesDir> <out.gif> [width=1120] [colors=128]"""
import json, os, shutil, subprocess, sys, tempfile
from PIL import Image

src, out = sys.argv[1], sys.argv[2]
W = int(sys.argv[3]) if len(sys.argv) > 3 else 1120
COLORS = int(sys.argv[4]) if len(sys.argv) > 4 else 128
meta = json.load(open(os.path.join(src, "segments.json")))
FPS = meta["fps"]
H = round(W * 1080 / 1920 / 2) * 2
XF = 3      # frames to dip out / in between segments (through the night-sky colour, no double exposure)
LOOP = 5    # the tail dips to the sky colour; frame 0 (the title) then "lights up" again


def load(si, f):
    return Image.open(os.path.join(src, f"s{si:02d}_{f:04d}.png")).convert("RGB").resize((W, H), Image.LANCZOS)


SKY = Image.new("RGB", (W, H), (6, 15, 26))
seq = []
for k, s in enumerate(meta["segments"]):
    frames = [load(s["i"], f) for f in range(s["frames"])]
    if seq:
        for j in range(XF):  # previous segment fades down, this one fades up
            seq[-XF + j] = Image.blend(seq[-XF + j], SKY, (j + 1) / (XF + 1))
            frames[j] = Image.blend(SKY, frames[j], (j + 1) / (XF + 1))
    seq.extend(frames)
for j in range(LOOP):
    seq[-LOOP + j] = Image.blend(seq[-LOOP + j], SKY, (j + 1) / (LOOP + 1))

tmp = tempfile.mkdtemp(prefix="gif_")
for i, im in enumerate(seq):
    im.save(os.path.join(tmp, f"{i:05d}.png"))
pal = os.path.join(tmp, "pal.png")
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(FPS), "-i", os.path.join(tmp, "%05d.png"),
                "-vf", f"palettegen=max_colors={COLORS}:stats_mode=full:reserve_transparent=0", pal], check=True)
raw = out if not shutil.which("gifsicle") else out + ".raw.gif"
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(FPS), "-i", os.path.join(tmp, "%05d.png"), "-i", pal,
                "-lavfi", "paletteuse=dither=none:diff_mode=rectangle", "-loop", "0", raw], check=True)
if raw != out:
    subprocess.run(["gifsicle", "-O3", "--lossy=8", "-o", out, raw], check=True)
    os.remove(raw)
shutil.rmtree(tmp)
print(f"{out}: {len(seq)} frames, {len(seq) / FPS:.1f}s, {W}x{H}, {os.path.getsize(out) / 1e6:.2f} MB")
