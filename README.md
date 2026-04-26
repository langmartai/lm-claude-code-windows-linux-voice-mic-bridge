# lm-claude-code-windows-linux-voice-mic-bridge

Stream a Windows microphone over raw TCP to a Linux machine, where it appears
as a regular PulseAudio input device (`WindowsMic`) any app — Claude Code
voice input, browsers, STT tools — can record from.

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
  hit `/voice`. The watchdog handles the case where Windows dshow goes
  zombie after a USB mic disconnect-reconnect, so you don't have to notice
  or manually intervene.

### Why not RDP audio redirection?

RDP carries audio natively, but you'd be in a remote desktop session, not
an SSH terminal — different workflow. This bridge keeps you in your
existing SSH terminal and just makes the mic show up.

## Architecture

```
Windows host                                    Linux host
─────────────                                   ───────────────────────────
USB mic ──┐                                     ┌── PulseAudio
          │                                     │
       dshow                                    │   sink:   virtmic
          │                                     │            │ (monitor)
       ffmpeg ──── raw s16le ────tcp:9999────►  ffmpeg ──────┤
       (windowsmic.ps1)                                      │
                                                   source: WindowsMic ◄── apps
                                                            │
                                                source-level watchdog ──► SSH-kill
                                                                          Windows ffmpeg
                                                                          on stuck stream
```

## Failure modes handled

| Failure | Recovery layer | Time |
|---|---|---|
| Linux listener crashes | systemd `Restart=always` | 2s |
| Linux watchdog crashes | systemd `Restart=always` | 5s |
| Windows ffmpeg crashes | PowerShell `while($true)` reconnect loop | 1s |
| Windows scheduled task crashes | Task `RestartCount=999` / 1-min interval | 60s |
| TCP drops | inner reconnect loops on both sides | 1–2s |
| Windows enum index shifts (`(3-` → `(4-`) on USB replug | PS1 re-resolves device name by pattern every iteration | next loop |
| **Sound card disconnect → Windows ffmpeg goes zombie (TCP up, all zeros)** | Linux watchdog detects digital silence (only when TCP is established), SSH-kills hung Windows ffmpeg, restarts listener | ~50s |
| Sound card unplugged entirely | Windows ffmpeg dshow open fails → PS loop retries every 1s; resumes the moment the device returns | ~1s after device returns |
| Windows simply offline | watchdog ignores (no TCP established) — no spurious bounces | n/a |

The most important non-obvious one is the sound-card-zombie case: dshow
holds a stale handle and ffmpeg keeps writing zero buffers without ever
hitting EOF or EPIPE, so the Windows-side reconnect loop alone is not
enough. The SSH-kill from the Linux watchdog is what breaks the zombie.

## Repo layout

```
linux/
  bin/windowsmic-listen.sh        TCP listener -> PulseAudio sink
  bin/windowsmic-watchdog.sh      Source-level silence watchdog + SSH-kill
  systemd/*.service               User-level systemd units (Restart=always)
  pulse/windowsmic.pa             null-sink + remap-source definition
  config.example.env              Template for ~/.config/windowsmic-bridge/config.env
  install.sh                      Idempotent installer
windows/
  windowsmic.ps1                  ffmpeg dshow -> TCP, with pattern device match
  config.example.ps1              Template for %USERPROFILE%\.windowsmic-bridge\config.ps1
  install.ps1                     Registers scheduled task with full resilience settings
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

# Then set Windows host + SSH key path (used for the watchdog SSH-kill)
$EDITOR ~/.config/windowsmic-bridge/config.env
systemctl --user restart windowsmic-watchdog.service
```

### Windows side

Requires: `ffmpeg` on PATH (`winget install Gyan.FFmpeg`), OpenSSH Server
running with the public key from `WIN_KEY` in `authorized_keys` (so the
Linux watchdog can SSH-kill).

In an **elevated** PowerShell:

```powershell
git clone git@github.com:langmartai/lm-claude-code-windows-linux-voice-mic-bridge.git
cd lm-claude-code-windows-linux-voice-mic-bridge
.\windows\install.ps1

# Then set the Linux host IP
notepad $env:USERPROFILE\.windowsmic-bridge\config.ps1
schtasks /End  /TN WindowsMicStream
schtasks /Run  /TN WindowsMicStream
```

## Verify

```bash
# Linux
pactl list short sources | grep WindowsMic           # should exist
ss -tn state established '( sport = :9999 )'         # should show ESTAB to Windows
parecord --device=WindowsMic --file-format=wav /tmp/t.wav &
sleep 4 && kill %1
ffmpeg -i /tmp/t.wav -af volumedetect -f null - 2>&1 | grep volume
```

If the test recording is silent (peak 0) and TCP is established, the
watchdog should auto-bounce within ~50s. Watch it work:

```bash
journalctl --user -u windowsmic-watchdog.service -f
```

## Use as Claude Code voice input

The pulse config sets `WindowsMic` as the default source, so any STT tool
respecting the PulseAudio default picks it automatically. If your tool
takes an explicit device, point it at `WindowsMic`.

## Tuning

Watchdog defaults are tuned for ~50s recovery. Override in
`~/.config/windowsmic-bridge/config.env`:

```bash
CHECK_INTERVAL=15      # seconds between source-level samples
SILENT_LIMIT=3         # consecutive zero-peak samples before bouncing
SAMPLE_SEC=3.0         # length of each sampling recording
SKIP_HEAD_SEC=1.0      # parecord startup latency to skip
```

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
  watchdog handles this; do not try to detect it via process state alone.

## License

See [LICENSE](LICENSE).
