#!/usr/bin/env bash
# Source-level watchdog for the Windows mic bridge.
#
# Failure mode it detects: when the Windows audio device disconnects/reconnects
# (USB hot-plug, audio-engine reset), Windows ffmpeg can keep its dshow handle
# in a zombie state — process alive, TCP socket alive, but only zero-filled
# buffers ever leave it. The PowerShell while-loop never sees an exit, so it
# never respawns ffmpeg. The stream is dead and stays dead until something
# breaks the zombie.
#
# Recovery: every CHECK_INTERVAL seconds, this watchdog samples the WindowsMic
# source and checks the peak amplitude. After SILENT_LIMIT consecutive zero
# peaks WHILE the inbound TCP is established, it (1) SSH-kills the hung
# Windows ffmpeg so the PowerShell loop respawns it with a fresh dshow handle,
# (2) restarts the local listener service so it accepts the new connection.
#
# Why peak == 0 (not "below -60dB"): a real AG06 idle has a noise floor around
# -65 to -75 dBFS. Triggering only on TRUE digital zeros means a quiet room
# never trips this — only a wedged stream does.
#
# Why the TCP-state guard: when no Windows side is connected, the null-sink
# monitor produces digital zeros too. Without the guard, the watchdog would
# spuriously bounce the listener every cycle while Windows is offline.

set -u

# Optional config — created by the user, NOT in this repo.
# Must define WIN_HOST (e.g. user@host) and WIN_KEY (path to SSH private key)
# for the SSH-kill behavior. Without it, the watchdog only restarts the local
# listener; the hung Windows ffmpeg has to be killed manually.
[ -f "$HOME/.config/windowsmic-bridge/config.env" ] && \
    . "$HOME/.config/windowsmic-bridge/config.env"

CHECK_INTERVAL="${CHECK_INTERVAL:-15}"
SILENT_LIMIT="${SILENT_LIMIT:-3}"
SAMPLE_SEC="${SAMPLE_SEC:-3.0}"
SKIP_HEAD_SEC="${SKIP_HEAD_SEC:-1.0}"
DEVICE="${DEVICE:-WindowsMic}"
PORT="${PORT:-9999}"
LISTENER_UNIT="${LISTENER_UNIT:-windowsmic-listen.service}"
WIN_HOST="${WIN_HOST:-}"
WIN_KEY="${WIN_KEY:-}"

export PULSE_SERVER="${PULSE_SERVER:-unix:/run/user/$(id -u)/pulse/native}"

silent_streak=0

is_windows_connected() {
  ss -tn state established "( sport = :${PORT} )" 2>/dev/null | grep -q ':'
}

kill_windows_ffmpeg() {
  if [ -z "$WIN_HOST" ] || [ -z "$WIN_KEY" ]; then
    echo "[$(date +%H:%M:%S)] WARN: WIN_HOST/WIN_KEY unset — cannot SSH-kill hung Windows ffmpeg"
    return 1
  fi
  ssh -i "$WIN_KEY" -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$WIN_HOST" \
      'powershell -Command "Get-Process ffmpeg -ErrorAction SilentlyContinue | Stop-Process -Force"' \
      >/dev/null 2>&1
}

while true; do
  sleep "$CHECK_INTERVAL"

  if ! systemctl --user is-active --quiet "$LISTENER_UNIT"; then
    echo "[$(date +%H:%M:%S)] listener inactive, skipping check"
    silent_streak=0
    continue
  fi

  if ! is_windows_connected; then
    [ "$silent_streak" -gt 0 ] && echo "[$(date +%H:%M:%S)] Windows disconnected — silence is expected, streak reset"
    silent_streak=0
    continue
  fi

  tmp=$(mktemp /tmp/windowsmic-watch.XXXXXX.wav)
  timeout "$(awk "BEGIN{print $SAMPLE_SEC + 0.5}")" \
      parecord --device="$DEVICE" --file-format=wav "$tmp" >/dev/null 2>&1 || true

  peak=$(python3 - "$tmp" "$SKIP_HEAD_SEC" <<'PY' 2>/dev/null
import sys, wave, struct
try:
    w = wave.open(sys.argv[1], 'rb')
    skip_frames = int(float(sys.argv[2]) * w.getframerate())
    total = w.getnframes()
    if total <= skip_frames:
        print(-1)
        sys.exit()
    w.setpos(skip_frames)
    frames = w.readframes(total - skip_frames)
    samples = struct.unpack('<' + 'h' * (len(frames) // 2), frames) if frames else []
    print(max((abs(s) for s in samples), default=0))
except Exception:
    print(-1)
PY
)
  rm -f "$tmp"

  case "$peak" in
    -1)
      echo "[$(date +%H:%M:%S)] could not read sample — recording failed"
      silent_streak=0
      ;;
    0)
      silent_streak=$((silent_streak + 1))
      echo "[$(date +%H:%M:%S)] digital silence detected (streak=$silent_streak/$SILENT_LIMIT)"
      if [ "$silent_streak" -ge "$SILENT_LIMIT" ]; then
        echo "[$(date +%H:%M:%S)] BOUNCING — kill hung Windows ffmpeg + restart listener"
        kill_windows_ffmpeg || echo "[$(date +%H:%M:%S)] (continuing without SSH-kill)"
        systemctl --user restart "$LISTENER_UNIT"
        silent_streak=0
        sleep 10
      fi
      ;;
    *)
      [ "$silent_streak" -gt 0 ] && echo "[$(date +%H:%M:%S)] audio recovered (peak=$peak), streak reset"
      silent_streak=0
      ;;
  esac
done
