#!/usr/bin/env bash
# TCP listener: accepts a raw s16le mono 48kHz audio stream from the Windows
# sender, writes it into the 'virtmic' PulseAudio sink. The 'WindowsMic'
# remap-source then exposes that audio as a regular Linux input device.
#
# Reconnect loop is the inner safety net; the windowsmic-watchdog.service is
# the outer one (detects stuck-but-alive streams from a frozen Windows dshow
# handle and bounces this listener).

set -u

# Optional config (sets PORT, etc.). Created by the user, NOT in this repo.
[ -f "$HOME/.config/windowsmic-bridge/config.env" ] && \
    . "$HOME/.config/windowsmic-bridge/config.env"

PORT="${PORT:-9999}"

export PULSE_SERVER="${PULSE_SERVER:-unix:/run/user/$(id -u)/pulse/native}"

while true; do
  echo "[$(date +%H:%M:%S)] waiting for Windows ffmpeg on tcp/$PORT ..."
  ffmpeg -hide_banner -loglevel warning \
    -f s16le -ar 48000 -ac 1 \
    -i "tcp://0.0.0.0:${PORT}?listen=1" \
    -f pulse -device virtmic "WindowsMic-Stream"
  echo "[$(date +%H:%M:%S)] stream ended, restarting listener in 1s"
  sleep 1
done
