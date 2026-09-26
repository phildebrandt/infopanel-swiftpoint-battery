# Install-TrimTask.ps1 - registers a scheduled task that runs Trim-X1Log.ps1
# at logon (after a 2 minute delay) and daily at 4:00 AM.
# Run from a normal (non-admin) PowerShell so the task runs as you, in your session.
#   powershell -ExecutionPolicy Bypass -File Install-TrimTask.ps1 -Days 7
# To remove:  Unregister-ScheduledTask -TaskName 'Trim Swiftpoint X1 Log' -Confirm:$false

param([int]$Days = 7)

$script = Join-Path $PSScriptRoot 'Trim-X1Log.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Days $Days"

$atLogon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$atLogon.Delay = 'PT2M'
$daily = New-ScheduledTaskTrigger -Daily -At 4:00am

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

Register-ScheduledTask -TaskName 'Trim Swiftpoint X1 Log' -Action $action `
    -Trigger @($atLogon, $daily) -Settings $settings -Force `
    -Description "Removes Swiftpoint X1 Control Panel log entries older than $Days days." | Out-Null

Write-Host "Scheduled task 'Trim Swiftpoint X1 Log' installed (keeps $Days days; runs at logon + 4:00 AM)." -ForegroundColor Green
