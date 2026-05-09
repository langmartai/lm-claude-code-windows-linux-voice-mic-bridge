#!/usr/bin/env bash
# Linux->Windows playback exporter.
# Pulls the WindowsSpeakers.monitor source and serves it on TCP for a
# Windows ffplay client to connect to.
#
# Direction inversion vs the mic side: there are potentially N Linux hosts
# but only one Windows playback sink, so each Linux runs a TCP server and
# Windows dials in (via ffplay). On client disconnect ffmpeg exits with EOF
# and the outer loop relistens.

set -u

[ -f "$HOME/.config/windowsmic-bridge/config.env" ] && \
    . "$HOME/.config/windowsmic-bridge/config.env"

EXPORT_PORT="${EXPORT_PORT:-10000}"
SPEAKERS_SINK="${SPEAKERS_SINK:-WindowsSpeakers}"

export PULSE_SERVER="${PULSE_SERVER:-unix:/run/user/$(id -u)/pulse/native}"

while true; do
  echo "[$(date +%H:%M:%S)] waiting for Windows on tcp/$EXPORT_PORT (sink=$SPEAKERS_SINK) ..."
  ffmpeg -hide_banner -loglevel warning \
    -f pulse -i "${SPEAKERS_SINK}.monitor" \
    -ac 2 -ar 48000 \
    -f s16le "tcp://0.0.0.0:${EXPORT_PORT}?listen=1"
  echo "[$(date +%H:%M:%S)] connection ended, relistening in 1s"
  sleep 1
done
