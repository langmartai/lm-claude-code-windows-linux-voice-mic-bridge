# lm-claude-code-windows-linux-voice-mic-bridge

Bidirectional audio bridge between a Windows host and one or more Linux
hosts over raw TCP, with no SSH tunnel and no audio session in the middle.

- **Mic**: Windows microphone → all Linux hosts. Each Linux exposes the
  stream as a regular PulseAudio input device (`WindowsMic`, the default
  source) — Claude Code voice input, browsers, STT tools record from it.
- **Speakers**: each Linux's audio output → Windows speakers. Linux
  apps play to the `WindowsSpeakers` PulseAudio sink (default sink); a
  Windows ffplay client per host plays the stream to the default Windows
  playback device. The Windows audio engine mixes N hosts natively.

## Primary use case: Claude Code `/voice` from a remote Linux box

You're on Windows, SSHed into an Ubuntu (or other Linux) machine. You run
Claude Code in that SSH session and want to use the `/voice` command — but
your microphone is on Windows, and Claude Code needs a *local Linux* audio
input device to record from. SSH carries no audio, so Claude Code sees no
microphones at all on the Linux side.

This bridge fixes it. Once installed:

1. Windows streams its mic to the Linux box over raw TCP on the same LAN /
   Hyper-V virtual switch.
2. PulseAudio on Linux exposes the incoming stream as a regular input
   source named `WindowsMic`, set as the **system default**.
3. Inside your SSH'd Claude Code session, `/voice` records from the default
   mic — which is now your Windows mic — with zero extra config.

To you it feels like the mic is plugged directly into the Linux box. The
same setup works for any Linux app that records from the default mic
(browser STT, `whisper.cpp`, `nerd-dictation`, OBS, etc.).

Design choices flow from this use case:

- **Direct TCP, no SSH tunnel** — both hosts are typically on the same LAN
  or Hyper-V virtual switch, so encryption is wasted overhead and adds
  latency.
- **PulseAudio default source** — so `/voice` and other apps need no
  per-tool device configuration.
- **Aggressive auto-recovery** — voice input has to "just work" when you
  hit `/voice`. The status-endpoint design (below) handles the case where
  Windows dshow goes zombie after a USB mic disconnect-reconnect, so you
  don't have to notice or manually intervene.

### Why not RDP audio redirection?

RDP carries audio natively, but you'd be in a remote desktop session, not
an SSH terminal — different workflow. This bridge keeps you in your
existing SSH terminal and just makes the mic show up.

## Architecture

### Mic flow (Windows → Linux, fan-out to N hosts)

```
Windows host                                    Linux host(s) — N >= 1
─────────────                                   ───────────────────────────
USB mic ──┐                                     ┌── PulseAudio
          │                                     │
       dshow                                    │   sink:   virtmic
          │                                     │            │ (monitor)
       ffmpeg ──┬── raw s16le ──tcp:9999────►   ffmpeg ──────┤
       (tee)    │                                             │
                │                                 source: WindowsMic ◄── apps
                │                                             │
                │                                 health daemon
                │                                             │
                └── ... fan out to N targets   ◄── GET /health (tcp:9998)
                                                             ▲
                                                             │ poll every 15s
                                                             │
       windowsmic-monitor.ps1 ◄───── reads zombie_likely ────┘
       (kills local ffmpeg if any target reports zombie)
```

Symmetric: `windowsmic-health.ps1` also exposes `GET /health` on tcp:9998
on the Windows side, mirroring the Linux endpoint for human inspection.

### Speakers flow (Linux → Windows, mixed at Windows default sink)

```
Windows host                                    Linux host(s) — N >= 1
─────────────                                   ───────────────────────────
Default speakers                                Linux apps
  ▲                                                  │
  │                                                  ▼
  ffplay (SDL2) ───┐                          PulseAudio
  ffplay (SDL2) ───┼── raw s16le ◄──tcp:10000───  ffmpeg
  ...              │                              (listen=1)
  one per target  │                                  ▲
                   │                                  │ monitor
                   ▼                                  │
        Windows audio engine               sink: WindowsSpeakers ◄── apps
        (native mix of N streams)
```

Each Linux exposes its `WindowsSpeakers.monitor` as a TCP server. Windows
runs one ffplay per target — each dials in, receives raw s16le, plays via
SDL2 to the default playback device. The Windows audio engine mixes the
streams natively. No filter graph, no `amix`, just native multi-stream.

**Multi-target (since v0.3):** Windows ffmpeg uses the `tee` muxer to fan
out a single dshow capture to multiple Linux receivers (`onfail=ignore`
per output, so a dead receiver doesn't stall the others). Each Linux
receiver runs an independent listener + health daemon. Add a host = add
an entry to `$LinuxTargets` and bounce the streamer task.

Each side observes only what it can cheaply see, exposes truthful state
on `/health`, and acts only on its own resources. No SSH key crosses
hosts.

## Failure modes handled

| Failure | Recovery layer | Time |
|---|---|---|
| Linux listener crashes | systemd `Restart=always` | 2s |
| Linux health daemon crashes | systemd `Restart=always` | 5s |
| Windows ffmpeg crashes | PowerShell `while($true)` reconnect loop | 1s |
| Windows scheduled task crashes | Task `RestartCount=999` / 1-min interval | 60s |
| Windows streamer's detached child PS dies | `WindowsMicGuardian` task (60s tick) | 60-90s |
| TCP drops | inner reconnect loops on both sides | 1–2s |
| Windows enum index shifts (`(3-` → `(4-`) on USB replug | PS1 re-resolves device name by pattern every iteration | next loop |
| **Sound card disconnect → Windows ffmpeg goes zombie (TCP up, all zeros)** | Linux health daemon reports `zombie_likely=true`; Windows monitor polls and self-kills local ffmpeg; PS while-loop respawns | ~50s |
| Sound card unplugged entirely | Windows ffmpeg dshow open fails → PS loop retries every 1s; resumes the moment the device returns | ~1s after device returns |
| Windows simply offline | Linux reports `tcp_established=false` and never reports zombie; no spurious bounces | n/a |

The most important non-obvious one is the sound-card-zombie case: dshow
holds a stale handle and ffmpeg keeps writing zero buffers without ever
hitting EOF or EPIPE. **Detection** has to happen on the Linux side
(consumer has cheap multiplexed access to the audio samples; Windows
producer cannot tap its own dshow capture without contention). **Action**
has to happen on the Windows side (the broken process lives there). The
status endpoint is the thin contract between the two.

## Repo layout

```
linux/
  bin/windowsmic-listen.sh             TCP listener -> PulseAudio sink (mic in)
  bin/windowsmic-health.py             Sampler + GET /health on :9998
  bin/windowsspeakers-export.sh        Pulse monitor -> TCP listen on :10000 (audio out)
  systemd/*.service                    User-level systemd units (Restart=always)
  pulse/windowsmic.pa                  null-sink + remap-source for WindowsMic (input)
  pulse/windowsspeakers.pa             null-sink for WindowsSpeakers (output, default sink)
  config.example.env                   Template for ~/.config/windowsmic-bridge/config.env
  install.sh                           Idempotent installer (migrates v0.1 watchdog)
windows/
  windowsmic.ps1                       ffmpeg dshow -> TCP tee to N targets
  windowsmic-guardian.ps1              Re-runs streamer task if its detached child PS dies
  windowsmic-launcher.vbs              Hidden-window wrapper for the streamer task
  windowsmic-health.ps1                HttpListener -> GET /health on :9998
  windowsmic-monitor.ps1               Polls all targets' /health, kills local ffmpeg on zombie
  windowsspeakers-receive.ps1          Maintains one ffplay per target -> default Windows playback
  config.example.ps1                   Template for %USERPROFILE%\.windowsmic-bridge\config.ps1
  install.ps1                          Registers all five scheduled tasks; sets urlacl + firewall
```

Local configs (`config.env`, `config.ps1`) live OUTSIDE this repo in the
user's home directory. The `.gitignore` blocks them anyway as a safety net.

## Install

### Linux side

Requires: `pulseaudio` (or compatible), `ffmpeg`, `pactl`, `python3`,
`systemd --user`.

```bash
git clone git@github.com:langmartai/lm-claude-code-windows-linux-voice-mic-bridge.git
cd lm-claude-code-windows-linux-voice-mic-bridge
bash linux/install.sh
```

That's it — no secrets to fill in. The default config (`PORT=9999`,
`HEALTH_PORT=9998`, `HEALTH_BIND=0.0.0.0`) covers the common case. If you
need to restrict the health endpoint to localhost or change ports, edit
`~/.config/windowsmic-bridge/config.env` and `systemctl --user restart
windowsmic-health.service`.

If your Linux host has a host firewall or cloud security group, allow
inbound TCP **9999** (mic stream), **9998** (health endpoint), and
**10000** (playback exporter) from the Windows host's address range.

### Windows side

Requires: `ffmpeg` on PATH (`winget install Gyan.FFmpeg`).

In an **elevated** PowerShell:

```powershell
git clone git@github.com:langmartai/lm-claude-code-windows-linux-voice-mic-bridge.git
cd lm-claude-code-windows-linux-voice-mic-bridge
.\windows\install.ps1

# Then set the Linux target(s)
notepad $env:USERPROFILE\.windowsmic-bridge\config.ps1
#   $LinuxTargets = @(
#       @{ Host = '192.0.2.10'; Port = 9999; HealthPort = 9998 },
#       @{ Host = '192.0.2.11'; Port = 9999; HealthPort = 9998 }
#   )

schtasks /End /TN WindowsMicStream  ; schtasks /Run /TN WindowsMicStream
schtasks /End /TN WindowsMicMonitor ; schtasks /Run /TN WindowsMicMonitor
```

The installer registers four scheduled tasks (`WindowsMicStream`,
`WindowsMicGuardian`, `WindowsMicHealth`, `WindowsMicMonitor`), reserves
the http urlacl `http://+:9998/` for the current user, and adds an
inbound firewall rule on TCP 9998. SSH server, key generation, and
`authorized_keys` editing are no longer needed — v0.2 doesn't touch SSH
at all.

## Verify

```bash
# Linux
curl -s http://127.0.0.1:9998/health | python3 -m json.tool
pactl list short sources | grep WindowsMic
ss -tn state established '( sport = :9999 )'
```

A healthy `/health` response looks like:

```json
{
  "stream": {
    "listener_active": true,
    "tcp_established": true,
    "windowsmic_state": "RUNNING"
  },
  "audio": {
    "last_peak": 1234,
    "last_peak_db": -28.4,
    "consecutive_silent": 0,
    "zombie_likely": false
  }
}
```

If `tcp_established=true`, `last_peak=0`, and `zombie_likely=true`, the
Windows monitor will kill its local ffmpeg within ~15 s and the streamer
will respawn it. Watch it happen:

```bash
journalctl --user -u windowsmic-health.service -f
```

```powershell
# Windows
Invoke-RestMethod http://127.0.0.1:9998/health | ConvertTo-Json -Depth 6
Get-Content "$env:LOCALAPPDATA\windowsmic-bridge\monitor.log" -Tail 20 -Wait
```

## Use as Claude Code voice input

The pulse config sets `WindowsMic` as the default source, so any STT tool
respecting the PulseAudio default picks it automatically. If your tool
takes an explicit device, point it at `WindowsMic`.

## Audio output from Linux

The pulse config also sets `WindowsSpeakers` as the default sink. Apps
that play audio (browsers, mpv, espeak, etc.) write there by default;
the `windowsspeakers-export` service streams the sink's monitor to
Windows, where one `ffplay` per host plays it through the default
Windows playback device. Verify with:

```bash
# Linux side: should be the default sink
pactl get-default-sink             # WindowsSpeakers
pactl list short sinks   | grep WindowsSpeakers
ss -tln '( sport = :10000 )'       # exporter listening
```

```powershell
# Windows side: should be one ffplay per target
Get-Process ffplay -ErrorAction SilentlyContinue
Get-Content "$env:LOCALAPPDATA\windowsmic-bridge\speakers-receive.log" -Tail 20
```

Quick end-to-end test from a Linux host: `paplay /usr/share/sounds/alsa/Front_Center.wav`
should play through the Windows speakers within a second or two of latency.

## Tuning

Watchdog defaults are tuned for ~50s recovery. Override in
`~/.config/windowsmic-bridge/config.env`:

```bash
CHECK_INTERVAL=15      # seconds between source-level samples
SILENT_LIMIT=3         # consecutive zero-peak samples before zombie_likely=true
SAMPLE_SEC=3.0         # length of each sampling recording
SKIP_HEAD_SEC=1.0      # parecord startup latency to skip
```

## Migrating from v0.1 (SSH-kill watchdog)

`linux/install.sh` automatically disables and removes
`windowsmic-watchdog.service` and `~/bin/windowsmic-watchdog.sh` if it
finds them, then installs the new health daemon. After running it:

- `WIN_HOST` and `WIN_KEY` in `~/.config/windowsmic-bridge/config.env`
  are unused — you can leave them or delete the lines. No SSH key is
  needed any more (Windows monitor pulls Linux state via HTTP).
- On Windows, re-run the elevated `install.ps1` to register the new
  `WindowsMicHealth` and `WindowsMicMonitor` tasks. The existing
  `WindowsMicStream` and `WindowsMicGuardian` tasks are recreated
  unchanged.

## Gotchas worth knowing

- The pulse remap-source must be created with explicit `rate=48000 channels=2 format=s16le`
  — the default 44100Hz silently produces no samples even though the source
  goes RUNNING. The shipped `windowsmic.pa` already handles this.
- The Windows mic device name has a `(N- )` enumeration prefix that shifts
  after USB disconnect-reconnect. Always match by pattern, never by literal
  string.
- A 2-second test recording often looks "silent" even on a healthy stream
  — `parecord` startup latency eats most of that window. Use ≥3 seconds.
- Long-running dshow captures occasionally go silent without erroring. The
  status-endpoint flow handles this; do not try to detect it via process
  state alone.
- Don't run a manual `parecord --device=WindowsMic` while the health daemon
  is sampling — overlapping clients on the same source break each other.
  `systemctl --user stop windowsmic-health.service` first when probing
  ad-hoc.

## License

See [LICENSE](LICENSE).
