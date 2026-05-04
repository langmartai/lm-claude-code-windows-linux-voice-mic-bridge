# Guardian for windowsmic.ps1.
#
# Why: when the streaming powershell self-detaches (via [Diagnostics.Process]::Start
# CreateNoWindow=$true) and the original task-launched powershell exits 0, Task
# Scheduler considers the task complete. RestartOnFailure only triggers on
# non-zero exits, so a crash of the detached child is NOT auto-recovered until
# the next Windows logon. This guardian fills that gap: every 60 s it checks
# whether a windowsmic.ps1 powershell is alive and, if not, kills any orphan
# ffmpeg children (which survive the parent and would otherwise block the new
# instance from grabbing the dshow device) and re-runs the streamer task.
#
# Self-detach + ASCII-only same as windowsmic.ps1 -- see those notes.

$ErrorActionPreference = 'Stop'

if (-not $env:WINDOWSMIC_GUARDIAN_DETACHED) {
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
        $psi.EnvironmentVariables['WINDOWSMIC_GUARDIAN_DETACHED'] = '1'
        [void][System.Diagnostics.Process]::Start($psi)
        exit 0
    }
}

# ---- main guardian loop (runs only in the detached child) ----

$StreamerScriptPattern = 'windowsmic\.ps1'         # match either C:\temp\... or C:\windowsmic-bridge\...
$StreamerTaskName      = 'WindowsMicStream'
$OrphanFFmpegPattern   = 'audio=Yamaha|tcp://[0-9.]+:9999'
$CheckIntervalSec      = 60

# Optional log (rolled at ~1 MB) so we can see what the guardian did. Empty path = no log.
$LogPath = Join-Path $env:LOCALAPPDATA 'windowsmic-bridge\guardian.log'
$LogDir  = [System.IO.Path]::GetDirectoryName($LogPath)
if ($LogDir -and -not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

function Write-GLog {
    param([string]$Line)
    if (-not $LogPath) { return }
    try {
        if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 1MB)) {
            Move-Item -Force $LogPath "$LogPath.1"
        }
        ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Line) |
            Out-File -FilePath $LogPath -Append -Encoding utf8
    } catch { }
}

Write-GLog "guardian started, checking every ${CheckIntervalSec}s"

while ($true) {
    try {
        $live = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                  Where-Object { $_.CommandLine -and ($_.CommandLine -match $StreamerScriptPattern) -and ($_.ProcessId -ne $PID) })

        if (-not $live -or $live.Count -eq 0) {
            Write-GLog "no streamer alive; cleaning orphan ffmpegs and re-running task"

            $orphans = @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue |
                         Where-Object { $_.CommandLine -and ($_.CommandLine -match $OrphanFFmpegPattern) })
            foreach ($o in $orphans) {
                try { Stop-Process -Id $o.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
                Write-GLog ("  killed orphan ffmpeg PID {0}" -f $o.ProcessId)
            }
            Start-Sleep -Seconds 1

            $r = & schtasks.exe /Run /TN $StreamerTaskName 2>&1 | Out-String
            Write-GLog ("  schtasks /Run output: {0}" -f $r.Trim())
        }
    }
    catch {
        Write-GLog ("loop error: {0}" -f $_.Exception.Message)
    }
    Start-Sleep -Seconds $CheckIntervalSec
}
