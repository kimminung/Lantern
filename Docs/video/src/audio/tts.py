"""Korean TTS with Supertonic 3 (sherpa-onnx). Module or CLI: python3 tts.py "text" out.wav [sid]"""
import os, sys, json, time
import numpy as np
import soundfile as sf
import sherpa_onnx

MODEL_DIR = os.environ.get(
    "ST3_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "models", "sherpa-onnx-supertonic-3-tts-int8-2026-05-11")
)
_tts = None


def get_tts():
    global _tts
    if _tts is None:
        m = MODEL_DIR
        cfg = sherpa_onnx.OfflineTtsConfig(
            model=sherpa_onnx.OfflineTtsModelConfig(
                supertonic=sherpa_onnx.OfflineTtsSupertonicModelConfig(
                    duration_predictor=f"{m}/duration_predictor.int8.onnx",
                    text_encoder=f"{m}/text_encoder.int8.onnx",
                    vector_estimator=f"{m}/vector_estimator.int8.onnx",
                    vocoder=f"{m}/vocoder.int8.onnx",
                    tts_json=f"{m}/tts.json",
                    unicode_indexer=f"{m}/unicode_indexer.bin",
                    voice_style=f"{m}/voice.bin",
                ),
                debug=False,
                num_threads=2,
                provider="cpu",
            )
        )
        assert cfg.validate()
        _tts = sherpa_onnx.OfflineTts(cfg)
    return _tts


def synth(text, out_path, sid=0, speed=1.0, steps=8, seed=None, lang="ko"):
    tts = get_tts()
    g = sherpa_onnx.GenerationConfig()
    g.sid = sid
    g.num_steps = steps
    g.speed = speed
    g.extra["lang"] = lang
    if seed is not None:
        g.extra["seed"] = str(seed)
    t0 = time.time()
    audio = tts.generate(text, g)
    el = time.time() - t0
    samples = np.asarray(audio.samples, dtype=np.float32)
    sf.write(out_path, samples, audio.sample_rate, subtype="PCM_16")
    return len(samples) / audio.sample_rate, audio.sample_rate, el


if __name__ == "__main__":
    text, out = sys.argv[1], sys.argv[2]
    sid = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    d, sr, el = synth(text, out, sid=sid)
    print(json.dumps({"dur": d, "sr": sr, "elapsed": el}))
