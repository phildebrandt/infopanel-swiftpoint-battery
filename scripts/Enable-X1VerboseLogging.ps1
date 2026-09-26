# Enable-X1VerboseLogging.ps1 - one-time setup for the Swiftpoint Battery InfoPanel plugin.
#
# Turns on two settings in Swiftpoint X1 Control Panel's settings.ini:
#   VerboseLogging=true  (required - X1 only writes battery values to its log in verbose mode)
#   X1API=true           (optional - lets the plugin read the active profile right after X1 starts)
# X1 rewrites settings.ini when it exits, so this script closes X1 first, edits the file,
# then relaunches X1 the same way Windows starts it at logon.
#
# Usage:  powershell -ExecutionPolicy Bypass -File Enable-X1VerboseLogging.ps1
#         powershell -ExecutionPolicy Bypass -File Enable-X1VerboseLogging.ps1 -NoApi
#         powershell -ExecutionPolicy Bypass -File Enable-X1VerboseLogging.ps1 -Disable

param(
    [switch]$NoApi,
    [switch]$Disable
)

$ErrorActionPreference = 'Stop'

$ini        = Join-Path $env:LOCALAPPDATA 'Swiftpoint X1 Control Panel\settings.ini'
$procName   = 'Swiftpoint X1 Control Panel'
$defaultExe = 'C:\Program Files\Swiftpoint X1 Control Panel\Swiftpoint X1 Control Panel.exe'

if (-not (Test-Path $ini)) {
    throw "X1 settings not found at $ini. Install Swiftpoint X1 Control Panel and run it once first."
}

# Find how X1 is normally launched (startup entry), fall back to the default install path
$exe = $defaultExe; $exeArgs = ''
foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
               'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
               'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
    $props = Get-ItemProperty $k -ErrorAction SilentlyContinue
    if (-not $props) { continue }
    $cmd = $props.PSObject.Properties | Where-Object { "$($_.Value)" -match 'Swiftpoint X1' } |
           Select-Object -First 1 -ExpandProperty Value
    if ($cmd -and ($cmd -match '^\s*"([^"]+)"\s*(.*)$' -or $cmd -match '^\s*(.+?\.exe)\s*(.*)$')) {
        $exe = $Matches[1]; $exeArgs = $Matches[2].Trim(); break
    }
}

function Set-IniValue([string[]]$lines, [string]$key, [string]$value) {
    $found = $false
    $out = foreach ($l in $lines) {
        if ($l -match "^\s*$([regex]::Escape($key))\s*=") { $found = $true; "$key=$value" } else { $l }
    }
    if (-not $found) {
        # Append under [General] (X1 keeps all its settings there)
        $out2 = @(); $inserted = $false
        foreach ($l in $out) {
            $out2 += $l
            if (-not $inserted -and $l -match '^\s*\[General\]\s*$') { $out2 += "$key=$value"; $inserted = $true }
        }
        if (-not $inserted) { $out2 += '[General]'; $out2 += "$key=$value" }
        $out = $out2
    }
    return ,$out
}

function Get-UpdatedIni {
    $lines = [IO.File]::ReadAllLines($ini)
    $new = Set-IniValue $lines 'VerboseLogging' $value
    if (-not $NoApi -and -not $Disable) { $new = Set-IniValue $new 'X1API' 'true' }
    return @{ Changed = (($lines -join "`n") -cne ($new -join "`n")); Lines = $new }
}

$value = if ($Disable) { 'false' } else { 'true' }

# Nothing to change -> don't restart X1
if (-not (Get-UpdatedIni).Changed) {
    Write-Host "Already set (VerboseLogging=$value) - nothing to do." -ForegroundColor Green
    return
}

$wasRunning = [bool](Get-Process -Name $procName -ErrorAction SilentlyContinue)
if ($wasRunning) {
    Write-Host 'Closing X1 Control Panel...'
    Stop-Process -Name $procName -Force
    Start-Sleep -Seconds 2
}

# Re-read after X1 is closed, write back as UTF-8 without BOM (Set-Content in PS 5.1 would write ANSI)
[IO.File]::WriteAllLines($ini, [string[]](Get-UpdatedIni).Lines, [Text.UTF8Encoding]::new($false))

Write-Host "VerboseLogging=$value" -ForegroundColor Green
if (-not $NoApi -and -not $Disable) { Write-Host 'X1API=true' -ForegroundColor Green }

Write-Host 'Starting X1 Control Panel...'
if ($exeArgs) { Start-Process -FilePath $exe -ArgumentList $exeArgs -WorkingDirectory (Split-Path $exe) }
else          { Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) }
Write-Host 'Done. Switch the mouse off and on once so X1 logs a fresh battery report.'
