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

## Working on this project

This section is for a Claude Code session that has been asked to install,
debug, or modify the bridge. Assume both `~/.config/windowsmic-bridge/config.env`
and `%USERPROFILE%\.windowsmic-bridge\config.ps1` already exist on the
respective hosts (otherwise: copy from the `config.example.*` templates and
ask the user to fill in `WIN_HOST`, `WIN_KEY`, `LinuxHost`).

### Bootstrap a fresh setup

```bash
# Linux side (run on the Linux box)
git clone git@github.com:langmartai/lm-claude-code-windows-linux-voice-mic-bridge.git
cd lm-claude-code-windows-linux-voice-mic-bridge
bash linux/install.sh
# then edit ~/.config/windowsmic-bridge/config.env (set WIN_HOST, WIN_KEY)
systemctl --user restart windowsmic-watchdog.service
```

```powershell
# Windows side (elevated PowerShell)
git clone git@github.com:langmartai/lm-claude-code-windows-linux-voice-mic-bridge.git
cd lm-claude-code-windows-linux-voice-mic-bridge
.\windows\install.ps1
# then edit %USERPROFILE%\.windowsmic-bridge\config.ps1 (set $LinuxHost)
schtasks /End /TN WindowsMicStream
schtasks /Run /TN WindowsMicStream
```

### Quick health check (Linux)

```bash
# all four should be green
systemctl --user is-active windowsmic-listen.service windowsmic-watchdog.service
pactl list short sources | grep WindowsMic
ss -tn state established '( sport = :9999 )' | tail -n +2

# is the mic actually delivering audio? (≥3s sample, skip 1s startup)
timeout 4 parecord --device=WindowsMic --file-format=wav /tmp/check.wav 2>/dev/null
python3 -c "
import wave, struct, math
w=wave.open('/tmp/check.wav','rb'); sr=w.getframerate(); skip=int(1.0*sr); n=w.getnframes()
w.setpos(skip); f=w.readframes(n-skip)
s=struct.unpack('<'+'h'*(len(f)//2), f) if f else []
peak=max(abs(x) for x in s) if s else 0
print(f'peak={peak} ({20*math.log10(peak/32768) if peak>0 else -100:.1f} dBFS)')
"
```

A non-zero peak after that python block = stream is healthy. A peak of 0
with `WindowsMic` listed and TCP established = stuck dshow (the watchdog
will recover within ~50s).

### Watch the watchdog react

```bash
journalctl --user -u windowsmic-watchdog.service -f
# you should see no output during normal operation;
# silence/recovery events log here when they happen
```

### Common operations

```bash
# Linux side: edit a script, redeploy, restart services
bash linux/install.sh                                       # idempotent
systemctl --user restart windowsmic-listen.service windowsmic-watchdog.service

# Force-bounce when the user says "voice broke right now":
# (this also kicks the Windows side via the watchdog's normal path on next cycle,
#  OR do it directly)
systemctl --user restart windowsmic-listen.service

# Kick the Windows side over SSH (uses WIN_HOST/WIN_KEY from config.env)
. ~/.config/windowsmic-bridge/config.env
ssh -i "$WIN_KEY" "$WIN_HOST" \
    'powershell -Command "Get-Process ffmpeg -ErrorAction SilentlyContinue | Stop-Process -Force"'
# the Windows scheduled-task PS loop respawns ffmpeg within ~8s

# Reload pulse config after editing linux/pulse/windowsmic.pa
sudo install -m 644 linux/pulse/windowsmic.pa /etc/pulse/default.pa.d/
pulseaudio -k && pulseaudio --start
```

```powershell
# Windows side
schtasks /Query /TN WindowsMicStream /V /FO LIST | Select-String 'Status|Last Run'
Get-Process ffmpeg | Select-Object Id, StartTime, CPU
schtasks /End /TN WindowsMicStream     # stop
schtasks /Run /TN WindowsMicStream     # start
```

### Modifying the scripts

Iterate on Linux first — it's the side you can SSH into and tail logs from.
Windows-side changes are slower because every change requires `scp` of the
new `.ps1` to `C:\windowsmic-bridge\windowsmic.ps1` and a task restart. For
fast Windows iteration, run the PS1 directly in an interactive PowerShell
to see ffmpeg's live output, *then* deploy via the scheduled task once the
logic is right.

After any change to a tracked file, run the credential-leak sweep before
committing:

```bash
git diff --cached | grep -E '10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|admin@|/home/[a-z]+|\.ssh/[a-z_-]+_key' && \
  echo "STOP: possible secret leak above" || echo "clean"
```

### When the user says "voice doesn't work"

Walk this checklist top-to-bottom — each step is fast (~2s) and rules out
a layer:

1. `systemctl --user is-active windowsmic-listen.service windowsmic-watchdog.service` — both `active`?
2. `ss -tn state established '( sport = :9999 )'` — TCP connection from Windows?
   - **No** → Windows side dead. Check `Get-Process ffmpeg` over SSH, kick task with `schtasks /Run /TN WindowsMicStream`.
   - **Yes** → continue.
3. `pactl list short sources | grep WindowsMic` — source exists?
   - **No** → pulse config didn't load. `sudo install … && pulseaudio -k && pulseaudio --start`.
   - **Yes** → continue.
4. Record a 4s sample (snippet above). Peak == 0 with TCP established = sound-card-zombie.
   - Either wait ~50s for watchdog, OR force it: `systemctl --user restart windowsmic-listen.service` then SSH-kill Windows ffmpeg.
5. `pactl get-default-source` — is `WindowsMic` the default?
   - **No** → `pactl set-default-source WindowsMic` (and check pulse config has `set-default-source WindowsMic`).
6. App-specific: does the app honor pulse default? If not, point it at device `WindowsMic` directly.

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

## Configuration / credential boundary

Real hosts, SSH users, and key paths **never live in the repo**.

| What | Where | Tracked? |
|---|---|---|
| Linux runtime config (`PORT`, `WIN_HOST`, `WIN_KEY`, watchdog tuning) | `~/.config/windowsmic-bridge/config.env` | NO — gitignored |
| Windows runtime config (`$LinuxHost`, `$LinuxPort`, `$MicPattern`) | `%USERPROFILE%\.windowsmic-bridge\config.ps1` | NO — gitignored |
| Templates with placeholder values | `linux/config.example.env`, `windows/config.example.ps1` | yes |

Placeholder IPs in tracked files use the **RFC 5737 documentation block**
(`192.0.2.0/24`) — never put real LAN IPs, SSH usernames, or key paths into
tracked files, even in comments or examples.

Before committing changes, sweep for accidental leaks:

```bash
git diff --cached | grep -E '10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|admin@|/home/[a-z]+|\.ssh/[a-z_-]+_key'
```

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

### Sound-card-zombie failure mode (the whole reason the watchdog exists)
When the USB audio device disconnects/reconnects, Windows ffmpeg does NOT
crash. dshow keeps the handle in a zombie state — process alive, TCP socket
alive, but only zero-filled buffers ever leave. PowerShell's `while($true)`
loop never sees ffmpeg exit and never respawns it. **The Linux watchdog's
SSH-kill of the hung Windows ffmpeg is the only thing that breaks this.**
If the SSH-kill is removed or `WIN_HOST`/`WIN_KEY` are unset, the bridge
silently dies after the first USB replug.

### Watchdog must guard on TCP-established state
A pulse null-sink monitor produces digital zeros even when nothing is
writing to the sink. So when Windows is simply offline, the watchdog sees
zeros on `WindowsMic` too. Without
`ss -tn state established sport :PORT` as a precondition, it would
spuriously bounce the listener every cycle while Windows is down.

### parecord startup latency eats short test recordings
A 1.5-second `parecord` typically returns only the WAV header — pulse
takes ~500ms to wake a SUSPENDED source and start delivering. Always skip
the first ~1s of any recording when checking peak, and use a recording
window of at least 3s. The watchdog's `SKIP_HEAD_SEC=1.0` and
`SAMPLE_SEC=3.0` defaults reflect this.

### Concurrent parecord clients break the source
Running multiple `parecord --device=WindowsMic` processes overlapping in
time causes most of them to return only the WAV header. When debugging,
do not run the watchdog AND a separate monitor loop at the same time —
they will compete and both fail. Stop the watchdog (`systemctl --user stop
windowsmic-watchdog.service`) before running ad-hoc recording probes.

### PowerShell regex cast is eager
`[regex]'literal' + $var` casts the literal to regex *before* concatenation,
not after — fails on incomplete patterns. Build the string first:

```powershell
$s = 'prefix' + [regex]::Escape($var) + 'suffix'
$m = [regex]::Match($input, $s)
```

### Hidden Start-Process via one-shot SSH dies with the session
`ssh host 'Start-Process ... -WindowStyle Hidden'` does NOT detach — the
spawned process gets killed when the SSH session closes. For persistent
launching from a remote SSH command, register a Scheduled Task and invoke
`schtasks /Run /TN <name>`.

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
- **Watchdog SSH-kills the Windows side, not the Linux side.** The
  failure is on the Windows side; bouncing the Linux listener alone does
  nothing because zombie ffmpeg never gets EPIPE. Attempting to fix this
  by hardening the Linux listener will not work — read the "sound-card-
  zombie" gotcha above.

## Testing recovery

Easy: kill Windows ffmpeg via SSH; PowerShell loop respawns it within a
few seconds. Confirms the inner reconnect path.

Hard: simulate the zombie failure mode. There's no clean way to fake it
without an actual USB disconnect-reconnect on the Windows host. Trust the
watchdog logic; verify by physically replugging the mic and watching:

```bash
journalctl --user -u windowsmic-watchdog.service -f
```

You should see `digital silence detected (streak=N/3)` accumulate, then
`BOUNCING — kill hung Windows ffmpeg + restart listener`, then audio
recovers within ~10s after that.

## Recovery timing budget

Defaults give ~50s end-to-end recovery from a USB replug:

```
CHECK_INTERVAL=15s × SILENT_LIMIT=3 = 45s detection
+ SSH-kill + listener restart                ≈  8s
                                            ─────
                                             ~53s
```

Do not push `CHECK_INTERVAL` below ~10s without also raising `SAMPLE_SEC`
beyond `SKIP_HEAD_SEC + 0.5s` — otherwise the post-skip sample window
becomes too short to reliably observe non-zero peaks.

## Repo conventions

- Account: `langmartai` — uses **SSH** remote (per the user's global
  GitHub-account-mapping notes). Do NOT switch to HTTPS for this repo.
- Single-package layout: `linux/` and `windows/` are sibling top-level
  directories; do not collapse them.
- systemd units use `%h/bin/...` for `ExecStart` so they install
  per-user without absolute paths in tracked files.
- `install.sh` and `install.ps1` must stay **idempotent** — re-running
  them after editing source files should redeploy cleanly.
