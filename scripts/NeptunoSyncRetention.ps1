Set-StrictMode -Version 2.0

$script:NeptunoSyncFullPayloadFiles = @(
    "catalog-payload.json",
    "live-payload.json",
    "changed-products.json",
    "quarantine-items.json"
)

$script:NeptunoSyncHistoricalTestDirectories = @(
    "neptuno-initial-baseline-smoke",
    "neptuno-production-wrapper-smoke",
    "neptuno-sync-1d-final-test",
    "neptuno-sync-1d-test",
    "neptuno-sync-payload-smoke",
    "neptuno-sync-send-9102",
    "neptuno-sync-send-9102-ok",
    "neptuno-sync-smoke",
    "neptuno-sync-test"
)

function ConvertTo-NeptunoRelativePath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $prefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
    if ([string]::Equals($resolvedPath, $resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return "."
    }
    if ($resolvedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $resolvedPath.Substring($prefix.Length)
    }
    return $resolvedPath
}

function Assert-NeptunoSafeChildPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][switch]$RequireDirectChild
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $resolvedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $prefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Cleanup refused a path outside the allowed root: $resolvedPath"
    }
    if ($RequireDirectChild -and
        -not [string]::Equals((Split-Path -Parent $resolvedPath), $resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Cleanup refused a non-direct child path: $resolvedPath"
    }
}

function Get-NeptunoPathStats {
    param([Parameter(Mandatory)][string]$Path)

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($resolvedPath) -and -not [System.IO.Directory]::Exists($resolvedPath)) {
        return [pscustomobject][ordered]@{ fileCount = 0; bytes = 0L; errors = @() }
    }

    $errors = [System.Collections.Generic.List[string]]::new()
    $fileCount = 0
    $bytes = 0L
    $item = Get-Item -LiteralPath $resolvedPath -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        $errors.Add("Skipped reparse point: $resolvedPath")
        return [pscustomobject][ordered]@{ fileCount = 0; bytes = 0L; errors = $errors.ToArray() }
    }
    if ($item -is [System.IO.FileInfo]) {
        return [pscustomobject][ordered]@{ fileCount = 1; bytes = [long]$item.Length; errors = @() }
    }

    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($resolvedPath)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        try {
            foreach ($child in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
                if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $errors.Add("Skipped reparse point: $($child.FullName)")
                    continue
                }
                if ($child -is [System.IO.DirectoryInfo]) {
                    $stack.Push($child.FullName)
                }
                else {
                    $fileCount++
                    $bytes += [long]$child.Length
                }
            }
        }
        catch {
            $errors.Add("Could not scan '$current': $($_.Exception.Message)")
        }
    }

    return [pscustomobject][ordered]@{ fileCount = $fileCount; bytes = $bytes; errors = $errors.ToArray() }
}

function Get-NeptunoObjectPropertyValue {
    param(
        [Parameter()]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Value) {
        return $null
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Test-NeptunoProcessIdActive {
    param([Parameter()][Nullable[int]]$ProcessId)

    if ($null -eq $ProcessId -or [int]$ProcessId -le 0) {
        return $false
    }
    try {
        $process = Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue
        return $null -ne $process
    }
    catch {
        return $false
    }
}

function Test-NeptunoRunActive {
    param(
        [Parameter()]$Checkpoint,
        [Parameter()][bool]$SyncTaskRunning = $false
    )

    if ($SyncTaskRunning) {
        return [pscustomobject][ordered]@{
            isActive = $true
            evidence = "scheduled-task-running"
        }
    }

    $processIdValue = Get-NeptunoObjectPropertyValue -Value $Checkpoint -Name "processId"
    if ($null -eq $processIdValue) {
        $processIdValue = Get-NeptunoObjectPropertyValue -Value $Checkpoint -Name "pid"
    }
    if ($null -ne $processIdValue) {
        $processId = 0
        if ([int]::TryParse([string]$processIdValue, [ref]$processId) -and (Test-NeptunoProcessIdActive -ProcessId $processId)) {
            return [pscustomobject][ordered]@{
                isActive = $true
                evidence = "checkpoint-processId-$processId"
            }
        }
        return [pscustomobject][ordered]@{
            isActive = $false
            evidence = "checkpoint-processId-not-running-$processIdValue"
        }
    }

    return [pscustomobject][ordered]@{
        isActive = $false
        evidence = "no-active-process-evidence"
    }
}

function Test-NeptunoManifestActionExists {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$Action
    )

    $manifestPath = Join-Path $RunDirectory "artifact-manifest.json"
    if (-not [System.IO.File]::Exists($manifestPath)) {
        return $false
    }
    try {
        $manifest = Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8 | ConvertFrom-Json
        $actions = @()
        $retentionActions = $manifest.PSObject.Properties["retentionActions"]
        if ($null -ne $retentionActions) {
            $actions += @($retentionActions.Value)
        }
        $removedArtifacts = $manifest.PSObject.Properties["removedArtifacts"]
        if ($null -ne $removedArtifacts) {
            $actions += @($removedArtifacts.Value)
        }
        return @($actions | Where-Object {
            $actionProperty = $_.PSObject.Properties["action"]
            $null -ne $actionProperty -and [string]$actionProperty.Value -eq $Action
        }).Count -gt 0
    }
    catch {
        return $false
    }
}

function Get-NeptunoRunInfo {
    param(
        [Parameter(Mandatory)][System.IO.DirectoryInfo]$Directory,
        [Parameter(Mandatory)][DateTimeOffset]$Now,
        [Parameter()][ValidateRange(1, 87600)][int]$StaleRunningAfterHours = 24,
        [Parameter()][bool]$EnableStaleRunningCleanup = $false,
        [Parameter()][bool]$SyncTaskRunning = $false
    )

    $checkpointPath = Join-Path $Directory.FullName "checkpoint.json"
    $summaryPath = Join-Path $Directory.FullName "sync-summary.json"
    $status = "unknown"
    $statusAt = [DateTimeOffset]$Directory.LastWriteTimeUtc
    $syncRunId = $Directory.Name
    $source = "directory"
    $error = $null
    $checkpoint = $null
    $legacyCompletedDetected = $false
    $activeEvidence = ""

    try {
        if ([System.IO.File]::Exists($summaryPath)) {
            $summary = Get-Content -Raw -LiteralPath $summaryPath -Encoding UTF8 | ConvertFrom-Json
            if ($summary.PSObject.Properties["status"]) { $status = [string]$summary.status }
            if ($summary.PSObject.Properties["syncRunId"]) { $syncRunId = [string]$summary.syncRunId }
            foreach ($name in @("completedAt", "failedAt", "interruptedAt", "updatedAt", "startedAt")) {
                $property = $summary.PSObject.Properties[$name]
                if ($null -ne $property -and $null -ne $property.Value) {
                    $parsed = [DateTimeOffset]::MinValue
                    if ([DateTimeOffset]::TryParse([string]$property.Value, [ref]$parsed)) {
                        $statusAt = $parsed
                        if ($name -eq "completedAt" -and $status -ne "completed") {
                            $status = "completed"
                            $legacyCompletedDetected = $true
                        }
                        break
                    }
                }
            }
            $source = "sync-summary.json"
            if ([System.IO.File]::Exists($checkpointPath)) {
                try {
                    $checkpoint = Get-Content -Raw -LiteralPath $checkpointPath -Encoding UTF8 | ConvertFrom-Json
                }
                catch {
                    $checkpoint = $null
                }
            }
        }
        elseif ([System.IO.File]::Exists($checkpointPath)) {
            $checkpoint = Get-Content -Raw -LiteralPath $checkpointPath -Encoding UTF8 | ConvertFrom-Json
            if ($checkpoint.PSObject.Properties["status"]) { $status = [string]$checkpoint.status }
            if ($checkpoint.PSObject.Properties["syncRunId"]) { $syncRunId = [string]$checkpoint.syncRunId }
            foreach ($name in @("completedAt", "failedAt", "interruptedAt", "updatedAt", "startedAt")) {
                $property = $checkpoint.PSObject.Properties[$name]
                if ($null -ne $property -and $null -ne $property.Value) {
                    $parsed = [DateTimeOffset]::MinValue
                    if ([DateTimeOffset]::TryParse([string]$property.Value, [ref]$parsed)) {
                        $statusAt = $parsed
                        break
                    }
                }
            }
            $source = "checkpoint.json"
        }
    }
    catch {
        $status = "unreadable"
        $error = $_.Exception.Message
    }

    $ageDays = [Math]::Max(0, ($Now - $statusAt.ToUniversalTime()).TotalDays)
    $ageHours = [Math]::Max(0, ($Now - $statusAt.ToUniversalTime()).TotalHours)
    $rawStatus = $status
    if ($EnableStaleRunningCleanup -and $status -eq "running" -and $ageHours -ge $StaleRunningAfterHours) {
        $active = Test-NeptunoRunActive -Checkpoint $checkpoint -SyncTaskRunning $SyncTaskRunning
        $activeEvidence = [string]$active.evidence
        if (-not [bool]$active.isActive) {
            $status = "StaleRunning"
        }
    }
    return [pscustomobject][ordered]@{
        directory = $Directory.FullName
        name = $Directory.Name
        syncRunId = $syncRunId
        status = $status
        rawStatus = $rawStatus
        statusAt = $statusAt.ToUniversalTime().ToString("o")
        ageDays = $ageDays
        ageHours = $ageHours
        source = $source
        legacyCompletedDetected = $legacyCompletedDetected
        activeEvidence = $activeEvidence
        error = $error
    }
}

function New-NeptunoCleanupCandidate {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$Status,
        [Parameter()][string]$SyncRunId = "",
        [Parameter()][string]$Category = "run",
        [Parameter()][double]$AgeDays = 0,
        [Parameter()][ValidateSet("delete", "classify", "preserve")][string]$Effect = "delete"
    )

    $stats = if ($Effect -eq "delete") {
        Get-NeptunoPathStats -Path $Path
    }
    else {
        [pscustomobject][ordered]@{ fileCount = 0; bytes = 0L; errors = @() }
    }
    return [pscustomobject][ordered]@{
        action = $Action
        effect = $Effect
        category = $Category
        path = [System.IO.Path]::GetFullPath($Path)
        relativePath = ConvertTo-NeptunoRelativePath -Root $Root -Path $Path
        syncRunId = $SyncRunId
        status = $Status
        ageDays = [Math]::Round($AgeDays, 2)
        fileCount = [int]$stats.fileCount
        bytes = [long]$stats.bytes
        reason = $Reason
        scanErrors = @($stats.errors)
    }
}

function Add-NeptunoLegacyProgressCompactionCandidates {
    param(
        [Parameter(Mandatory)]$Candidates,
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][string]$Root
    )

    $progressDirectory = Join-Path $Run.directory "work/progress"
    if (-not [System.IO.Directory]::Exists($progressDirectory)) {
        return
    }

    $progressItem = Get-Item -LiteralPath $progressDirectory -Force
    if (($progressItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return
    }

    $snapshots = @(Get-ChildItem -LiteralPath $progressDirectory -File -Filter "*.json" -Force |
        Sort-Object LastWriteTimeUtc, Name -Descending)
    if ($snapshots.Count -le 1) {
        return
    }

    $newest = $snapshots[0]
    $Candidates.Add((New-NeptunoCleanupCandidate `
        -Action "PreserveNewestProgressSnapshot" `
        -Path $newest.FullName `
        -Root $Root `
        -Reason "newest legacy progress snapshot is preserved for minimum resumability evidence" `
        -Status $Run.status `
        -SyncRunId $Run.syncRunId `
        -Category "legacy-progress" `
        -AgeDays $Run.ageDays `
        -Effect "preserve"))

    foreach ($snapshot in @($snapshots | Select-Object -Skip 1)) {
        $Candidates.Add((New-NeptunoCleanupCandidate `
            -Action "CompactLegacyProgress" `
            -Path $snapshot.FullName `
            -Root $Root `
            -Reason "older legacy cumulative progress snapshot is superseded by the newest snapshot" `
            -Status $Run.status `
            -SyncRunId $Run.syncRunId `
            -Category "legacy-progress" `
            -AgeDays $Run.ageDays))
    }
}

function New-NeptunoSyncCleanupPlan {
    param(
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter()][ValidateRange(1, 3650)][int]$SuccessfulRunRetentionDays = 7,
        [Parameter()][ValidateRange(1, 3650)][int]$FailedRunRetentionDays = 30,
        [Parameter()][ValidateRange(0, 100000)][int]$MinimumSuccessfulRunsToKeep = 10,
        [Parameter()][ValidateRange(0, 100000)][int]$MinimumFailedRunsToKeep = 20,
        [Parameter()][bool]$PreserveFullPayloads = $false,
        [Parameter()][bool]$PreserveFailedPayloads = $true,
        [Parameter()][bool]$EnableStaleRunningCleanup = $false,
        [Parameter()][ValidateRange(1, 87600)][int]$StaleRunningAfterHours = 24,
        [Parameter()][bool]$SyncTaskRunning = $false,
        [Parameter()][bool]$IncludeHistoricalTestDirectories = $false,
        [Parameter()][string[]]$HistoricalTestDirectories = $script:NeptunoSyncHistoricalTestDirectories,
        [Parameter()][DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )

    $resolvedOutputDirectory = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($OutputDirectory))
    $runsDirectory = Join-Path $resolvedOutputDirectory "runs"
    $exportsRoot = Split-Path -Parent $resolvedOutputDirectory
    $candidates = [System.Collections.Generic.List[object]]::new()
    $preserved = [System.Collections.Generic.List[object]]::new()
    $localAudit = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($required in @("state", "latest")) {
        $preservedPath = Join-Path $resolvedOutputDirectory $required
        if ([System.IO.Directory]::Exists($preservedPath)) {
            $preserved.Add([pscustomobject][ordered]@{
                category = "protected"
                path = [System.IO.Path]::GetFullPath($preservedPath)
                relativePath = ConvertTo-NeptunoRelativePath -Root $resolvedOutputDirectory -Path $preservedPath
                reason = "$required is protected operational state"
            })
        }
    }

    if ([System.IO.Directory]::Exists($runsDirectory)) {
        $runInfos = [System.Collections.Generic.List[object]]::new()
        foreach ($run in @(Get-ChildItem -LiteralPath $runsDirectory -Directory -Force)) {
            if (($run.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $errors.Add("Skipped reparse-point run directory: $($run.FullName)")
                continue
            }
            $runInfos.Add((Get-NeptunoRunInfo `
                -Directory $run `
                -Now $Now `
                -StaleRunningAfterHours $StaleRunningAfterHours `
                -EnableStaleRunningCleanup $EnableStaleRunningCleanup `
                -SyncTaskRunning $SyncTaskRunning))
        }

        $successful = @($runInfos.ToArray() | Where-Object { $_.status -eq "completed" } | Sort-Object statusAt -Descending)
        $failed = @($runInfos.ToArray() | Where-Object { $_.status -eq "failed" } | Sort-Object statusAt -Descending)
        $staleRunning = @($runInfos.ToArray() | Where-Object { $_.status -eq "StaleRunning" } | Sort-Object statusAt -Descending)
        $interrupted = @($runInfos.ToArray() | Where-Object { $_.status -eq "interrupted" } | Sort-Object statusAt -Descending)
        $nonTerminal = @($runInfos.ToArray() | Where-Object { $_.status -notin @("completed", "failed", "StaleRunning", "interrupted") })

        foreach ($run in $nonTerminal) {
            $preserved.Add([pscustomobject][ordered]@{
                category = "run"
                path = $run.directory
                relativePath = ConvertTo-NeptunoRelativePath -Root $resolvedOutputDirectory -Path $run.directory
                status = $run.status
                syncRunId = $run.syncRunId
                reason = "non-terminal run is preserved for resume/evidence"
            })
        }

        foreach ($run in $staleRunning) {
            $preserved.Add([pscustomobject][ordered]@{
                category = "run"
                path = $run.directory
                relativePath = ConvertTo-NeptunoRelativePath -Root $resolvedOutputDirectory -Path $run.directory
                status = $run.status
                rawStatus = $run.rawStatus
                syncRunId = $run.syncRunId
                reason = "running checkpoint exceeded stale threshold and no active process evidence was found; run directory is preserved"
            })
            if (-not (Test-NeptunoManifestActionExists -RunDirectory $run.directory -Action "ClassifyStaleRun")) {
                $candidates.Add((New-NeptunoCleanupCandidate `
                    -Action "ClassifyStaleRun" `
                    -Path (Join-Path $run.directory "checkpoint.json") `
                    -Root $resolvedOutputDirectory `
                    -Reason "running checkpoint is older than $StaleRunningAfterHours hour(s) and active evidence is '$($run.activeEvidence)'" `
                    -Status $run.status `
                    -SyncRunId $run.syncRunId `
                    -Category "classification" `
                    -AgeDays $run.ageDays `
                    -Effect "classify"))
            }
            Add-NeptunoLegacyProgressCompactionCandidates -Candidates $candidates -Run $run -Root $resolvedOutputDirectory
        }

        foreach ($run in $interrupted) {
            $preserved.Add([pscustomobject][ordered]@{
                category = "run"
                path = $run.directory
                relativePath = ConvertTo-NeptunoRelativePath -Root $resolvedOutputDirectory -Path $run.directory
                status = $run.status
                syncRunId = $run.syncRunId
                reason = "interrupted run is preserved; legacy progress snapshots may be compacted"
            })
            Add-NeptunoLegacyProgressCompactionCandidates -Candidates $candidates -Run $run -Root $resolvedOutputDirectory
        }

        for ($i = 0; $i -lt $successful.Count; $i++) {
            $run = $successful[$i]
            $keepByCount = $i -lt $MinimumSuccessfulRunsToKeep
            $keepByAge = $run.ageDays -le $SuccessfulRunRetentionDays
            if (-not $keepByCount -and -not $keepByAge) {
                $candidates.Add((New-NeptunoCleanupCandidate `
                    -Action "DeleteRunDirectory" `
                    -Path $run.directory `
                    -Root $resolvedOutputDirectory `
                    -Reason "completed run is older than $SuccessfulRunRetentionDays day(s) and outside newest $MinimumSuccessfulRunsToKeep completed run(s)" `
                    -Status $run.status `
                    -SyncRunId $run.syncRunId `
                    -Category "run" `
                    -AgeDays $run.ageDays))
                continue
            }

            $preserved.Add([pscustomobject][ordered]@{
                category = "run"
                path = $run.directory
                relativePath = ConvertTo-NeptunoRelativePath -Root $resolvedOutputDirectory -Path $run.directory
                status = $run.status
                syncRunId = $run.syncRunId
                reason = "completed run kept by age/count policy"
            })

            if (-not $PreserveFullPayloads) {
                foreach ($fileName in $script:NeptunoSyncFullPayloadFiles) {
                    $payloadPath = Join-Path $run.directory $fileName
                    if ([System.IO.File]::Exists($payloadPath)) {
                        $candidates.Add((New-NeptunoCleanupCandidate `
                            -Action "DeleteLegacyPayload" `
                            -Path $payloadPath `
                            -Root $resolvedOutputDirectory `
                            -Reason "full payload from completed run is legacy/diagnostic-only; summary, checkpoint and events remain" `
                            -Status $run.status `
                            -SyncRunId $run.syncRunId `
                            -Category "payload" `
                            -AgeDays $run.ageDays))
                    }
                }
            }
        }

        for ($i = 0; $i -lt $failed.Count; $i++) {
            $run = $failed[$i]
            $keepByCount = $i -lt $MinimumFailedRunsToKeep
            $keepByAge = $run.ageDays -le $FailedRunRetentionDays
            if (-not $keepByCount -and -not $keepByAge) {
                $candidates.Add((New-NeptunoCleanupCandidate `
                    -Action "DeleteRunDirectory" `
                    -Path $run.directory `
                    -Root $resolvedOutputDirectory `
                    -Reason "failed run is older than $FailedRunRetentionDays day(s) and outside newest $MinimumFailedRunsToKeep failed run(s)" `
                    -Status $run.status `
                    -SyncRunId $run.syncRunId `
                    -Category "run" `
                    -AgeDays $run.ageDays))
                continue
            }

            $preserved.Add([pscustomobject][ordered]@{
                category = "run"
                path = $run.directory
                relativePath = ConvertTo-NeptunoRelativePath -Root $resolvedOutputDirectory -Path $run.directory
                status = $run.status
                syncRunId = $run.syncRunId
                reason = "failed run kept by extended age/count policy"
            })

            if (-not $PreserveFailedPayloads) {
                foreach ($fileName in $script:NeptunoSyncFullPayloadFiles) {
                    $payloadPath = Join-Path $run.directory $fileName
                    if ([System.IO.File]::Exists($payloadPath)) {
                        $candidates.Add((New-NeptunoCleanupCandidate `
                            -Action "DeletePayloadFile" `
                            -Path $payloadPath `
                            -Root $resolvedOutputDirectory `
                            -Reason "failed payload pruning was explicitly enabled" `
                            -Status $run.status `
                            -SyncRunId $run.syncRunId `
                            -Category "payload" `
                            -AgeDays $run.ageDays))
                    }
                }
            }
        }
    }

    $localAuditPath = Join-Path $exportsRoot "local-audit"
    if ([System.IO.Directory]::Exists($localAuditPath)) {
        $stats = Get-NeptunoPathStats -Path $localAuditPath
        $localAudit.Add([pscustomobject][ordered]@{
            path = [System.IO.Path]::GetFullPath($localAuditPath)
            relativePath = ConvertTo-NeptunoRelativePath -Root $exportsRoot -Path $localAuditPath
            fileCount = [int]$stats.fileCount
            bytes = [long]$stats.bytes
            reason = "manual audit evidence; never deleted automatically"
        })
    }

    if ($IncludeHistoricalTestDirectories) {
        foreach ($name in $HistoricalTestDirectories) {
            $historicalPath = Join-Path $exportsRoot $name
            if ([System.IO.Directory]::Exists($historicalPath)) {
                $item = Get-Item -LiteralPath $historicalPath -Force
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $errors.Add("Skipped reparse-point historical directory: $historicalPath")
                    continue
                }
                $candidates.Add((New-NeptunoCleanupCandidate `
                    -Action "DeleteHistoricalDirectory" `
                    -Path $historicalPath `
                    -Root $exportsRoot `
                    -Reason "known historical smoke/test export directory" `
                    -Status "historical-test" `
                    -SyncRunId "" `
                    -Category "historical-test" `
                    -AgeDays 0))
            }
        }
    }

    $candidateArray = @($candidates.ToArray())
    $candidateFilesTotal = 0
    $candidateBytesTotal = 0L
    foreach ($candidate in $candidateArray) {
        if ($candidate.effect -eq "delete") {
            $candidateFilesTotal += [int]$candidate.fileCount
            $candidateBytesTotal += [long]$candidate.bytes
        }
    }
    return [pscustomobject][ordered]@{
        outputDirectory = $resolvedOutputDirectory
        runsDirectory = $runsDirectory
        exportsRoot = $exportsRoot
        generatedAt = $Now.ToUniversalTime().ToString("o")
        policy = [pscustomobject][ordered]@{
            successfulRunRetentionDays = $SuccessfulRunRetentionDays
            failedRunRetentionDays = $FailedRunRetentionDays
            minimumSuccessfulRunsToKeep = $MinimumSuccessfulRunsToKeep
            minimumFailedRunsToKeep = $MinimumFailedRunsToKeep
            preserveFullPayloads = $PreserveFullPayloads
            preserveFailedPayloads = $PreserveFailedPayloads
            enableStaleRunningCleanup = $EnableStaleRunningCleanup
            staleRunningAfterHours = $StaleRunningAfterHours
            syncTaskRunning = $SyncTaskRunning
            includeHistoricalTestDirectories = $IncludeHistoricalTestDirectories
        }
        candidates = $candidateArray
        preserved = @($preserved.ToArray())
        localAudit = @($localAudit.ToArray())
        errors = @($errors.ToArray())
        totals = [pscustomobject][ordered]@{
            candidateCount = $candidateArray.Count
            candidateFiles = $candidateFilesTotal
            candidateBytes = $candidateBytesTotal
        }
    }
}

function Write-NeptunoArtifactManifest {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter()][object[]]$RemovedArtifacts = @(),
        [Parameter()][object[]]$RetentionActions = @(),
        [Parameter(Mandatory)]$Policy
    )

    $manifestPath = Join-Path $RunDirectory "artifact-manifest.json"
    $existing = @()
    $existingActions = @()
    if ([System.IO.File]::Exists($manifestPath)) {
        try {
            $manifest = Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8 | ConvertFrom-Json
            if ($manifest.PSObject.Properties["removedArtifacts"]) {
                $existing = @($manifest.removedArtifacts)
            }
            if ($manifest.PSObject.Properties["retentionActions"]) {
                $existingActions = @($manifest.retentionActions)
            }
        }
        catch {
            $existing = @()
            $existingActions = @()
        }
    }
    $next = @($existing) + @($RemovedArtifacts)
    $nextActions = @($existingActions) + @($RetentionActions)
    $value = [pscustomobject][ordered]@{
        version = 1
        updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
        policy = $Policy
        removedArtifacts = $next
        retentionActions = $nextActions
    }
    $json = $value | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($manifestPath, $json + "`n", [System.Text.UTF8Encoding]::new($false))
}

function Invoke-NeptunoSyncCleanupPlan {
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter()][switch]$Apply
    )

    $deletedFiles = 0
    $deletedBytes = 0L
    $errors = [System.Collections.Generic.List[string]]::new()
    $preserved = [System.Collections.Generic.List[string]]::new()

    foreach ($candidate in @($Plan.candidates)) {
        if (-not $Apply) {
            continue
        }
        try {
            if ($candidate.action -eq "DeleteRunDirectory") {
                Assert-NeptunoSafeChildPath -Root $Plan.runsDirectory -Path $candidate.path -RequireDirectChild
                $item = Get-Item -LiteralPath $candidate.path -Force
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Refused reparse-point run directory."
                }
                Remove-Item -LiteralPath $candidate.path -Recurse -Force -ErrorAction Stop
            }
            elseif ($candidate.action -eq "DeleteHistoricalDirectory") {
                Assert-NeptunoSafeChildPath -Root $Plan.exportsRoot -Path $candidate.path -RequireDirectChild
                $item = Get-Item -LiteralPath $candidate.path -Force
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Refused reparse-point historical directory."
                }
                Remove-Item -LiteralPath $candidate.path -Recurse -Force -ErrorAction Stop
            }
            elseif ($candidate.action -in @("DeletePayloadFile", "DeleteLegacyPayload")) {
                Assert-NeptunoSafeChildPath -Root $Plan.runsDirectory -Path $candidate.path
                $runDirectory = Split-Path -Parent $candidate.path
                Assert-NeptunoSafeChildPath -Root $Plan.runsDirectory -Path $runDirectory -RequireDirectChild
                $retentionAction = [pscustomobject][ordered]@{
                    action = [string]$candidate.action
                    path = ConvertTo-NeptunoRelativePath -Root $runDirectory -Path $candidate.path
                    bytes = [long]$candidate.bytes
                    appliedAt = [DateTimeOffset]::UtcNow.ToString("o")
                    reason = [string]$candidate.reason
                }
                $removed = [pscustomobject][ordered]@{
                    path = Split-Path -Leaf $candidate.path
                    bytes = [long]$candidate.bytes
                    removedAt = [DateTimeOffset]::UtcNow.ToString("o")
                    reason = $candidate.reason
                }
                Write-NeptunoArtifactManifest -RunDirectory $runDirectory -RemovedArtifacts @($removed) -RetentionActions @($retentionAction) -Policy $Plan.policy
                Remove-Item -LiteralPath $candidate.path -Force -ErrorAction Stop
            }
            elseif ($candidate.action -eq "CompactLegacyProgress") {
                Assert-NeptunoSafeChildPath -Root $Plan.runsDirectory -Path $candidate.path
                $progressDirectory = Split-Path -Parent $candidate.path
                $workDirectory = Split-Path -Parent $progressDirectory
                $runDirectory = Split-Path -Parent $workDirectory
                Assert-NeptunoSafeChildPath -Root $Plan.runsDirectory -Path $runDirectory -RequireDirectChild
                $retentionAction = [pscustomobject][ordered]@{
                    action = "CompactLegacyProgress"
                    path = ConvertTo-NeptunoRelativePath -Root $runDirectory -Path $candidate.path
                    bytes = [long]$candidate.bytes
                    appliedAt = [DateTimeOffset]::UtcNow.ToString("o")
                    reason = [string]$candidate.reason
                }
                $removed = [pscustomobject][ordered]@{
                    path = ConvertTo-NeptunoRelativePath -Root $runDirectory -Path $candidate.path
                    bytes = [long]$candidate.bytes
                    removedAt = [DateTimeOffset]::UtcNow.ToString("o")
                    reason = $candidate.reason
                }
                Write-NeptunoArtifactManifest -RunDirectory $runDirectory -RemovedArtifacts @($removed) -RetentionActions @($retentionAction) -Policy $Plan.policy
                Remove-Item -LiteralPath $candidate.path -Force -ErrorAction Stop
            }
            elseif ($candidate.action -in @("ClassifyStaleRun", "PreserveNewestProgressSnapshot")) {
                Assert-NeptunoSafeChildPath -Root $Plan.runsDirectory -Path $candidate.path
                $runDirectory = if ($candidate.action -eq "ClassifyStaleRun") {
                    Split-Path -Parent $candidate.path
                }
                else {
                    Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $candidate.path))
                }
                Assert-NeptunoSafeChildPath -Root $Plan.runsDirectory -Path $runDirectory -RequireDirectChild
                $retentionAction = [pscustomobject][ordered]@{
                    action = [string]$candidate.action
                    path = ConvertTo-NeptunoRelativePath -Root $runDirectory -Path $candidate.path
                    appliedAt = [DateTimeOffset]::UtcNow.ToString("o")
                    reason = [string]$candidate.reason
                }
                Write-NeptunoArtifactManifest -RunDirectory $runDirectory -RetentionActions @($retentionAction) -Policy $Plan.policy
            }
            else {
                throw "Unknown cleanup action '$($candidate.action)'."
            }
            if ($candidate.effect -eq "delete") {
                $deletedFiles += [int]$candidate.fileCount
                $deletedBytes += [long]$candidate.bytes
            }
        }
        catch {
            $errors.Add("$($candidate.relativePath): $($_.Exception.Message)")
        }
    }

    foreach ($entry in @($Plan.preserved)) {
        $preserved.Add([string]$entry.relativePath)
    }

    return [pscustomobject][ordered]@{
        applied = [bool]$Apply
        deletedFiles = $deletedFiles
        deletedBytes = $deletedBytes
        errors = @($errors.ToArray())
        preserved = @($preserved.ToArray())
    }
}
