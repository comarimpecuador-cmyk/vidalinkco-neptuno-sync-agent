[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateRange(1, 1440)]
    [int]$SyncIntervalMinutes = 30,

    [Parameter()]
    [ValidateRange(1, 1440)]
    [int]$HeartbeatIntervalMinutes = 5,

    [Parameter()]
    [string]$TaskUser,

    [Parameter()]
    [switch]$RunWithHighestPrivileges
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent $PSScriptRoot
$syncLauncherPath = Join-Path $PSScriptRoot "run-neptuno-sync-production.vbs"
$heartbeatLauncherPath = Join-Path $PSScriptRoot "run-neptuno-heartbeat-production.vbs"
$wscriptPath = Join-Path $env:SystemRoot "System32/wscript.exe"

if (-not [System.IO.File]::Exists($syncLauncherPath)) {
    throw "Sync VBS launcher was not found: $syncLauncherPath"
}
if (-not [System.IO.File]::Exists($heartbeatLauncherPath)) {
    throw "Heartbeat VBS launcher was not found: $heartbeatLauncherPath"
}
if (-not [System.IO.File]::Exists($wscriptPath)) {
    throw "wscript.exe was not found: $wscriptPath"
}

function New-NeptunoScheduledTaskPrincipal {
    param([Parameter()][string]$User)

    $runLevel = if ($RunWithHighestPrivileges) { "Highest" } else { "Limited" }
    if ([string]::IsNullOrWhiteSpace($User)) {
        return New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel $runLevel
    }
    return New-ScheduledTaskPrincipal -UserId $User -LogonType Password -RunLevel $runLevel
}

function Register-NeptunoTask {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$LauncherPath,
        [Parameter(Mandatory)][int]$IntervalMinutes,
        [Parameter(Mandatory)][string]$Description
    )

    $action = New-ScheduledTaskAction `
        -Execute $wscriptPath `
        -Argument ('"{0}"' -f $LauncherPath) `
        -WorkingDirectory $repoRoot
    $trigger = New-ScheduledTaskTrigger `
        -Once `
        -At (Get-Date).Date.AddMinutes(5) `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable
    $principal = New-NeptunoScheduledTaskPrincipal -User $TaskUser
    $task = New-ScheduledTask `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description $Description

    if ($PSCmdlet.ShouldProcess($TaskName, "Register or update scheduled task using VBS launcher")) {
        Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
    }
}

Register-NeptunoTask `
    -TaskName "Vidalinkco NEPTUNO Sync" `
    -LauncherPath $syncLauncherPath `
    -IntervalMinutes $SyncIntervalMinutes `
    -Description "Runs Vidalinkco NEPTUNO sync through hidden VBS launcher."

Register-NeptunoTask `
    -TaskName "Vidalinkco NEPTUNO Heartbeat" `
    -LauncherPath $heartbeatLauncherPath `
    -IntervalMinutes $HeartbeatIntervalMinutes `
    -Description "Runs Vidalinkco NEPTUNO heartbeat through hidden VBS launcher."

Write-Host "NEPTUNO scheduled tasks registered with VBS launchers."
Write-Host "Sync interval minutes: $SyncIntervalMinutes"
Write-Host "Heartbeat interval minutes: $HeartbeatIntervalMinutes"
