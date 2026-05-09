# Installs the Windows side: copies scripts to C:\windowsmic-bridge\, seeds
# the user config, registers scheduled tasks, registers the http urlacl so
# the unprivileged health PS1 can bind http://+:9998/, and opens the inbound
# firewall port for /health.
# Run from an elevated PowerShell at the repo root.

[CmdletBinding()]
param(
    [int]$WindowsHealthPort = 9998
)

$ErrorActionPreference = 'Stop'

$dst = 'C:\windowsmic-bridge'
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item -Force "$PSScriptRoot\windowsmic.ps1"          "$dst\windowsmic.ps1"
Copy-Item -Force "$PSScriptRoot\windowsmic-guardian.ps1" "$dst\windowsmic-guardian.ps1"
Copy-Item -Force "$PSScriptRoot\windowsmic-launcher.vbs" "$dst\windowsmic-launcher.vbs"
Copy-Item -Force "$PSScriptRoot\windowsmic-health.ps1"   "$dst\windowsmic-health.ps1"
Copy-Item -Force "$PSScriptRoot\windowsmic-monitor.ps1"  "$dst\windowsmic-monitor.ps1"

$cfgDir  = Join-Path $env:USERPROFILE '.windowsmic-bridge'
$cfgFile = Join-Path $cfgDir 'config.ps1'
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
if (-not (Test-Path $cfgFile)) {
    Copy-Item "$PSScriptRoot\config.example.ps1" $cfgFile
    Write-Host "==> Edit $cfgFile and set `$LinuxHost"
}

# ---- HTTP urlacl + firewall (so the unprivileged scheduled task can bind +:port and accept LAN traffic) ----
$urlacl    = "http://+:$WindowsHealthPort/"
$userSpec  = "$env:USERDOMAIN\$env:USERNAME"
# Best effort: clear any stale registration, then add fresh.
& netsh http delete urlacl url=$urlacl 2>$null | Out-Null
& netsh http add    urlacl url=$urlacl user=$userSpec | Out-Null
Write-Host ("==> registered urlacl {0} for {1}" -f $urlacl, $userSpec)

$ruleName = 'WindowsMicHealth-Inbound'
if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name $ruleName -DisplayName 'WindowsMic Health (inbound TCP)' `
        -Direction Inbound -Protocol TCP -LocalPort $WindowsHealthPort `
        -Action Allow -Profile Any | Out-Null
    Write-Host ("==> added firewall rule {0} for TCP/{1}" -f $ruleName, $WindowsHealthPort)
} else {
    Set-NetFirewallRule -Name $ruleName -LocalPort $WindowsHealthPort -Action Allow -Profile Any | Out-Null
}

# ---- shared trigger + settings ----
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -MultipleInstances IgnoreNew `
    -Hidden

# ---- streamer (unchanged: launched via wscript so the host PS never owns a console) ----
$streamerAction = New-ScheduledTaskAction `
    -Execute 'wscript.exe' `
    -Argument "`"$dst\windowsmic-launcher.vbs`""
Register-ScheduledTask `
    -TaskName 'WindowsMicStream' `
    -Action $streamerAction `
    -Trigger $trigger `
    -Settings $settings `
    -RunLevel Limited `
    -Force | Out-Null
Start-ScheduledTask -TaskName 'WindowsMicStream'
Write-Host "==> WindowsMicStream task registered and started"

# ---- guardian (re-runs streamer if its detached child crashes) ----
$guardianAction = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dst\windowsmic-guardian.ps1`""
Register-ScheduledTask `
    -TaskName 'WindowsMicGuardian' `
    -Action $guardianAction `
    -Trigger $trigger `
    -Settings $settings `
    -RunLevel Limited `
    -Force | Out-Null
Start-ScheduledTask -TaskName 'WindowsMicGuardian'
Write-Host "==> WindowsMicGuardian task registered and started"

# ---- health (HTTP /health endpoint) ----
$healthAction = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dst\windowsmic-health.ps1`""
Register-ScheduledTask `
    -TaskName 'WindowsMicHealth' `
    -Action $healthAction `
    -Trigger $trigger `
    -Settings $settings `
    -RunLevel Limited `
    -Force | Out-Null
Start-ScheduledTask -TaskName 'WindowsMicHealth'
Write-Host "==> WindowsMicHealth task registered and started"

# ---- monitor (polls Linux /health, self-kills ffmpeg on zombie report) ----
$monitorAction = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dst\windowsmic-monitor.ps1`""
Register-ScheduledTask `
    -TaskName 'WindowsMicMonitor' `
    -Action $monitorAction `
    -Trigger $trigger `
    -Settings $settings `
    -RunLevel Limited `
    -Force | Out-Null
Start-ScheduledTask -TaskName 'WindowsMicMonitor'
Write-Host "==> WindowsMicMonitor task registered and started"

Write-Host ""
Write-Host "==> Verify with:"
Write-Host ("    Invoke-RestMethod http://127.0.0.1:{0}/health | ConvertTo-Json -Depth 6" -f $WindowsHealthPort)
Write-Host "    schtasks /Query /TN WindowsMicStream  /V /FO LIST | Select-String 'Status|Last'"
Write-Host "    schtasks /Query /TN WindowsMicMonitor /V /FO LIST | Select-String 'Status|Last'"
