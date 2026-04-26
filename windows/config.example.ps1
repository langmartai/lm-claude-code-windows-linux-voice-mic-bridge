# Copy to %USERPROFILE%\.windowsmic-bridge\config.ps1 and fill in.
# windowsmic.ps1 dot-sources this if it exists.
# Do NOT commit this file with real values.

$LinuxHost  = '192.0.2.10'        # IP of the Linux box running the listener (REPLACE)
$LinuxPort  = 9999                # must match PORT in linux/config.env
$MicPattern = 'Yamaha AG06'       # substring matched against ffmpeg dshow audio device names
