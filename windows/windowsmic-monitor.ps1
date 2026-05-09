# Polls the Linux /health endpoint and self-kills local ffmpeg if Linux
# reports the zombie state (TCP up + audio is digital silence for N samples).
#
# Replaces the cross-host SSH-kill the Linux watchdog used to do. Detection
# stays on Linux where the audio data is; recovery action stays on Windows
# where the broken process lives.
#
# Self-detach + ASCII-only: see windowsmic.ps1 header notes.

$ErrorActionPreference = 'Stop'

if (-not $env:WINDOWSMIC_MONITOR_DETACHED) {
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
        $psi.EnvironmentVariables['WINDOWSMIC_MONITOR_DETACHED'] = '1'
        [void][System.Diagnostics.Process]::Start($psi)
        exit 0
    }
}

# ---- main process (detached child) ----

$LinuxHost       = ''
$LinuxHealthPort = 9998
$PollIntervalSec = 15
$RequestTimeout  = 5

$cfg = Join-Path $env:USERPROFILE '.windowsmic-bridge\config.ps1'
if (Test-Path $cfg) { . $cfg }

$LogPath = Join-Path $env:LOCALAPPDATA 'windowsmic-bridge\monitor.log'
$LogDir  = [System.IO.Path]::GetDirectoryName($LogPath)
if ($LogDir -and -not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

function Write-MLog {
    param([string]$Line)
    try {
        if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 1MB)) {
            Move-Item -Force $LogPath "$LogPath.1"
        }
        ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Line) |
            Out-File -FilePath $LogPath -Append -Encoding utf8
    } catch { }
}

if (-not $LinuxHost) {
    Write-MLog "ERROR: \$LinuxHost not set in $cfg -- monitor exiting"
    exit 1
}

$Url = "http://${LinuxHost}:${LinuxHealthPort}/health"
Write-MLog ("monitor started, polling {0} every {1}s" -f $Url, $PollIntervalSec)

$lastZombieAt = $null

while ($true) {
    try {
        $resp = Invoke-RestMethod -Uri $Url -TimeoutSec $RequestTimeout -ErrorAction Stop

        # zombie_likely is the canonical actionable flag computed by Linux.
        $zombie = $false
        if ($resp -and $resp.audio -and $resp.audio.PSObject.Properties.Name -contains 'zombie_likely') {
            $zombie = [bool]$resp.audio.zombie_likely
        }

        if ($zombie) {
            $now = Get-Date
            # Linux already de-bounced via SILENT_LIMIT consecutive samples,
            # so a single zombie report is enough to act on. Cooldown after
            # acting so we don't repeatedly kill while the streamer respawns.
            if (-not $lastZombieAt -or ($now - $lastZombieAt).TotalSeconds -ge 30) {
                Write-MLog ("Linux reports zombie_likely=true (peak={0}, streak={1}/{2}, last_sample={3})" `
                    -f $resp.audio.last_peak, `
                       $resp.audio.consecutive_silent, `
                       $resp.config.silent_limit, `
                       $resp.audio.last_sample_at)
                $procs = @(Get-Process ffmpeg -ErrorAction SilentlyContinue)
                if ($procs.Count -eq 0) {
                    Write-MLog "  no ffmpeg process found to kill (already gone?)"
                } else {
                    foreach ($p in $procs) {
                        try {
                            Stop-Process -Id $p.Id -Force -ErrorAction Stop
                            Write-MLog ("  killed ffmpeg PID {0}" -f $p.Id)
                        } catch {
                            Write-MLog ("  kill PID {0} failed: {1}" -f $p.Id, $_.Exception.Message)
                        }
                    }
                }
                $lastZombieAt = $now
            }
        } else {
            if ($lastZombieAt) {
                Write-MLog "Linux now reports healthy stream"
                $lastZombieAt = $null
            }
        }
    } catch {
        Write-MLog ("poll failed: {0}" -f $_.Exception.Message)
    }
    Start-Sleep -Seconds $PollIntervalSec
}
