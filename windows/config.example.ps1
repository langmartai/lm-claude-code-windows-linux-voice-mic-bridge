# Copy to %USERPROFILE%\.windowsmic-bridge\config.ps1 and fill in.
# windowsmic.ps1, windowsmic-monitor.ps1, and windowsmic-health.ps1 dot-source
# this file if it exists. Do NOT commit this file with real values.

# ---- Multi-target form (preferred since v0.3) ----
# One ffmpeg process captures dshow once and tees to all targets. A slow or
# dead receiver does not stall the others (per-output onfail=ignore).
$LinuxTargets = @(
    @{ Host = '192.0.2.10';  Port = 9999; HealthPort = 9998 },
    @{ Host = '192.0.2.11';  Port = 9999; HealthPort = 9998 }
)

# ---- Legacy single-target form (still works) ----
# If $LinuxTargets is unset/empty, the scripts fall back to these. Kept for
# backwards compatibility with existing installs.
# $LinuxHost       = '192.0.2.10'
# $LinuxPort       = 9999
# $LinuxHealthPort = 9998

# ---- Other settings ----
$WindowsHealthPort = 9998                # local port the Windows /health server binds
$MicPattern        = 'Yamaha AG06'       # substring matched against ffmpeg dshow audio device names
