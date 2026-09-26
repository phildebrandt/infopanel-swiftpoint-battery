# package.ps1 - build the Swiftpoint Battery plugin, zip it, and deploy it to InfoPanel.
# Run from an ADMIN PowerShell (InfoPanel runs elevated, and ProgramData\InfoPanel may need admin):
#   powershell -ExecutionPolicy Bypass -File package.ps1            # build + zip + deploy
#   powershell -ExecutionPolicy Bypass -File package.ps1 -NoDeploy  # build + zip only
#
# Deploy step: stops InfoPanel if it's running (its DLL lock would block the copy),
# replaces plugins\InfoPanel.SwiftpointBattery\ with the fresh build, then relaunches InfoPanel.

param([switch]$NoDeploy)

$ErrorActionPreference = "Stop"

$projectDir = $PSScriptRoot
$publishDir = Join-Path $projectDir "bin\publish"
$pluginName = "InfoPanel.SwiftpointBattery"
$zipName    = "$pluginName.zip"
$folderName = $pluginName
$pluginsDir = Join-Path $env:ProgramData "InfoPanel\plugins"
$deployDir  = Join-Path $pluginsDir $folderName

# Clean stale build artifacts first
Write-Host "Cleaning previous build..." -ForegroundColor DarkGray
Remove-Item -Recurse -Force "$projectDir\obj", "$projectDir\bin" -ErrorAction SilentlyContinue

Write-Host "Building plugin..." -ForegroundColor Cyan
dotnet publish "$projectDir\SwiftpointBatteryPlugin.csproj" `
    -c Release `
    -o $publishDir `
    --no-self-contained

if ($LASTEXITCODE -ne 0) { throw "Build failed" }

# Files that make up the plugin: every DLL except InfoPanel.Plugins.dll, plus PluginInfo.ini
$pluginFiles = @(Get-ChildItem "$publishDir" -Filter "*.dll" -File | Where-Object { $_.Name -ne "InfoPanel.Plugins.dll" })
$pluginFiles += Get-Item "$projectDir\PluginInfo.ini"

# Build zip
$zipPath = Join-Path $projectDir $zipName
if (Test-Path $zipPath) { Remove-Item $zipPath }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
foreach ($f in $pluginFiles) {
    $entryName = "$folderName/$($f.Name)"   # zip spec requires forward slashes
    Write-Host "  Adding: $entryName"
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $entryName) | Out-Null
}
$zip.Dispose()
Write-Host "Created: $zipPath" -ForegroundColor Green

if ($NoDeploy) { return }

# ---- Deploy ------------------------------------------------------------------
Write-Host ""
Write-Host "Deploying to $deployDir ..." -ForegroundColor Cyan

$ip = Get-Process -Name "InfoPanel" -ErrorAction SilentlyContinue | Select-Object -First 1
$ipExe = $null
if ($ip) {
    try { $ipExe = $ip.Path } catch { }
    Write-Host "  Stopping InfoPanel..."
    try {
        Stop-Process -Id $ip.Id -Force
    } catch {
        throw "Couldn't stop InfoPanel (it probably runs as admin). Re-run this script from an admin PowerShell."
    }
    $ip.WaitForExit(10000) | Out-Null
    Start-Sleep -Milliseconds 500
}

try {
    if (Test-Path $deployDir) { Remove-Item -Recurse -Force $deployDir }
    New-Item -ItemType Directory -Path $deployDir -Force | Out-Null
    foreach ($f in $pluginFiles) {
        Copy-Item -LiteralPath $f.FullName -Destination $deployDir -Force
        Write-Host "  Copied: $($f.Name)"
    }
    Write-Host "Deployed." -ForegroundColor Green
}
catch [System.UnauthorizedAccessException] {
    throw "Access denied writing to $pluginsDir. Re-run this script from an admin PowerShell."
}
finally {
    if ($ip) {
        if (-not $ipExe) {
            $ipExe = @("$env:ProgramFiles\InfoPanel\InfoPanel.exe", "${env:ProgramFiles(x86)}\InfoPanel\InfoPanel.exe") |
                     Where-Object { Test-Path $_ } | Select-Object -First 1
        }
        if ($ipExe) {
            Write-Host "  Relaunching InfoPanel..."
            Start-Process -FilePath $ipExe -WorkingDirectory (Split-Path $ipExe)
        } else {
            Write-Host "  Couldn't find InfoPanel.exe - start it manually." -ForegroundColor Yellow
        }
    }
}
