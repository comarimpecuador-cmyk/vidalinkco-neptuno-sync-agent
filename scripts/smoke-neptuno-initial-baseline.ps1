[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot "exports/neptuno-initial-baseline-smoke"
}
$mainScript = Join-Path $PSScriptRoot "sync-neptuno-catalog.ps1"
$resolvedOutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$fixturePath = Join-Path $resolvedOutputDirectory "fixture-1200.json"
$fakeToken = "initial-baseline-smoke-token-never-sent"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

function New-CatalogFixtureRow {
    param([Parameter(Mandatory)][int]$ExternalId)

    return [pscustomobject][ordered]@{
        externalId = [string]$ExternalId
        nombreOriginal = "PRODUCTO BASELINE $ExternalId"
        nombreLargo = "PRODUCTO BASELINE $ExternalId"
        precioOrigen = 1.00
        aplicaIvaOrigen = "N"
        ivaOrigenId = "0"
        categoriaExternalId = "MED"
        categoriaNombre = "MEDICAMENTOS"
        subcategoriaExternalId = "BASE"
        subcategoriaNombre = "BASELINE"
        estadoExternalId = "ACT"
        estadoNombre = "ACTIVO"
        puedeVender = "S"
        presentacionCodigo = "UNI"
        presentacionNombre = "UNIDAD"
        medidaCodigo = $null
        medidaNombre = $null
        concentracionCodigo = $null
        concentracionNombre = $null
        unidadesPorCaja = 1
        fabricanteExternalId = "100"
        fabricanteCodigo = "SMOKE"
        fabricanteNombre = "LABORATORIO SMOKE"
        generico = "N"
        restriccionMedica = "N"
        cronico = "N"
        requiereMedico = "N"
        vademecumExternalId = $null
        vademecumNombre = $null
        vademecumSectionNames = $null
    }
}

function Initialize-BaselineState {
    param([Parameter(Mandatory)][string]$RunOutput)

    & $mainScript `
        -FixturePath $fixturePath `
        -OutputDirectory $RunOutput `
        -SourceKey "neptuno-initial-baseline-smoke" `
        -BodegaId 1 `
        -Mode All `
        -Eligibility AllForAudit `
        -RunType Bootstrap `
        -BatchSize 500 `
        -ProgressEveryBatches 1000 `
        -RebuildState `
        -DryRun
}

function Get-NewestRunDirectory {
    param([Parameter(Mandatory)][string]$RunOutput)

    return @(Get-ChildItem -LiteralPath (Join-Path $RunOutput "runs") -Directory | Sort-Object Name -Descending)[0].FullName
}

if ([System.IO.Directory]::Exists($resolvedOutputDirectory)) {
    Remove-Item -LiteralPath $resolvedOutputDirectory -Recurse -Force
}
[System.IO.Directory]::CreateDirectory($resolvedOutputDirectory) | Out-Null
$catalogRows = [System.Collections.Generic.List[object]]::new()
for ($externalId = 1; $externalId -le 1200; $externalId++) {
    $catalogRows.Add((New-CatalogFixtureRow -ExternalId $externalId))
}
$fixture = [pscustomobject][ordered]@{
    catalogRows = $catalogRows.ToArray()
    liveRows = @()
}
[System.IO.File]::WriteAllText($fixturePath, (($fixture | ConvertTo-Json -Depth 10) + "`n"), $utf8NoBom)

$successOutput = Join-Path $resolvedOutputDirectory "success"
Initialize-BaselineState -RunOutput $successOutput
$successConsole = & $mainScript `
    -FixturePath $fixturePath `
    -OutputDirectory $successOutput `
    -SourceKey "neptuno-initial-baseline-smoke" `
    -BodegaId 1 `
    -Mode All `
    -Eligibility AllForAudit `
    -RunType Incremental `
    -BatchSize 500 `
    -ProgressEveryBatches 1000 `
    -ApiUrl "https://127.0.0.1:1/must-not-connect" `
    -ApiToken $fakeToken `
    -Send `
    -InitialBaseline `
    -ChunkSize 500 `
    -MockSendSuccess 6>&1 | Out-String
$successRun = Get-NewestRunDirectory -RunOutput $successOutput
$successManifest = Get-Content -Raw -LiteralPath (Join-Path $successRun "chunks/manifest.json") -Encoding UTF8 | ConvertFrom-Json
$successSummary = Get-Content -Raw -LiteralPath (Join-Path $successRun "sync-summary.json") -Encoding UTF8 | ConvertFrom-Json
$chunkSyncRunIds = @($successManifest.chunks | ForEach-Object { [string]$_.syncRunId })
$chunkIdempotencyKeys = @($successManifest.chunks | ForEach-Object { [string]$_.idempotencyKey })
Assert-True -Condition ($successManifest.totalItems -eq 1200 -and $successManifest.totalChunks -eq 3) -Message "A 1200-item baseline did not produce exactly 3 chunks."
Assert-True -Condition (@($successManifest.chunks | ForEach-Object { [int]$_.itemCount }) -join "," -eq "500,500,200") -Message "Baseline chunk sizes are not 500,500,200."
Assert-True -Condition (@($chunkSyncRunIds | Sort-Object -Unique).Count -eq 3) -Message "Chunk syncRunId values are not unique."
Assert-True -Condition (@($chunkIdempotencyKeys | Sort-Object -Unique).Count -eq 3) -Message "Chunk idempotencyKey values are not unique."
Assert-True -Condition (@($successManifest.chunks | Where-Object { $_.syncRunId -ne $_.idempotencyKey }).Count -eq 0) -Message "Chunk header and HTTP idempotency keys diverged."
Assert-True -Condition ($successManifest.parentSyncRunId -eq $successSummary.syncRunId) -Message "Local parentSyncRunId evidence is missing."
Assert-True -Condition ($successSummary.sendStatus -eq "sent-chunked" -and $successSummary.chunksSent -eq 3) -Message "Successful chunked baseline summary is invalid."
Assert-True -Condition ($successConsole -notmatch [regex]::Escape($fakeToken)) -Message "Token appeared in successful baseline output."
foreach ($chunk in @($successManifest.chunks)) {
    Assert-True -Condition ([int]$chunk.itemCount -le 1000) -Message "A baseline request exceeded 1000 items."
    $chunkPayload = Get-Content -Raw -LiteralPath (Join-Path $successRun ([string]$chunk.payloadRelativePath)) -Encoding UTF8 | ConvertFrom-Json
    Assert-True -Condition ($chunkPayload.syncRunId -eq $chunk.syncRunId -and $chunkPayload.idempotencyKey -eq $chunk.idempotencyKey) -Message "Chunk payload identity does not match its manifest."
}

$resumeOutput = Join-Path $resolvedOutputDirectory "resume"
Initialize-BaselineState -RunOutput $resumeOutput
$failedConsole = ""
$failedAsExpected = $false
try {
    $failedConsole = & $mainScript `
        -FixturePath $fixturePath `
        -OutputDirectory $resumeOutput `
        -SourceKey "neptuno-initial-baseline-smoke" `
        -BodegaId 1 `
        -Mode All `
        -Eligibility AllForAudit `
        -RunType Incremental `
        -BatchSize 500 `
        -ProgressEveryBatches 1000 `
        -ApiUrl "https://127.0.0.1:1/must-not-connect" `
        -ApiToken $fakeToken `
        -Send `
        -InitialBaseline `
        -ChunkSize 500 `
        -MockSendSuccess `
        -MockChunkFailureAt 2 6>&1 | Out-String
}
catch {
    $failedAsExpected = $_.Exception.Message -match "chunk failure at chunk 2"
    $failedConsole += $_.Exception.Message
}
Assert-True -Condition $failedAsExpected -Message "Synthetic mid-baseline failure was not surfaced."
Assert-True -Condition ($failedConsole -notmatch [regex]::Escape($fakeToken)) -Message "Token appeared in failed baseline output."
$failedRun = Get-NewestRunDirectory -RunOutput $resumeOutput
$failedManifest = Get-Content -Raw -LiteralPath (Join-Path $failedRun "chunks/manifest.json") -Encoding UTF8 | ConvertFrom-Json
$failedCheckpoint = Get-Content -Raw -LiteralPath (Join-Path $failedRun "checkpoint.json") -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition ($failedManifest.status -eq "failed" -and $failedManifest.sentChunks -eq 1) -Message "Mid-baseline failure did not preserve resumable progress."
Assert-True -Condition ($failedManifest.chunks[0].status -eq "sent" -and $failedManifest.chunks[1].status -eq "failed" -and $failedManifest.chunks[2].status -eq "pending") -Message "Failed chunk statuses are invalid."
Assert-True -Condition ($failedCheckpoint.status -eq "failed" -and $failedCheckpoint.initialBaseline -eq $true) -Message "Failed baseline checkpoint is not resumable."

$resumeConsole = & $mainScript `
    -FixturePath $fixturePath `
    -OutputDirectory $resumeOutput `
    -SourceKey "neptuno-initial-baseline-smoke" `
    -BodegaId 1 `
    -Mode All `
    -Eligibility AllForAudit `
    -RunType Incremental `
    -BatchSize 500 `
    -ProgressEveryBatches 1000 `
    -ApiUrl "https://127.0.0.1:1/must-not-connect" `
    -ApiToken $fakeToken `
    -Send `
    -InitialBaseline `
    -ChunkSize 500 `
    -Resume `
    -MockSendSuccess 6>&1 | Out-String
$resumedManifest = Get-Content -Raw -LiteralPath (Join-Path $failedRun "chunks/manifest.json") -Encoding UTF8 | ConvertFrom-Json
$resumedSummary = Get-Content -Raw -LiteralPath (Join-Path $failedRun "sync-summary.json") -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition ($resumedManifest.status -eq "completed" -and $resumedManifest.sentChunks -eq 3) -Message "Baseline resume did not complete all chunks."
Assert-True -Condition ($resumedManifest.chunks[0].attemptCount -eq 1 -and $resumedManifest.chunks[1].attemptCount -eq 2 -and $resumedManifest.chunks[2].attemptCount -eq 1) -Message "Resume retransmitted an already accepted chunk or lost retry evidence."
Assert-True -Condition ($resumedSummary.resumed -eq $true -and $resumedSummary.sendStatus -eq "sent-chunked") -Message "Resumed baseline summary is invalid."
Assert-True -Condition ($resumeConsole -notmatch [regex]::Escape($fakeToken)) -Message "Token appeared in resumed baseline output."
$resumedState = Get-Content -Raw -LiteralPath (Join-Path $resumeOutput "state/fingerprints.json") -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition (@($resumedState.sentCatalog.PSObject.Properties).Count -eq 1200) -Message "Completed baseline did not confirm sent catalog fingerprints."

$postBaselineConsole = & $mainScript `
    -FixturePath $fixturePath `
    -OutputDirectory $resumeOutput `
    -SourceKey "neptuno-initial-baseline-smoke" `
    -BodegaId 1 `
    -Mode All `
    -Eligibility AllForAudit `
    -RunType Incremental `
    -BatchSize 500 `
    -ProgressEveryBatches 1000 `
    -ApiUrl "https://127.0.0.1:1/must-not-connect" `
    -ApiToken $fakeToken `
    -Send `
    -MaxSendItems 1000 `
    -MockSendSuccess 6>&1 | Out-String
$postBaselineSummary = Get-Content -Raw -LiteralPath (Join-Path $resumeOutput "latest/sync-summary.json") -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition ($postBaselineSummary.changedCatalogItems -eq 0 -and $postBaselineSummary.sendStatus -eq "no-changes") -Message "Normal incremental did not become empty after baseline completion."
Assert-True -Condition ($postBaselineConsole -notmatch [regex]::Escape($fakeToken)) -Message "Token appeared in post-baseline output."

$guardOutput = Join-Path $resolvedOutputDirectory "guard"
Initialize-BaselineState -RunOutput $guardOutput
$guardBlocked = $false
try {
    & $mainScript `
        -FixturePath $fixturePath `
        -OutputDirectory $guardOutput `
        -SourceKey "neptuno-initial-baseline-smoke" `
        -BodegaId 1 `
        -Mode All `
        -Eligibility AllForAudit `
        -RunType Incremental `
        -BatchSize 500 `
        -ProgressEveryBatches 1000 `
        -ApiUrl "https://127.0.0.1:1/must-not-connect" `
        -ApiToken $fakeToken `
        -Send `
        -MaxSendItems 1000 `
        -MockSendSuccess 6>&1 | Out-Null
}
catch {
    $guardBlocked = $_.Exception.Message -match "MaxSendItems=1000"
}
Assert-True -Condition $guardBlocked -Message "Non-chunked 1200-item send bypassed MaxSendItems."

Write-Host "NEPTUNO initial baseline chunk smoke passed."
Write-Host "1200 items to 3 chunks: OK"
Write-Host "Unique syncRunId and idempotencyKey per chunk: OK"
Write-Host "Maximum 1000 items per request: OK"
Write-Host "Token output isolation: OK"
Write-Host "Mid-run failure and idempotent resume: OK"
Write-Host "Post-baseline incremental transition: OK"
Write-Host "Non-chunked MaxSendItems guard: OK"
Write-Host "Smoke evidence root: $resolvedOutputDirectory"
