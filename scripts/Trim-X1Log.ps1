# Trim-X1Log.ps1 - removes Swiftpoint X1 Control Panel log entries older than N days.
#
# X1 keeps log.txt open while it runs, so the file can't safely be rewritten
# underneath it. If X1 is running (and there is something to trim), this script
# stops X1, rewrites the log, and relaunches X1 using the same command line as
# its Windows startup entry. The mouse keeps working while X1 is closed
# (profiles live on the mouse), and the InfoPanel plugin detects the shorter
# file and rescans automatically.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File Trim-X1Log.ps1 -Days 7 -DryRun   # report only
#   powershell -ExecutionPolicy Bypass -File Trim-X1Log.ps1 -Days 7           # trim

param(
    [int]$Days = 7,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$logDir     = Join-Path $env:LOCALAPPDATA 'Swiftpoint X1 Control Panel'
$log        = Join-Path $logDir 'log.txt'
$procName   = 'Swiftpoint X1 Control Panel'
$defaultExe = 'C:\Program Files\Swiftpoint X1 Control Panel\Swiftpoint X1 Control Panel.exe'

if (-not (Test-Path $log)) { Write-Host "No X1 log found at $log"; return }

$cutoff = (Get-Date).AddDays(-$Days)
$tsRx   = [regex]'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})'
$inv    = [Globalization.CultureInfo]::InvariantCulture

function Get-LineTime([string]$line) {
    $m = $tsRx.Match($line)
    if (-not $m.Success) { return $null }
    return [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-ddTHH:mm:ss', $inv)
}

function Open-SharedReader([string]$path) {
    $fs = [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                               [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    return [IO.StreamReader]::new($fs, [Text.Encoding]::UTF8)
}

# --- Pass 1: count what would be dropped (safe while X1 is running) -------------
$dropLines = 0; $totalLines = 0; $firstKept = $null
$r = Open-SharedReader $log
try {
    $keeping = $false
    while ($null -ne ($line = $r.ReadLine())) {
        $totalLines++
        if (-not $keeping) {
            $t = Get-LineTime $line
            if ($null -ne $t -and $t -ge $cutoff) { $keeping = $true; $firstKept = $t }
        }
        if (-not $keeping) { $dropLines++ }
    }
} finally { $r.Dispose() }

$sizeMB = [math]::Round((Get-Item $log).Length / 1MB, 2)
Write-Host "Log: $sizeMB MB, $totalLines lines. Cutoff: $($cutoff.ToString('yyyy-MM-dd HH:mm'))."
Write-Host "Would remove $dropLines lines older than $Days days."

if ($dropLines -eq 0) { Write-Host "Nothing to trim."; return }
if ($dropLines -eq $totalLines) { Write-Host "Every line is older than the cutoff - keeping the log as-is rather than emptying it."; return }
if ($DryRun) { Write-Host "Dry run - no changes made."; return }

# --- Find how X1 is normally launched (so relaunch matches startup) -------------
$exe = $defaultExe; $exeArgs = ''
$runKeys = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
           'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
           'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
foreach ($k in $runKeys) {
    $props = Get-ItemProperty $k -ErrorAction SilentlyContinue
    if (-not $props) { continue }
    $cmd = $props.PSObject.Properties | Where-Object { "$($_.Value)" -match 'Swiftpoint X1' } |
           Select-Object -First 1 -ExpandProperty Value
    if ($cmd) {
        if ($cmd -match '^\s*"([^"]+)"\s*(.*)$' -or $cmd -match '^\s*(.+?\.exe)\s*(.*)$') {
            $exe = $Matches[1]; $exeArgs = $Matches[2].Trim()
        }
        break
    }
}

# --- Stop X1, rewrite, relaunch -----------------------------------------------
$wasRunning = [bool](Get-Process -Name $procName -ErrorAction SilentlyContinue)
if ($wasRunning) {
    Write-Host "Stopping X1..."
    Stop-Process -Name $procName -Force
    Start-Sleep -Seconds 2
}

try {
    $tmp = "$log.trimming"
    $r = Open-SharedReader $log
    $w = [IO.StreamWriter]::new($tmp, $false, [Text.UTF8Encoding]::new($false))
    try {
        $keeping = $false
        while ($null -ne ($line = $r.ReadLine())) {
            if (-not $keeping) {
                $t = Get-LineTime $line
                if ($null -ne $t -and $t -ge $cutoff) { $keeping = $true }
            }
            if ($keeping) { $w.WriteLine($line) }
        }
    } finally { $r.Dispose(); $w.Dispose() }

    Move-Item -LiteralPath $tmp -Destination $log -Force
    $newMB = [math]::Round((Get-Item $log).Length / 1MB, 2)
    Write-Host "Trimmed: $sizeMB MB -> $newMB MB (log now starts $($firstKept.ToString('yyyy-MM-dd HH:mm')))."
}
finally {
    if (Test-Path "$log.trimming") { Remove-Item "$log.trimming" -Force -ErrorAction SilentlyContinue }
    if ($wasRunning) {
        Write-Host "Relaunching X1..."
        if ($exeArgs) { Start-Process -FilePath $exe -ArgumentList $exeArgs -WorkingDirectory (Split-Path $exe) }
        else          { Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) }
    }
}
