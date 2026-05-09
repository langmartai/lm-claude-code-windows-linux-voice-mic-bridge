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

$LinuxTargets    = $null
$LinuxHost       = ''
$LinuxPort       = 9999
$LinuxHealthPort = 9998
$PollIntervalSec = 15
$RequestTimeout  = 5

$cfg = Join-Path $env:USERPROFILE '.windowsmic-bridge\config.ps1'
if (Test-Path $cfg) { . $cfg }

if (-not $LinuxTargets -or $LinuxTargets.Count -eq 0) {
    if ($LinuxHost) {
        $LinuxTargets = @(@{ Host = $LinuxHost; Port = $LinuxPort; HealthPort = $LinuxHealthPort })
    }
}
$normalized = @()
foreach ($t in $LinuxTargets) {
    if (-not $t.Host) { continue }
    if (-not $t.Port) { $t.Port = 9999 }
    if (-not $t.HealthPort) { $t.HealthPort = 9998 }
    $normalized += $t
}
$LinuxTargets = $normalized

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

if ($LinuxTargets.Count -eq 0) {
    Write-MLog "ERROR: no Linux targets configured (set \$LinuxTargets or \$LinuxHost in $cfg) -- monitor exiting"
    exit 1
}

$targetsDesc = ($LinuxTargets | ForEach-Object { "{0}:{1}" -f $_.Host, $_.HealthPort }) -join ', '
Write-MLog ("monitor started, polling [{0}] every {1}s" -f $targetsDesc, $PollIntervalSec)

$lastZombieAt = $null

while ($true) {
    # Poll every target. Any zombie_likely=true is enough to act -- the streamer
    # is one ffmpeg with a single dshow handle, so if any consumer reports
    # silence-while-connected, the upstream capture is broken and ALL targets
    # are affected (some may just not have accumulated SILENT_LIMIT samples yet).
    $reports = @()  # list of @{Host;Why}
    foreach ($t in $LinuxTargets) {
        $url = "http://{0}:{1}/health" -f $t.Host, $t.HealthPort
        try {
            $resp = Invoke-RestMethod -Uri $url -TimeoutSec $RequestTimeout -ErrorAction Stop
            $zombie = $false
            if ($resp -and $resp.audio -and $resp.audio.PSObject.Properties.Name -contains 'zombie_likely') {
                $zombie = [bool]$resp.audio.zombie_likely
            }
            if ($zombie) {
                $reports += @{
                    Host   = $t.Host
                    Peak   = $resp.audio.last_peak
                    Streak = $resp.audio.consecutive_silent
                    Limit  = $resp.config.silent_limit
                }
            }
        } catch {
            Write-MLog ("poll {0} failed: {1}" -f $url, $_.Exception.Message)
        }
    }

    if ($reports.Count -gt 0) {
        $now = Get-Date
        if (-not $lastZombieAt -or ($now - $lastZombieAt).TotalSeconds -ge 30) {
            foreach ($r in $reports) {
                Write-MLog ("zombie_likely from {0} (peak={1}, streak={2}/{3})" -f $r.Host, $r.Peak, $r.Streak, $r.Limit)
            }
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
            Write-MLog "all targets now report healthy stream"
            $lastZombieAt = $null
        }
    }
    Start-Sleep -Seconds $PollIntervalSec
}
