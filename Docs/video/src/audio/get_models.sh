#!/usr/bin/env bash
# Supertonic 3 (Korean TTS, MIT code) and SenseVoice (ASR pronunciation check) for sherpa-onnx
set -euo pipefail
cd "$(dirname "$0")" && mkdir -p models && cd models
B=https://github.com/k2-fsa/sherpa-onnx/releases/download
[ -d sherpa-onnx-supertonic-3-tts-int8-2026-05-11 ] || curl -sSL "$B/tts-models/sherpa-onnx-supertonic-3-tts-int8-2026-05-11.tar.bz2" | tar xj
[ -d sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17 ] || curl -sSL "$B/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2" | tar xj
ls
