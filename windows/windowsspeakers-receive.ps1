# Linux -> Windows playback receiver.
#
# Maintains one ffplay child per $LinuxTargets entry. Each ffplay dials
# tcp://<linux>:<PlaybackPort> and plays raw s16le 48kHz stereo to the
# Windows default playback device via SDL2 (which ffplay is built on).
# The Windows audio engine mixes N concurrent streams natively, so we don't
# need an ffmpeg amix filter -- one ffplay per host is simpler and gives
# per-host failure isolation.
#
# Why ffplay and not ffmpeg: upstream ffmpeg builds on Windows do not have
# a clean native audio OUTPUT muxer (dshow/wasapi are input-only). ffplay
# is part of the Gyan.FFmpeg distribution and is the standard pure-ffmpeg-
# distribution way to play to default Windows audio.
#
# Self-detach + ASCII-only: see windowsmic.ps1 header notes.

$ErrorActionPreference = 'Stop'

if (-not $env:WINDOWSSPEAKERS_RECEIVE_DETACHED) {
    $selfPath = $MyInvocation.MyCommand.Path
    if (-not $selfPath) { $selfPath = $PSCommandPath }
    if ($selfPath) {
        $psExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $psExe
        $psi.Arguments              = "-NoProfile -ExecutionPolicy Bypass -File `"$selfPath`""
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.WorkingDirectory       = [System.IO.Path]::GetDirectoryName($selfPath)
        $psi.EnvironmentVariables['WINDOWSSPEAKERS_RECEIVE_DETACHED'] = '1'
        [void][System.Diagnostics.Process]::Start($psi)
        exit 0
    }
}

# ---- main process (detached child) ----

$LinuxTargets    = $null
$LinuxHost       = ''
$LinuxPort       = 9999
$LinuxHealthPort = 9998
$DefaultPlaybackPort = 10000
$ChildPollSec    = 2
$RestartCooldownSec = 1

$cfg = Join-Path $env:USERPROFILE '.windowsmic-bridge\config.ps1'
if (Test-Path $cfg) { . $cfg }

if (-not $LinuxTargets -or $LinuxTargets.Count -eq 0) {
    if ($LinuxHost) {
        $LinuxTargets = @(@{ Host = $LinuxHost; Port = $LinuxPort; HealthPort = $LinuxHealthPort })
    } else {
        $LinuxTargets = @()
    }
}
$normalized = @()
foreach ($t in $LinuxTargets) {
    if (-not $t.Host) { continue }
    if (-not $t.PlaybackPort) { $t.PlaybackPort = $DefaultPlaybackPort }
    $normalized += $t
}
$LinuxTargets = $normalized

$LogPath = Join-Path $env:LOCALAPPDATA 'windowsmic-bridge\speakers-receive.log'
$LogDir  = [System.IO.Path]::GetDirectoryName($LogPath)
if ($LogDir -and -not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

function Write-RLog {
    param([string]$Line)
    try {
        if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 1MB)) {
            Move-Item -Force $LogPath "$LogPath.1"
        }
        ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Line) |
            Out-File -FilePath $LogPath -Append -Encoding utf8
    } catch { }
}

if ($LinuxTargets.Count -eq 0) {
    Write-RLog "ERROR: no Linux targets configured -- receiver exiting"
    exit 1
}

function Quote-Arg {
    param([string]$a)
    if ($a -match '[\s"]') { return '"' + ($a -replace '"','\"') + '"' }
    return $a
}

function Start-FFplayHidden {
    param([string[]]$FFplayArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'ffplay'
    $psi.Arguments              = ($FFplayArgs | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    # Drain pipes async so OS buffers never fill and block ffplay.
    $null = $p.StandardOutput.BaseStream.CopyToAsync([System.IO.Stream]::Null)
    $null = $p.StandardError.BaseStream.CopyToAsync([System.IO.Stream]::Null)
    return $p
}

$targetsDesc = ($LinuxTargets | ForEach-Object { "{0}:{1}" -f $_.Host, $_.PlaybackPort }) -join ', '
Write-RLog ("receiver started, maintaining ffplay per target: [{0}]" -f $targetsDesc)

# host:port -> @{ Process; LastStartedAt }
$children = @{}

while ($true) {
    foreach ($t in $LinuxTargets) {
        $key = "{0}:{1}" -f $t.Host, $t.PlaybackPort
        $alive = $false
        if ($children.ContainsKey($key) -and $children[$key].Process) {
            try {
                if (-not $children[$key].Process.HasExited) { $alive = $true }
            } catch { $alive = $false }
        }
        if (-not $alive) {
            if ($children.ContainsKey($key) -and $children[$key].LastStartedAt) {
                $age = (Get-Date) - $children[$key].LastStartedAt
                if ($age.TotalSeconds -lt $RestartCooldownSec) { continue }
            }
            try {
                # ffplay 7.x argument names diverge from ffmpeg's:
                #   ffmpeg uses -ar / -ac 2  ; ffplay uses -sample_rate / -ch_layout stereo
                # Get this wrong and ffplay exits immediately with
                # "Failed to set value '2' for option 'ac': Option not found".
                $proc = Start-FFplayHidden -FFplayArgs @(
                    '-nodisp', '-autoexit', '-loglevel', 'error',
                    '-fflags', 'nobuffer',
                    '-f', 's16le', '-sample_rate', '48000', '-ch_layout', 'stereo',
                    ("tcp://{0}:{1}" -f $t.Host, $t.PlaybackPort)
                )
                $children[$key] = @{ Process = $proc; LastStartedAt = Get-Date }
                Write-RLog ("started ffplay for {0} (PID {1})" -f $key, $proc.Id)
            } catch {
                Write-RLog ("failed to start ffplay for {0}: {1}" -f $key, $_.Exception.Message)
            }
        }
    }

    # Drop entries whose target was removed from config (graceful, not strictly needed for static config)
    $configuredKeys = @($LinuxTargets | ForEach-Object { "{0}:{1}" -f $_.Host, $_.PlaybackPort })
    foreach ($k in @($children.Keys)) {
        if ($configuredKeys -notcontains $k) {
            try { $children[$k].Process.Kill() } catch { }
            $children.Remove($k) | Out-Null
            Write-RLog ("dropped {0} (no longer configured)" -f $k)
        }
    }

    Start-Sleep -Seconds $ChildPollSec
}
