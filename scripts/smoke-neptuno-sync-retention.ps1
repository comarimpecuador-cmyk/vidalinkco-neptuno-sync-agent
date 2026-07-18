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
        [Parameter()][switch]$WithPayload,
        [Parameter()][switch]$LegacySummary,
        [Parameter()][Nullable[int]]$ProcessId,
        [Parameter()][int]$ProgressSnapshots = 0
    )

    $runDirectory = Join-Path (Join-Path $Root "runs") $Name
    [System.IO.Directory]::CreateDirectory($runDirectory) | Out-Null
    $statusAt = [DateTimeOffset]::UtcNow.AddDays(-1 * $AgeDays).ToString("o")
    $summary = if ($LegacySummary -and $Status -eq "completed") {
        [pscustomobject][ordered]@{
            syncRunId = $Name
            completedAt = $statusAt
        }
    }
    else {
        [pscustomobject][ordered]@{
            status = $Status
            syncRunId = $Name
            completedAt = $(if ($Status -eq "completed") { $statusAt } else { $null })
            failedAt = $(if ($Status -eq "failed") { $statusAt } else { $null })
            updatedAt = $statusAt
        }
    }
    $checkpoint = [pscustomobject][ordered]@{
        status = $Status
        syncRunId = $Name
        updatedAt = $statusAt
    }
    if ($null -ne $ProcessId) {
        $checkpoint | Add-Member -NotePropertyName processId -NotePropertyValue ([int]$ProcessId)
    }
    [System.IO.File]::WriteAllText((Join-Path $runDirectory "sync-summary.json"), (($summary | ConvertTo-Json -Depth 8) + "`n"), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $runDirectory "checkpoint.json"), (($checkpoint | ConvertTo-Json -Depth 8) + "`n"), [System.Text.UTF8Encoding]::new($false))

    if ($WithPayload) {
        foreach ($name in @("catalog-payload.json", "live-payload.json", "changed-products.json", "quarantine-items.json")) {
            [System.IO.File]::WriteAllText((Join-Path $runDirectory $name), '{"items":[{"externalId":"9102"}]}', [System.Text.UTF8Encoding]::new($false))
        }
    }

    if ($ProgressSnapshots -gt 0) {
        $progressDirectory = Join-Path $runDirectory "work/progress"
        [System.IO.Directory]::CreateDirectory($progressDirectory) | Out-Null
        foreach ($index in 1..$ProgressSnapshots) {
            $path = Join-Path $progressDirectory ("{0:D8}.json" -f $index)
            [System.IO.File]::WriteAllText($path, ('{"batch":' + $index + '}'), [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddMinutes($index))
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
$legacyCompleted = New-SmokeRun -Root $resolvedOutputDirectory -Name "legacy-completed" -Status "completed" -AgeDays 1 -WithPayload -LegacySummary
$failedMid = New-SmokeRun -Root $resolvedOutputDirectory -Name "failed-mid" -Status "failed" -AgeDays 20 -WithPayload
$failedOld = New-SmokeRun -Root $resolvedOutputDirectory -Name "failed-old" -Status "failed" -AgeDays 40 -WithPayload
$runningOld = New-SmokeRun -Root $resolvedOutputDirectory -Name "running-old" -Status "running" -AgeDays 90 -WithPayload
$staleRunning = New-SmokeRun -Root $resolvedOutputDirectory -Name "stale-running" -Status "running" -AgeDays 5 -ProgressSnapshots 4
$activeRunning = New-SmokeRun -Root $resolvedOutputDirectory -Name "active-running" -Status "running" -AgeDays 5 -ProcessId $PID -ProgressSnapshots 3
$interruptedLegacy = New-SmokeRun -Root $resolvedOutputDirectory -Name "interrupted-legacy" -Status "interrupted" -AgeDays 5 -ProgressSnapshots 3

$plan = New-NeptunoSyncCleanupPlan `
    -OutputDirectory $resolvedOutputDirectory `
    -SuccessfulRunRetentionDays 7 `
    -FailedRunRetentionDays 30 `
    -MinimumSuccessfulRunsToKeep 0 `
    -MinimumFailedRunsToKeep 0 `
    -EnableStaleRunningCleanup $true `
    -StaleRunningAfterHours 24 `
    -SyncTaskRunning $false

$runDeleteCandidates = @($plan.candidates | Where-Object { $_.action -eq "DeleteRunDirectory" })
Assert-True -Condition (@($runDeleteCandidates | Where-Object { $_.syncRunId -eq "success-old" }).Count -eq 1) -Message "Old successful run was not eligible."
Assert-True -Condition (@($runDeleteCandidates | Where-Object { $_.syncRunId -eq "success-recent" }).Count -eq 0) -Message "Recent successful run was incorrectly eligible."
Assert-True -Condition (@($runDeleteCandidates | Where-Object { $_.syncRunId -eq "failed-mid" }).Count -eq 0) -Message "Failed run did not use extended retention."
Assert-True -Condition (@($runDeleteCandidates | Where-Object { $_.syncRunId -eq "failed-old" }).Count -eq 1) -Message "Old failed run was not eligible."
Assert-True -Condition (@($runDeleteCandidates | Where-Object { $_.syncRunId -eq "running-old" }).Count -eq 0) -Message "Running run was incorrectly eligible."
Assert-True -Condition (@($plan.candidates | Where-Object { $_.path -match '\\state\\|\\latest\\' }).Count -eq 0) -Message "State/latest appeared in cleanup candidates."
Assert-True -Condition (@($plan.candidates | Where-Object { $_.action -eq "DeleteLegacyPayload" -and $_.syncRunId -eq "legacy-completed" }).Count -eq 4) -Message "Completed legacy payloads were not eligible."
Assert-True -Condition (@($plan.candidates | Where-Object { $_.action -eq "ClassifyStaleRun" -and $_.syncRunId -eq "stale-running" }).Count -eq 1) -Message "Stale running run was not classified."
Assert-True -Condition (@($plan.candidates | Where-Object { $_.action -eq "ClassifyStaleRun" -and $_.syncRunId -eq "active-running" }).Count -eq 0) -Message "Active running process was incorrectly classified as stale."
Assert-True -Condition (@($plan.candidates | Where-Object { $_.action -eq "CompactLegacyProgress" -and $_.syncRunId -eq "stale-running" }).Count -eq 3) -Message "Stale running progress snapshots were not compactable."
Assert-True -Condition (@($plan.candidates | Where-Object { $_.action -eq "CompactLegacyProgress" -and $_.syncRunId -eq "interrupted-legacy" }).Count -eq 2) -Message "Interrupted legacy progress snapshots were not compactable."
Assert-True -Condition (@($plan.candidates | Where-Object { $_.action -eq "PreserveNewestProgressSnapshot" -and $_.syncRunId -eq "stale-running" }).Count -eq 1) -Message "Newest stale progress snapshot was not marked preserved."

$previewResult = Invoke-NeptunoSyncCleanupPlan -Plan $plan
Assert-True -Condition (-not $previewResult.applied) -Message "Preview result was marked applied."
Assert-True -Condition ([System.IO.Directory]::Exists($successOld) -and [System.IO.Directory]::Exists($failedOld)) -Message "Dry-run deleted candidate directories."

$deleteCandidatePaths = @($plan.candidates | Where-Object { $_.effect -eq "delete" } | ForEach-Object { $_.path })
$applyResult = Invoke-NeptunoSyncCleanupPlan -Plan $plan -Apply
Assert-True -Condition ($applyResult.applied) -Message "Apply result was not marked applied."
Assert-True -Condition (-not [System.IO.Directory]::Exists($successOld) -and -not [System.IO.Directory]::Exists($failedOld)) -Message "Apply did not delete eligible run directories."
Assert-True -Condition ([System.IO.Directory]::Exists((Join-Path $resolvedOutputDirectory "state")) -and [System.IO.Directory]::Exists((Join-Path $resolvedOutputDirectory "latest"))) -Message "Apply removed protected state/latest."
Assert-True -Condition ([System.IO.Directory]::Exists($successRecent) -and [System.IO.Directory]::Exists($failedMid) -and [System.IO.Directory]::Exists($runningOld) -and [System.IO.Directory]::Exists($staleRunning) -and [System.IO.Directory]::Exists($interruptedLegacy)) -Message "Apply removed preserved runs."
Assert-True -Condition (-not [System.IO.File]::Exists((Join-Path $successRecent "catalog-payload.json"))) -Message "Completed run payload was not pruned."
Assert-True -Condition ([System.IO.File]::Exists((Join-Path $successRecent "artifact-manifest.json"))) -Message "Payload pruning did not write a manifest."
Assert-True -Condition ([System.IO.File]::Exists((Join-Path $staleRunning "checkpoint.json"))) -Message "Stale running checkpoint was removed."
Assert-True -Condition (@(Get-ChildItem -LiteralPath (Join-Path $staleRunning "work/progress") -File -Filter "*.json").Count -eq 1) -Message "Stale running progress was not compacted to one snapshot."
Assert-True -Condition (@(Get-ChildItem -LiteralPath (Join-Path $interruptedLegacy "work/progress") -File -Filter "*.json").Count -eq 1) -Message "Interrupted legacy progress was not compacted to one snapshot."
$staleManifest = Get-Content -Raw -LiteralPath (Join-Path $staleRunning "artifact-manifest.json") -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition (@($staleManifest.retentionActions | Where-Object { $_.action -eq "ClassifyStaleRun" }).Count -eq 1) -Message "Stale classification was not recorded in manifest."
Assert-True -Condition (@($staleManifest.retentionActions | Where-Object { $_.action -eq "CompactLegacyProgress" }).Count -eq 3) -Message "Progress compaction was not recorded in manifest."
foreach ($candidatePath in $deleteCandidatePaths) {
    if ($candidatePath -match 'success-old|failed-old') { continue }
    Assert-True -Condition (-not [System.IO.File]::Exists($candidatePath)) -Message "Apply parity failed; delete candidate still exists: $candidatePath"
}

$secondPlan = New-NeptunoSyncCleanupPlan `
    -OutputDirectory $resolvedOutputDirectory `
    -SuccessfulRunRetentionDays 7 `
    -FailedRunRetentionDays 30 `
    -MinimumSuccessfulRunsToKeep 0 `
    -MinimumFailedRunsToKeep 0 `
    -EnableStaleRunningCleanup $true `
    -StaleRunningAfterHours 24 `
    -SyncTaskRunning $false
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
Write-Host "Stale running classification with active-process guard: OK"
Write-Host "Completed legacy payload pruning: OK"
Write-Host "Interrupted/stale legacy progress compaction: OK"
Write-Host "Artifact manifest retention actions: OK"
Write-Host "Successful and failed age retention: OK"
Write-Host "Minimum run count retention: OK"
Write-Host "Dry-run and apply semantics: OK"
Write-Host "Locked file tolerance: OK"
Write-Host "Outside path rejection: OK"
Write-Host "Idempotent cleanup: OK"
