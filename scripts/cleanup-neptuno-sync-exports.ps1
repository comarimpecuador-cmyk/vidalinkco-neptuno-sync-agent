[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputDirectory,

    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$SuccessfulRunRetentionDays = 7,

    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$FailedRunRetentionDays = 30,

    [Parameter()]
    [ValidateRange(0, 100000)]
    [int]$MinimumSuccessfulRunsToKeep = 10,

    [Parameter()]
    [ValidateRange(0, 100000)]
    [int]$MinimumFailedRunsToKeep = 20,

    [Parameter()]
    [switch]$PreserveFullPayloads,

    [Parameter()]
    [bool]$PreserveFailedPayloads = $true,

    [Parameter()]
    [switch]$IncludeHistoricalTestDirectories,

    [Parameter()]
    [switch]$Apply
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot "exports/neptuno-sync"
}

. (Join-Path $PSScriptRoot "NeptunoSyncRetention.ps1")

function Format-Bytes {
    param([Parameter(Mandatory)][long]$Bytes)

    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Test-NeptunoSyncScheduledTaskRunning {
    $scheduledTaskCommand = Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue
    if ($null -eq $scheduledTaskCommand) {
        return $false
    }

    try {
        $task = Get-ScheduledTask -TaskName "Vidalinkco NEPTUNO Sync" -ErrorAction SilentlyContinue
        if ($null -eq $task) {
            return $false
        }
        return [string]$task.State -eq "Running"
    }
    catch {
        Write-Warning "Could not inspect scheduled task state: $($_.Exception.Message)"
        return $false
    }
}

$plan = New-NeptunoSyncCleanupPlan `
    -OutputDirectory $OutputDirectory `
    -SuccessfulRunRetentionDays $SuccessfulRunRetentionDays `
    -FailedRunRetentionDays $FailedRunRetentionDays `
    -MinimumSuccessfulRunsToKeep $MinimumSuccessfulRunsToKeep `
    -MinimumFailedRunsToKeep $MinimumFailedRunsToKeep `
    -PreserveFullPayloads ([bool]$PreserveFullPayloads) `
    -PreserveFailedPayloads $PreserveFailedPayloads `
    -IncludeHistoricalTestDirectories ([bool]$IncludeHistoricalTestDirectories)

Write-Host "NEPTUNO export cleanup mode: $(if ($Apply) { 'APPLY' } else { 'PREVIEW' })"
Write-Host "Output directory: $($plan.outputDirectory)"
Write-Host "Policy: successful $SuccessfulRunRetentionDays day(s) or newest $MinimumSuccessfulRunsToKeep; failed $FailedRunRetentionDays day(s) or newest $MinimumFailedRunsToKeep."
Write-Host "Full payload preservation for completed runs: $([bool]$PreserveFullPayloads)"
Write-Host "Failed payload preservation: $PreserveFailedPayloads"
Write-Host ""

if (@($plan.candidates).Count -eq 0) {
    Write-Host "No cleanup candidates."
}
else {
    Write-Host "Cleanup candidates:"
    $plan.candidates |
        Select-Object action, category, relativePath, status, ageDays, fileCount, @{Name = "size"; Expression = { Format-Bytes -Bytes $_.bytes } }, reason |
        Format-Table -AutoSize | Out-String -Width 240 | Write-Host
}

if (@($plan.localAudit).Count -gt 0) {
    Write-Host "Manual local-audit evidence preserved:"
    $plan.localAudit |
        Select-Object relativePath, fileCount, @{Name = "size"; Expression = { Format-Bytes -Bytes $_.bytes } }, reason |
        Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}

if (@($plan.errors).Count -gt 0) {
    Write-Host "Plan warnings:"
    $plan.errors | ForEach-Object { Write-Host "- $_" }
}

Write-Host "Candidate files: $($plan.totals.candidateFiles)"
Write-Host "Candidate size: $(Format-Bytes -Bytes ([long]$plan.totals.candidateBytes))"

if ($Apply -and (Test-NeptunoSyncScheduledTaskRunning)) {
    throw "Refusing destructive cleanup because scheduled task 'Vidalinkco NEPTUNO Sync' is Running."
}

$result = Invoke-NeptunoSyncCleanupPlan -Plan $plan -Apply:$Apply

Write-Host ""
Write-Host "Cleanup summary:"
Write-Host "Applied: $($result.applied)"
Write-Host "Files deleted: $($result.deletedFiles)"
Write-Host "Bytes freed: $(Format-Bytes -Bytes ([long]$result.deletedBytes))"
Write-Host "Preserved entries: $(@($result.preserved).Count)"
if (@($result.errors).Count -gt 0) {
    Write-Host "Errors:"
    $result.errors | ForEach-Object { Write-Host "- $_" }
}
else {
    Write-Host "Errors: 0"
}
