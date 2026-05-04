# Installs the Windows side: copies scripts to C:\windowsmic-bridge\, seeds
# the user config, registers a scheduled task that runs at logon with the
# correct resilience settings (no battery cutoff, restart-on-failure).
# The task is launched via wscript.exe + a .vbs wrapper so the streaming
# powershell never owns a visible console window.
# Run from an elevated PowerShell at the repo root.

$ErrorActionPreference = 'Stop'

$dst = 'C:\windowsmic-bridge'
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item -Force "$PSScriptRoot\windowsmic.ps1"          "$dst\windowsmic.ps1"
Copy-Item -Force "$PSScriptRoot\windowsmic-launcher.vbs" "$dst\windowsmic-launcher.vbs"

$cfgDir  = Join-Path $env:USERPROFILE '.windowsmic-bridge'
$cfgFile = Join-Path $cfgDir 'config.ps1'
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
if (-not (Test-Path $cfgFile)) {
    Copy-Item "$PSScriptRoot\config.example.ps1" $cfgFile
    Write-Host "==> Edit $cfgFile and set `$LinuxHost"
}

$action   = New-ScheduledTaskAction `
    -Execute 'wscript.exe' `
    -Argument "`"$dst\windowsmic-launcher.vbs`""
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -MultipleInstances IgnoreNew `
    -Hidden

Register-ScheduledTask `
    -TaskName 'WindowsMicStream' `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -RunLevel Limited `
    -Force | Out-Null

Start-ScheduledTask -TaskName 'WindowsMicStream'
Write-Host "==> WindowsMicStream task registered and started"
