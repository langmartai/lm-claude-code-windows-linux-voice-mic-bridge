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
#
# All ffmpeg invocations go through [Diagnostics.Process] with
# CreateNoWindow=$true so the streamer never owns a visible console, and
# stderr is captured via the redirected pipe rather than PS5.1 `2>&1` (which
# would wrap each stderr line as a NativeCommandError and abort the script
# under $ErrorActionPreference = 'Stop').
#
# File MUST stay 7-bit ASCII. Without a UTF-8 BOM, PS5.1 reads non-ASCII
# bytes through the OEM/ANSI code page and the parser blows up on smart
# punctuation (em-dash, curly quotes). Use ASCII double-hyphen, not the
# em-dash codepoint U+2014.

$ErrorActionPreference = 'Stop'

# Self-detach.
#
# Windows 11 ConPTY ignores `powershell.exe -WindowStyle Hidden` for
# scheduled tasks: the visible terminal isn't owned by our own
# conhost (which we could hide with ShowWindow) but by a separate
# WindowsTerminal.exe process we cannot reach. Re-registering the task to
# launch via wscript.exe + .vbs would solve it, but that needs admin.
#
# Instead, on the first invocation we re-launch ourselves via
# [Diagnostics.Process]::Start with CreateNoWindow=$true and exit. The
# child gets no console window at all (no ConPTY hand-off, no Windows
# Terminal tab) and runs the actual streaming loop. The original
# task-spawned powershell exits 0 immediately, which closes its terminal
# and does NOT trigger task-scheduler RestartOnFailure (that only fires on
# non-zero exit codes).
#
# WINDOWSMIC_DETACHED short-circuits the relaunch on the child run so we
# don't fork forever.
if (-not $env:WINDOWSMIC_DETACHED) {
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
        # Indexer assignment, not .Add(): tolerates the var already being set.
        $psi.EnvironmentVariables['WINDOWSMIC_DETACHED'] = '1'
        [void][System.Diagnostics.Process]::Start($psi)
        exit 0
    }
}

# Multi-target: $LinuxTargets is the primary form
#   $LinuxTargets = @(
#       @{ Host = '192.0.2.10'; Port = 9999; HealthPort = 9998 },
#       @{ Host = '192.0.2.11'; Port = 9999; HealthPort = 9998 }
#   )
# Legacy single-target ($LinuxHost / $LinuxPort) is still accepted and is
# converted to a one-element $LinuxTargets list at runtime.
$LinuxTargets    = $null
$LinuxHost       = ''
$LinuxPort       = 9999
$LinuxHealthPort = 9998
$MicPattern      = 'Yamaha AG06'

$cfg = Join-Path $env:USERPROFILE '.windowsmic-bridge\config.ps1'
if (Test-Path $cfg) { . $cfg }

if (-not $LinuxTargets -or $LinuxTargets.Count -eq 0) {
    if ($LinuxHost) {
        $LinuxTargets = @(@{ Host = $LinuxHost; Port = $LinuxPort; HealthPort = $LinuxHealthPort })
    } else {
        Write-Host "ERROR: neither \$LinuxTargets nor \$LinuxHost set in $cfg"
        exit 1
    }
}

# Normalize: every target must have Host + Port; HealthPort defaults to 9998.
$normalized = @()
foreach ($t in $LinuxTargets) {
    if (-not $t.Host) { Write-Host "ERROR: target missing Host: $($t | ConvertTo-Json -Compress)"; exit 1 }
    if (-not $t.Port) { $t.Port = 9999 }
    if (-not $t.HealthPort) { $t.HealthPort = 9998 }
    $normalized += $t
}
$LinuxTargets = $normalized

function Quote-Arg {
    param([string]$a)
    if ($a -match '[\s"]') { return '"' + ($a -replace '"','\"') + '"' }
    return $a
}

function Start-FFmpegHidden {
    param([string[]]$FFmpegArgs, [switch]$CaptureStderr)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'ffmpeg'
    $psi.Arguments              = ($FFmpegArgs | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($CaptureStderr) {
        $stderr = $p.StandardError.ReadToEnd()
        [void]$p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        return $stderr
    }
    # Long-running invocation: drain both pipes asynchronously so the OS
    # buffers never fill and block ffmpeg.
    $null = $p.StandardOutput.BaseStream.CopyToAsync([System.IO.Stream]::Null)
    $null = $p.StandardError.BaseStream.CopyToAsync([System.IO.Stream]::Null)
    $p.WaitForExit()
    return $p.ExitCode
}

function Resolve-MicName {
    param([string]$Pattern)
    $listing     = Start-FFmpegHidden -CaptureStderr -FFmpegArgs @(
        '-hide_banner','-list_devices','true','-f','dshow','-i','dummy'
    )
    $regexString = '"([^"]*' + [regex]::Escape($Pattern) + '[^"]*)"\s*\(audio\)'
    $m           = [regex]::Match($listing, $regexString)
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Build-OutputArgs {
    param($Targets)
    if ($Targets.Count -eq 1) {
        $t = $Targets[0]
        return @('-f', 's16le', ("tcp://{0}:{1}" -f $t.Host, $t.Port))
    }
    # Tee muxer with onfail=ignore per output: a single dead/slow receiver
    # does not stall the others. URL parts contain ':' but that's fine because
    # the tee parser splits on '|' between outputs and ']' between options/URL.
    $parts = @()
    foreach ($t in $Targets) {
        $parts += ("[f=s16le:onfail=ignore]tcp://{0}:{1}" -f $t.Host, $t.Port)
    }
    return @('-map', '0:a', '-f', 'tee', ($parts -join '|'))
}

$targetsDesc = ($LinuxTargets | ForEach-Object { "{0}:{1}" -f $_.Host, $_.Port }) -join ', '

while ($true) {
    $MicName = Resolve-MicName -Pattern $MicPattern
    if (-not $MicName) {
        Write-Host ("[{0}] no audio device matching '{1}' -- retrying in 5s" -f (Get-Date -Format HH:mm:ss), $MicPattern)
        Start-Sleep -Seconds 5
        continue
    }

    Write-Host ("[{0}] streaming '{1}' -> {2}" -f (Get-Date -Format HH:mm:ss), $MicName, $targetsDesc)

    $ffArgs = @(
        '-hide_banner','-loglevel','warning',
        '-f','dshow','-i',"audio=$MicName",
        '-acodec','pcm_s16le','-ar','48000','-ac','1'
    ) + (Build-OutputArgs -Targets $LinuxTargets)

    [void](Start-FFmpegHidden -FFmpegArgs $ffArgs)

    Write-Host ("[{0}] stream ended, re-resolving device in 1s..." -f (Get-Date -Format HH:mm:ss))
    Start-Sleep -Seconds 1
}
