# Copy to %USERPROFILE%\.windowsmic-bridge\config.ps1 and fill in.
# windowsmic.ps1, windowsmic-monitor.ps1, and windowsmic-health.ps1 dot-source
# this file if it exists. Do NOT commit this file with real values.

$LinuxHost          = '192.0.2.10'        # IP of the Linux box (REPLACE)
$LinuxPort          = 9999                # must match PORT in linux config.env
$LinuxHealthPort    = 9998                # must match HEALTH_PORT in linux config.env
$WindowsHealthPort  = 9998                # local port the Windows /health server binds
$MicPattern         = 'Yamaha AG06'       # substring matched against ffmpeg dshow audio device names
