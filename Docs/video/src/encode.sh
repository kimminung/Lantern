#!/usr/bin/env bash
# Final MP4 for the README: master video + mixed audio → H.264/AAC, two-pass, sized under GitHub's 10 MB limit.
# usage: ./encode.sh <master.mkv> <mix.wav|m4a> <out.mp4> [video_kbps=580]
set -euo pipefail
MASTER=$1; AUDIO=$2; OUT=$3; VK=${4:-580}
TMP=$(mktemp -d)
ffmpeg -y -loglevel error -i "$MASTER" -c:v libx264 -preset slow -profile:v high -pix_fmt yuv420p -b:v ${VK}k \
  -g 150 -keyint_min 30 -tune animation -pass 1 -passlogfile "$TMP/x264" -an -f mp4 /dev/null
ffmpeg -y -loglevel error -i "$MASTER" -i "$AUDIO" -map 0:v -map 1:a -c:v libx264 -preset slow -profile:v high -pix_fmt yuv420p \
  -b:v ${VK}k -g 150 -keyint_min 30 -tune animation -pass 2 -passlogfile "$TMP/x264" \
  -c:a aac -b:a 96k -ar 48000 -ac 2 -shortest -movflags +faststart \
  -metadata title="Lantern — 온디바이스 RAG 에이전트" "$OUT"
rm -rf "$TMP"
ls -la "$OUT"
