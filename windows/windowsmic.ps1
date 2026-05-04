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

# Self-hide our own console window. Windows 11 ConPTY ignores
# `powershell.exe -WindowStyle Hidden` for scheduled tasks, so the host
# console (class PseudoConsoleWindow) stays visible no matter what
# install.ps1 / wscript wrapper sets. The Win32 call below hides our
# own conhost window unconditionally and works without admin.
Add-Type -Name __Hide -Namespace __WMB -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]   public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@ -ErrorAction SilentlyContinue
try {
    $__h = [__WMB.__Hide]::GetConsoleWindow()
    if ($__h -ne [System.IntPtr]::Zero) { [void][__WMB.__Hide]::ShowWindow($__h, 0) }  # SW_HIDE = 0
} catch { }

$LinuxHost  = ''                # set in config.ps1 (e.g. '192.0.2.10')
$LinuxPort  = 9999
$MicPattern = 'Yamaha AG06'

$cfg = Join-Path $env:USERPROFILE '.windowsmic-bridge\config.ps1'
if (Test-Path $cfg) { . $cfg }

if (-not $LinuxHost) {
    Write-Host "ERROR: \$LinuxHost not set. Create $cfg with: \$LinuxHost = '<linux-ip>'"
    exit 1
}

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

while ($true) {
    $MicName = Resolve-MicName -Pattern $MicPattern
    if (-not $MicName) {
        Write-Host ("[{0}] no audio device matching '{1}' -- retrying in 5s" -f (Get-Date -Format HH:mm:ss), $MicPattern)
        Start-Sleep -Seconds 5
        continue
    }

    Write-Host ("[{0}] streaming '{1}' -> {2}:{3}" -f (Get-Date -Format HH:mm:ss), $MicName, $LinuxHost, $LinuxPort)

    [void](Start-FFmpegHidden -FFmpegArgs @(
        '-hide_banner','-loglevel','warning',
        '-f','dshow','-i',"audio=$MicName",
        '-acodec','pcm_s16le','-ar','48000','-ac','1',
        '-f','s16le',"tcp://${LinuxHost}:${LinuxPort}"
    ))

    Write-Host ("[{0}] stream ended, re-resolving device in 1s..." -f (Get-Date -Format HH:mm:ss))
    Start-Sleep -Seconds 1
}
