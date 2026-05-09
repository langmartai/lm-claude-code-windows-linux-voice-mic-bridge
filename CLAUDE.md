# CLAUDE.md

Notes for future Claude Code sessions working on this repo. Captures decisions
and gotchas that are not obvious from reading the source.

## What this repo is for

A bridge that exposes a **Windows microphone as a native PulseAudio input
device on a remote Linux box, over SSH-only access**. Driving use case is
running Claude Code on the Linux box (SSHed in from Windows) and using its
`/voice` command — Claude Code records from the default Linux mic, which
this bridge points at the Windows mic.

Read [README.md](README.md) for the user-facing story; this file is the
maintainer's lens.

## Architecture (v0.2)

Each side **observes only what it can cheaply observe**, **exposes truthful
state on `/health`**, and **acts only on its own resources**. No SSH key
crosses hosts.

- Linux samples the WindowsMic source amplitude every 15s and exposes the
  conclusion as `audio.zombie_likely` on `GET /health` (port 9998).
- Windows polls Linux's `/health`. If Linux says zombie, Windows kills its
  own ffmpeg; the streamer's `while($true)` loop respawns it.
- Windows also exposes its own `/health` (port 9998) for human inspection
  — process alive, TCP outbound, streamer task status. Linux does not poll
  it (no action available), but it's there for `curl`-driven debugging.

The asymmetry of detection (only Linux can see the audio cheaply) and
action (only Windows can fix its own ffmpeg) is intentional. The status
endpoint is the thin contract that lets each side stay self-contained.

## Working on this project

This section is for a Claude Code session that has been asked to install,
debug, or modify the bridge. Default config has no secrets (v0.2 dropped
`WIN_HOST`/`WIN_KEY` entirely), so a fresh `bash linux/install.sh` and
elevated `.\windows\install.ps1` is enough.

### Bootstrap a fresh setup

```bash
# Linux side (run on the Linux box)
git clone git@github.com:langmartai/lm-claude-code-windows-linux-voice-mic-bridge.git
cd lm-claude-code-windows-linux-voice-mic-bridge
bash linux/install.sh
```

```powershell
# Windows side (elevated PowerShell)
git clone git@github.com:langmartai/lm-claude-code-windows-linux-voice-mic-bridge.git
cd lm-claude-code-windows-linux-voice-mic-bridge
.\windows\install.ps1
# then edit %USERPROFILE%\.windowsmic-bridge\config.ps1 (set $LinuxHost)
schtasks /End /TN WindowsMicStream  ; schtasks /Run /TN WindowsMicStream
schtasks /End /TN WindowsMicMonitor ; schtasks /Run /TN WindowsMicMonitor
```

### Quick health check (Linux)

```bash
# all three should be green
systemctl --user is-active windowsmic-listen.service windowsmic-health.service
pactl list short sources | grep WindowsMic
ss -tn state established '( sport = :9999 )' | tail -n +2

# canonical: ask the health daemon what it sees
curl -s http://127.0.0.1:9998/health | python3 -m json.tool
```

A non-zero `audio.last_peak` = stream is healthy. `tcp_established=true`
with `last_peak=0` and `zombie_likely=true` = stuck dshow (the Windows
monitor will recover within ~15s).

### Watch the recovery happen

```bash
# Linux side (sampling/exporting events)
journalctl --user -u windowsmic-health.service -f
```

```powershell
# Windows side (monitor's poll/kill events)
Get-Content "$env:LOCALAPPDATA\windowsmic-bridge\monitor.log" -Tail 50 -Wait
```

### Common operations

```bash
# Linux side: edit a script, redeploy, restart services
bash linux/install.sh                                    # idempotent (also migrates v0.1 watchdog)
systemctl --user restart windowsmic-listen.service windowsmic-health.service

# Force-bounce when the user says "voice broke right now":
systemctl --user restart windowsmic-listen.service

# Reload pulse config after editing linux/pulse/windowsmic.pa
sudo install -m 644 linux/pulse/windowsmic.pa /etc/pulse/default.pa.d/
pulseaudio -k && pulseaudio --start
```

```powershell
# Windows side
schtasks /Query /TN WindowsMicStream  /V /FO LIST | Select-String 'Status|Last Run'
schtasks /Query /TN WindowsMicMonitor /V /FO LIST | Select-String 'Status|Last Run'
Get-Process ffmpeg | Select-Object Id, StartTime, CPU
schtasks /End /TN WindowsMicStream     # stop streamer
schtasks /Run /TN WindowsMicStream     # start streamer
```

### Modifying the scripts

Iterate on Linux first — it's the side you can SSH into and tail logs from.
Windows-side changes are slower because every change requires `scp` of the
new `.ps1` to `C:\windowsmic-bridge\` and a task restart. For fast Windows
iteration, run the PS1 directly in an interactive PowerShell to see live
output, *then* deploy via the scheduled task once the logic is right.

After any change to a tracked file, run the credential-leak sweep before
committing:

```bash
git diff --cached | grep -E '10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|admin@|/home/[a-z]+|\.ssh/[a-z_-]+_key' && \
  echo "STOP: possible secret leak above" || echo "clean"
```

### When the user says "voice doesn't work"

Walk this checklist top-to-bottom — each step is fast and rules out a layer:

1. `systemctl --user is-active windowsmic-listen.service windowsmic-health.service` — both `active`?
2. `curl -s http://127.0.0.1:9998/health | jq .stream` — what does Linux see?
   - `tcp_established=false` → Windows side dead. Check `Get-Process ffmpeg` over SSH, kick task with `schtasks /Run /TN WindowsMicStream`.
   - `tcp_established=true` and `windowsmic_state=null` → pulse config didn't load. `sudo install … && pulseaudio -k && pulseaudio --start`.
   - `tcp_established=true`, `windowsmic_state=RUNNING` → continue.
3. `curl -s http://127.0.0.1:9998/health | jq .audio` — what's the audio?
   - `last_peak=0` and `zombie_likely=true` → sound-card-zombie. The Windows monitor handles this; if it doesn't (e.g., monitor task crashed), check `Get-Content $env:LOCALAPPDATA\windowsmic-bridge\monitor.log -Tail 20`.
   - `last_peak>0` → stream is healthy; problem is downstream of the bridge.
4. `pactl get-default-source` — is `WindowsMic` the default?
   - **No** → `pactl set-default-source WindowsMic` (and check pulse config has `set-default-source WindowsMic`).
5. App-specific: does the app honor pulse default? If not, point it at device `WindowsMic` directly.

### What NOT to do

- Don't add SSH tunneling "just to be safe" — the design assumes LAN/vSwitch.
  Adding it changes the latency profile; only do it if there's a real reason.
- Don't switch to a codec (opus, mp3) for "bandwidth" — uncompressed s16le at
  ~768 kbit/s is fine on a LAN and avoids latency/quality cost.
- Don't put the device name as a literal string in the PS1 — always pattern
  match. See "Windows device name has a shifting prefix" below.
- Don't lower `CHECK_INTERVAL` below ~10s without raising `SAMPLE_SEC`. See
  "Recovery timing budget" below.
- Don't run multiple `parecord --device=WindowsMic` clients at once when
  debugging. See "Concurrent parecord clients" below.
- Don't reintroduce SSH-kill or any cross-host action. Detection on consumer
  side, action on producer side, status endpoint between them — that's the
  v0.2 contract.

## Configuration / credential boundary

v0.2 has **no cross-host credentials at all**. The status-endpoint design
removed the SSH key requirement. Local configs still live outside the repo
on each host:

| What | Where | Tracked? |
|---|---|---|
| Linux runtime config (`PORT`, `HEALTH_PORT`, sampler tuning) | `~/.config/windowsmic-bridge/config.env` | NO — gitignored |
| Windows runtime config (`$LinuxHost`, `$LinuxPort`, `$LinuxHealthPort`, `$WindowsHealthPort`, `$MicPattern`) | `%USERPROFILE%\.windowsmic-bridge\config.ps1` | NO — gitignored |
| Templates with placeholder values | `linux/config.example.env`, `windows/config.example.ps1` | yes |

Placeholder IPs in tracked files use the **RFC 5737 documentation block**
(`192.0.2.0/24`) — never put real LAN IPs into tracked files.

`.gitignore` excludes `config.env`, `config.ps1`, `*.local.*`, `.env*` as a
safety net.

## Critical implementation gotchas

These are non-obvious, easy to break, and silently fail. Do not regress them.

### Pulse remap-source needs explicit format
The shipped `linux/pulse/windowsmic.pa` sets `rate=48000 channels=2 format=s16le`
on the `module-remap-source`. **Do not remove these.** Without them pulse
falls back to 44100Hz default and the source goes RUNNING but produces no
samples — looks like everything is wired up but recordings are pure zeros.

### Windows device name has a shifting prefix
`ffmpeg -f dshow -i "audio=..."` returns names like `Microphone (3- Yamaha AG06MK2)`.
The leading `(N- ` is Windows' device-enumeration index and **shifts to
`(4- `, `(5- ` after USB disconnect-reconnect cycles**. The PS1 resolves
the device by substring pattern (default `Yamaha AG06`) every loop iteration
— never hardcode the literal name.

### Sound-card-zombie failure mode (the whole reason the monitor exists)
When the USB audio device disconnects/reconnects, Windows ffmpeg does NOT
crash. dshow keeps the handle in a zombie state — process alive, TCP socket
alive, but only zero-filled buffers ever leave. PowerShell's `while($true)`
loop never sees ffmpeg exit and never respawns it.

**Detection lives on Linux** (the consumer side has cheap multiplexed access
to the audio samples; the Windows producer cannot tap its own dshow capture
without contention). **Action lives on Windows** (only it can kill its own
ffmpeg). The status endpoint is the contract: Linux exposes
`audio.zombie_likely`; Windows polls and self-kills.

If the Windows monitor task is disabled or its config has the wrong
`$LinuxHealthPort`, the bridge silently dies after the first USB replug.

### Health daemon must guard its peak interpretation on TCP-established state
A pulse null-sink monitor produces digital zeros even when nothing is
writing to the sink. So when Windows is simply offline, the sampler sees
zeros on `WindowsMic` too. The health daemon distinguishes "Windows offline"
(silence is expected, don't accumulate streak) from "Windows connected but
silent" (real zombie indication, accumulate streak) using the
`tcp_established` flag. `zombie_likely` is only `true` when both
`tcp_established=true` AND `consecutive_silent >= silent_limit`.

### parecord startup latency eats short test recordings
A 1.5-second `parecord` typically returns only the WAV header — pulse
takes ~500ms to wake a SUSPENDED source and start delivering. Always skip
the first ~1s of any recording when checking peak, and use a recording
window of at least 3s. The health daemon's `SKIP_HEAD_SEC=1.0` and
`SAMPLE_SEC=3.0` defaults reflect this.

### Concurrent parecord clients break the source
Running multiple `parecord --device=WindowsMic` processes overlapping in
time causes most of them to return only the WAV header. When debugging,
do not run the health daemon AND a separate manual recording at the same
time — they will compete and both fail. Stop the daemon
(`systemctl --user stop windowsmic-health.service`) before running ad-hoc
recording probes.

### PowerShell regex cast is eager
`[regex]'literal' + $var` casts the literal to regex *before* concatenation,
not after — fails on incomplete patterns. Build the string first:

```powershell
$s = 'prefix' + [regex]::Escape($var) + 'suffix'
$m = [regex]::Match($input, $s)
```

### HttpListener `+:port` requires a urlacl for non-admin users
`http://+:9998/` binding without admin needs a pre-registered urlacl. The
elevated `install.ps1` does this once via
`netsh http add urlacl url=http://+:9998/ user=DOMAIN\USER`. Without it,
`windowsmic-health.ps1` falls back to per-IP binding (still works on
localhost; LAN access depends on which IPs were enumerated).

### AG06MK2 specifics (likely true for other USB mics too)
The Yamaha AG06MK2 presents to dshow as **44100Hz stereo**. The PS1 forces
output to 48000Hz mono on the wire (`-ar 48000 -ac 1`). The Linux listener
receives mono and writes to a 2ch null-sink (pulse upmixes). Do not "fix"
the mismatch by changing the listener's `-ac` — a stereo→mono mismatch on
the listener side will break the sample alignment.

## Architecture rationale (so you don't second-guess)

- **Direct TCP, no SSH tunnel.** Both hosts are on the same LAN or Hyper-V
  virtual switch. Encryption adds latency without adding security in this
  threat model. If you ever need cross-network, add an SSH tunnel as an
  optional config — do not make it the default.
- **Raw `s16le` over TCP, no codec.** ~768 kbit/s on a LAN is free.
  Compression adds latency, complexity, and quality loss for an STT
  pipeline that doesn't need it.
- **PulseAudio default source = `WindowsMic`.** Apps like Claude Code's
  `/voice` and most STT tools record from the default source. Setting it
  here means zero per-tool config.
- **Status endpoint, not SSH-kill.** v0.1 had Linux SSH into Windows and
  kill ffmpeg. v0.2 inverts this: Linux exposes its observation, Windows
  pulls and self-kills. Each side mutates only its own resources; no SSH
  key crosses hosts; both sides can be debugged with `curl`.

## Testing recovery

Easy: kill Windows ffmpeg directly (`Stop-Process -Name ffmpeg -Force`);
the PS while-loop respawns within seconds. Confirms the inner reconnect
path.

Hard: simulate the zombie failure mode. There's no clean way to fake it
without an actual USB disconnect-reconnect on the Windows host. Trust the
flow logic; verify by physically replugging the mic and watching:

```bash
journalctl --user -u windowsmic-health.service -f
```

```powershell
Get-Content "$env:LOCALAPPDATA\windowsmic-bridge\monitor.log" -Tail 50 -Wait
```

You should see `consecutive_silent` increment in the Linux log toward
`SILENT_LIMIT`, then the Windows monitor log show `Linux reports
zombie_likely=true ... killed ffmpeg PID NNN`, then audio recover within
~10s after that.

## Recovery timing budget

Defaults give ~50–65s end-to-end recovery from a USB replug:

```
CHECK_INTERVAL=15s × SILENT_LIMIT=3 = 45s detection (worst-case Linux side)
+ Windows monitor poll (≤15s)        ≈ 15s
+ ffmpeg kill + respawn               ≈  3s
                                    ─────
                                    ~63s worst case
```

Best case is faster — the next Windows poll might land just after the third
silent sample on Linux. Do not push `CHECK_INTERVAL` below ~10s without
also raising `SAMPLE_SEC` beyond `SKIP_HEAD_SEC + 0.5s` — otherwise the
post-skip sample window becomes too short to reliably observe non-zero peaks.

## Repo conventions

- Account: `langmartai` — uses **SSH** remote (per the user's global
  GitHub-account-mapping notes). Do NOT switch to HTTPS for this repo.
- Single-package layout: `linux/` and `windows/` are sibling top-level
  directories; do not collapse them.
- systemd units use `%h/bin/...` for `ExecStart` so they install
  per-user without absolute paths in tracked files.
- `install.sh` and `install.ps1` must stay **idempotent** — re-running
  them after editing source files should redeploy cleanly. `install.sh`
  also handles v0.1 → v0.2 migration by removing the old watchdog files.
- All `.ps1` files are **7-bit ASCII**. PS5.1 reads non-ASCII bytes
  through the OEM/ANSI code page and the parser blows up on smart
  punctuation (em-dash, curly quotes). Use `--`, never `—`.
