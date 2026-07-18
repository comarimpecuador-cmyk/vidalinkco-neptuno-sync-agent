[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot "exports/neptuno-retention-smoke"
}

. (Join-Path $PSScriptRoot "NeptunoSyncRetention.ps1")

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function New-SmokeRun {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][int]$AgeDays,
        [Parameter()][switch]$WithPayload
    )

    $runDirectory = Join-Path (Join-Path $Root "runs") $Name
    [System.IO.Directory]::CreateDirectory($runDirectory) | Out-Null
    $statusAt = [DateTimeOffset]::UtcNow.AddDays(-1 * $AgeDays).ToString("o")
    $summary = [pscustomobject][ordered]@{
        status = $Status
        syncRunId = $Name
        completedAt = $(if ($Status -eq "completed") { $statusAt } else { $null })
        failedAt = $(if ($Status -eq "failed") { $statusAt } else { $null })
        updatedAt = $statusAt
    }
    $checkpoint = [pscustomobject][ordered]@{
        status = $Status
        syncRunId = $Name
        updatedAt = $statusAt
    }
    [System.IO.File]::WriteAllText((Join-Path $runDirectory "sync-summary.json"), (($summary | ConvertTo-Json -Depth 8) + "`n"), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $runDirectory "checkpoint.json"), (($checkpoint | ConvertTo-Json -Depth 8) + "`n"), [System.Text.UTF8Encoding]::new($false))

    if ($WithPayload) {
        foreach ($name in @("catalog-payload.json", "live-payload.json", "changed-products.json", "quarantine-items.json")) {
            [System.IO.File]::WriteAllText((Join-Path $runDirectory $name), '{"items":[{"externalId":"9102"}]}', [System.Text.UTF8Encoding]::new($false))
        }
    }

    return $runDirectory
}

$resolvedOutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if ([System.IO.Directory]::Exists($resolvedOutputDirectory)) {
    $allowedSmokeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "exports")).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedOutputDirectory.StartsWith($allowedSmokeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Smoke cleanup refused an OutputDirectory outside repo exports."
    }
    Remove-Item -LiteralPath $resolvedOutputDirectory -Recurse -Force
}

[System.IO.Directory]::CreateDirectory((Join-Path $resolvedOutputDirectory "state")) | Out-Null
[System.IO.Directory]::CreateDirectory((Join-Path $resolvedOutputDirectory "latest")) | Out-Null
[System.IO.Directory]::CreateDirectory((Join-Path $resolvedOutputDirectory "runs")) | Out-Null
[System.IO.File]::WriteAllText((Join-Path $resolvedOutputDirectory "state/fingerprints.json"), '{"version":2}', [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText((Join-Path $resolvedOutputDirectory "state/cursors.json"), '{"version":1}', [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText((Join-Path $resolvedOutputDirectory "latest/sync-summary.json"), '{"status":"completed"}', [System.Text.UTF8Encoding]::new($false))

$successOld = New-SmokeRun -Root $resolvedOutputDirectory -Name "success-old" -Status "completed" -AgeDays 20 -WithPayload
$successRecent = New-SmokeRun -Root $resolvedOutputDirectory -Name "success-recent" -Status "completed" -AgeDays 1 -WithPayload
$failedMid = New-SmokeRun -Root $resolvedOutputDirectory -Name "failed-mid" -Status "failed" -AgeDays 20 -WithPayload
$failedOld = New-SmokeRun -Root $resolvedOutputDirectory -Name "failed-old" -Status "failed" -AgeDays 40 -WithPayload
$runningOld = New-SmokeRun -Root $resolvedOutputDirectory -Name "running-old" -Status "running" -AgeDays 90 -WithPayload

$plan = New-NeptunoSyncCleanupPlan `
    -OutputDirectory $resolvedOutputDirectory `
    -SuccessfulRunRetentionDays 7 `
    -FailedRunRetentionDays 30 `
    -MinimumSuccessfulRunsToKeep 0 `
    -MinimumFailedRunsToKeep 0

$runDeleteCandidates = @($plan.candidates | Where-Object { $_.action -eq "DeleteRunDirectory" })
Assert-True -Condition (@($runDeleteCandidates | Where-Object { $_.syncRunId -eq "success-old" }).Count -eq 1) -Message "Old successful run was not eligible."
Assert-True -Condition (@($runDeleteCandidates | Where-Object { $_.syncRunId -eq "success-recent" }).Count -eq 0) -Message "Recent successful run was incorrectly eligible."
Assert-True -Condition (@($runDeleteCandidates | Where-Object { $_.syncRunId -eq "failed-mid" }).Count -eq 0) -Message "Failed run did not use extended retention."
Assert-True -Condition (@($runDeleteCandidates | Where-Object { $_.syncRunId -eq "failed-old" }).Count -eq 1) -Message "Old failed run was not eligible."
Assert-True -Condition (@($runDeleteCandidates | Where-Object { $_.syncRunId -eq "running-old" }).Count -eq 0) -Message "Running run was incorrectly eligible."
Assert-True -Condition (@($plan.candidates | Where-Object { $_.path -match '\\state\\|\\latest\\' }).Count -eq 0) -Message "State/latest appeared in cleanup candidates."

$previewResult = Invoke-NeptunoSyncCleanupPlan -Plan $plan
Assert-True -Condition (-not $previewResult.applied) -Message "Preview result was marked applied."
Assert-True -Condition ([System.IO.Directory]::Exists($successOld) -and [System.IO.Directory]::Exists($failedOld)) -Message "Dry-run deleted candidate directories."

$applyResult = Invoke-NeptunoSyncCleanupPlan -Plan $plan -Apply
Assert-True -Condition ($applyResult.applied) -Message "Apply result was not marked applied."
Assert-True -Condition (-not [System.IO.Directory]::Exists($successOld) -and -not [System.IO.Directory]::Exists($failedOld)) -Message "Apply did not delete eligible run directories."
Assert-True -Condition ([System.IO.Directory]::Exists((Join-Path $resolvedOutputDirectory "state")) -and [System.IO.Directory]::Exists((Join-Path $resolvedOutputDirectory "latest"))) -Message "Apply removed protected state/latest."
Assert-True -Condition ([System.IO.Directory]::Exists($successRecent) -and [System.IO.Directory]::Exists($failedMid) -and [System.IO.Directory]::Exists($runningOld)) -Message "Apply removed preserved runs."
Assert-True -Condition (-not [System.IO.File]::Exists((Join-Path $successRecent "catalog-payload.json"))) -Message "Completed run payload was not pruned."
Assert-True -Condition ([System.IO.File]::Exists((Join-Path $successRecent "artifact-manifest.json"))) -Message "Payload pruning did not write a manifest."

$secondPlan = New-NeptunoSyncCleanupPlan `
    -OutputDirectory $resolvedOutputDirectory `
    -SuccessfulRunRetentionDays 7 `
    -FailedRunRetentionDays 30 `
    -MinimumSuccessfulRunsToKeep 0 `
    -MinimumFailedRunsToKeep 0
Assert-True -Condition (@($secondPlan.candidates).Count -eq 0) -Message "Cleanup was not idempotent."

$minimumOutput = Join-Path $resolvedOutputDirectory "minimum"
[System.IO.Directory]::CreateDirectory((Join-Path $minimumOutput "runs")) | Out-Null
[void](New-SmokeRun -Root $minimumOutput -Name "old-1" -Status "completed" -AgeDays 40)
[void](New-SmokeRun -Root $minimumOutput -Name "old-2" -Status "completed" -AgeDays 39)
[void](New-SmokeRun -Root $minimumOutput -Name "old-3" -Status "completed" -AgeDays 38)
$minimumPlan = New-NeptunoSyncCleanupPlan -OutputDirectory $minimumOutput -SuccessfulRunRetentionDays 7 -MinimumSuccessfulRunsToKeep 2 -MinimumFailedRunsToKeep 0
$minimumDeletes = @($minimumPlan.candidates | Where-Object { $_.action -eq "DeleteRunDirectory" })
Assert-True -Condition ($minimumDeletes.Count -eq 1 -and $minimumDeletes[0].syncRunId -eq "old-1") -Message "Minimum successful runs policy was not respected."

$lockedOutput = Join-Path $resolvedOutputDirectory "locked"
[System.IO.Directory]::CreateDirectory((Join-Path $lockedOutput "runs")) | Out-Null
$lockedRun = New-SmokeRun -Root $lockedOutput -Name "locked-old" -Status "completed" -AgeDays 40 -WithPayload
$otherRun = New-SmokeRun -Root $lockedOutput -Name "other-old" -Status "completed" -AgeDays 40 -WithPayload
$lockedFile = Join-Path $lockedRun "catalog-payload.json"
$stream = [System.IO.File]::Open($lockedFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
try {
    $lockedPlan = New-NeptunoSyncCleanupPlan -OutputDirectory $lockedOutput -SuccessfulRunRetentionDays 7 -MinimumSuccessfulRunsToKeep 0 -MinimumFailedRunsToKeep 0
    $lockedResult = Invoke-NeptunoSyncCleanupPlan -Plan $lockedPlan -Apply
    Assert-True -Condition (@($lockedResult.errors).Count -ge 1) -Message "Locked file did not produce a cleanup error."
    Assert-True -Condition (-not [System.IO.Directory]::Exists($otherRun)) -Message "Locked file prevented unrelated eligible cleanup."
}
finally {
    $stream.Dispose()
}

$outsideRejected = $false
try {
    Assert-NeptunoSafeChildPath -Root $resolvedOutputDirectory -Path (Split-Path -Parent $resolvedOutputDirectory)
}
catch {
    $outsideRejected = $_.Exception.Message -match 'outside'
}
Assert-True -Condition $outsideRejected -Message "Path outside exports was not rejected."

Write-Host "NEPTUNO sync retention smoke passed."
Write-Host "Protected state/latest: OK"
Write-Host "Active/incomplete run preservation: OK"
Write-Host "Successful and failed age retention: OK"
Write-Host "Minimum run count retention: OK"
Write-Host "Dry-run and apply semantics: OK"
Write-Host "Locked file tolerance: OK"
Write-Host "Outside path rejection: OK"
Write-Host "Idempotent cleanup: OK"
