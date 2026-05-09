# HTTP /health endpoint exposing Windows-side observations.
#
# Pure observer/exporter -- mirror of linux/bin/windowsmic-health.py.
# Never modifies anything; the Linux peer reads this for human-side debugging
# and (optionally, future) automation.
#
# Self-detach + ASCII-only: see windowsmic.ps1 header notes.
#
# Bind: HttpListener on http://+:$WindowsHealthPort/. Requires either admin OR
# a pre-registered urlacl. windows/install.ps1 (elevated) registers the urlacl
# for the current user, so this PS1 runs unprivileged from a scheduled task.

$ErrorActionPreference = 'Stop'

if (-not $env:WINDOWSMIC_HEALTH_DETACHED) {
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
        $psi.EnvironmentVariables['WINDOWSMIC_HEALTH_DETACHED'] = '1'
        [void][System.Diagnostics.Process]::Start($psi)
        exit 0
    }
}

# ---- main process (detached child) ----

$LinuxHost         = ''
$LinuxPort         = 9999
$WindowsHealthPort = 9998
$Version           = '0.2.0'

$cfg = Join-Path $env:USERPROFILE '.windowsmic-bridge\config.ps1'
if (Test-Path $cfg) { . $cfg }

$LogPath = Join-Path $env:LOCALAPPDATA 'windowsmic-bridge\health.log'
$LogDir  = [System.IO.Path]::GetDirectoryName($LogPath)
if ($LogDir -and -not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

function Write-HLog {
    param([string]$Line)
    try {
        if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 1MB)) {
            Move-Item -Force $LogPath "$LogPath.1"
        }
        ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Line) |
            Out-File -FilePath $LogPath -Append -Encoding utf8
    } catch { }
}

function Get-FFmpegStatus {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue |
               Where-Object { $_.CommandLine -and ($_.CommandLine -match ("tcp://[0-9.]+:" + [string]$LinuxPort)) })
    $info = @()
    foreach ($p in $procs) {
        $started = $null
        try { $started = (Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue).StartTime } catch { }
        $info += @{
            pid        = $p.ProcessId
            started_at = if ($started) { $started.ToUniversalTime().ToString("o") } else { $null }
        }
    }
    return @{
        alive     = ($procs.Count -gt 0)
        count     = $procs.Count
        processes = $info
    }
}

function Get-TcpStatus {
    try {
        $conns = @(Get-NetTCPConnection -RemotePort $LinuxPort -State Established -ErrorAction SilentlyContinue)
    } catch {
        $conns = @()
    }
    $remotes = @()
    foreach ($c in $conns) { $remotes += ("{0}:{1}" -f $c.RemoteAddress, $c.RemotePort) }
    return @{
        established = ($conns.Count -gt 0)
        count       = $conns.Count
        remotes     = $remotes
    }
}

function Get-StreamerTaskStatus {
    try {
        $rows = & schtasks.exe /Query /TN 'WindowsMicStream' /FO CSV /V 2>$null | ConvertFrom-Csv
        if ($rows -and $rows.Count -gt 0) {
            $r = $rows[0]
            return @{
                status      = $r.Status
                last_run    = $r.'Last Run Time'
                last_result = $r.'Last Result'
                next_run    = $r.'Next Run Time'
            }
        }
    } catch { }
    return @{ status = $null }
}

function Get-Snapshot {
    return @{
        version    = $Version
        pid        = $PID
        host       = $env:COMPUTERNAME
        timestamp  = (Get-Date).ToUniversalTime().ToString("o")
        ffmpeg     = (Get-FFmpegStatus)
        tcp        = (Get-TcpStatus)
        task       = (Get-StreamerTaskStatus)
        config     = @{
            linux_host  = $LinuxHost
            linux_port  = $LinuxPort
            health_port = $WindowsHealthPort
        }
    }
}

# Try '+' first; fall back to localhost+per-IP if no urlacl exists.
function Start-Listener {
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://+:$WindowsHealthPort/")
    try {
        $listener.Start()
        return @{ listener = $listener; bound = "http://+:$WindowsHealthPort/" }
    } catch {
        Write-HLog ("HttpListener '+' failed: {0} -- falling back to per-IP" -f $_.Exception.Message)
    }
    $listener = New-Object System.Net.HttpListener
    $bound = @()
    foreach ($ip in @('127.0.0.1') + (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                       Where-Object { $_.IPAddress -ne '127.0.0.1' } | Select-Object -ExpandProperty IPAddress)) {
        $url = "http://${ip}:${WindowsHealthPort}/"
        try { $listener.Prefixes.Add($url); $bound += $url } catch { }
    }
    $listener.Start()
    return @{ listener = $listener; bound = ($bound -join ', ') }
}

$startInfo = Start-Listener
$listener  = $startInfo.listener
Write-HLog ("listening on {0}" -f $startInfo.bound)

while ($listener.IsListening) {
    try {
        $ctx  = $listener.GetContext()
        $resp = $ctx.Response
        $req  = $ctx.Request
        $path = $req.Url.AbsolutePath.TrimEnd('/')
        if (-not $path) { $path = '/' }
        try {
            $status = 200
            if ($path -eq '/' -or $path -eq '/health') {
                $body = (Get-Snapshot | ConvertTo-Json -Depth 6)
            } elseif ($path -eq '/version') {
                $body = (@{ version = $Version } | ConvertTo-Json)
            } else {
                $status = 404
                $body   = '{"error":"not found"}'
            }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
            $resp.StatusCode      = $status
            $resp.ContentType     = 'application/json'
            $resp.ContentLength64 = $bytes.Length
            $resp.OutputStream.Write($bytes, 0, $bytes.Length)
        } finally {
            try { $resp.OutputStream.Close() } catch { }
        }
    } catch {
        Write-HLog ("request error: {0}" -f $_.Exception.Message)
    }
}
