# Streams a Windows microphone over raw TCP to the Linux PulseAudio listener.
#
# Device binding: matches by pattern (default: 'Yamaha AG06') rather than the
# literal "(N- Vendor Model)" string. The leading "(N- " is Windows' device-
# enumeration index and shifts to "(N+1- " after USB disconnect-reconnect
# cycles. The pattern resolver re-runs on every loop iteration, so a renamed
# device is picked up automatically.
#
# Configuration: optional dot-source from
#   $env:USERPROFILE\.windowsmic-bridge\config.ps1
# (NOT in the repo) for $LinuxHost / $LinuxPort / $MicPattern overrides.

$ErrorActionPreference = 'Stop'

$LinuxHost  = ''                # set in config.ps1 (e.g. '192.0.2.10')
$LinuxPort  = 9999
$MicPattern = 'Yamaha AG06'

$cfg = Join-Path $env:USERPROFILE '.windowsmic-bridge\config.ps1'
if (Test-Path $cfg) { . $cfg }

if (-not $LinuxHost) {
    Write-Host "ERROR: \$LinuxHost not set. Create $cfg with: \$LinuxHost = '<linux-ip>'"
    exit 1
}

function Resolve-MicName {
    param([string]$Pattern)
    $listing     = & ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 | Out-String
    $regexString = '"([^"]*' + [regex]::Escape($Pattern) + '[^"]*)"\s*\(audio\)'
    $m           = [regex]::Match($listing, $regexString)
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

while ($true) {
    $MicName = Resolve-MicName -Pattern $MicPattern
    if (-not $MicName) {
        Write-Host ("[{0}] no audio device matching '{1}' — retrying in 5s" -f (Get-Date -Format HH:mm:ss), $MicPattern)
        Start-Sleep -Seconds 5
        continue
    }

    Write-Host ("[{0}] streaming '{1}' -> {2}:{3}" -f (Get-Date -Format HH:mm:ss), $MicName, $LinuxHost, $LinuxPort)

    & ffmpeg -hide_banner -loglevel warning `
        -f dshow -i "audio=$MicName" `
        -acodec pcm_s16le -ar 48000 -ac 1 `
        -f s16le "tcp://${LinuxHost}:${LinuxPort}"

    Write-Host ("[{0}] stream ended, re-resolving device in 1s..." -f (Get-Date -Format HH:mm:ss))
    Start-Sleep -Seconds 1
}
