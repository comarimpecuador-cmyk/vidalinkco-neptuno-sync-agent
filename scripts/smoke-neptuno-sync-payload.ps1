[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) "exports/neptuno-sync-smoke")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent $PSScriptRoot
$mainScript = Join-Path $PSScriptRoot "sync-neptuno-catalog.ps1"
$catalogSqlPath = Join-Path $repoRoot "docs/sql/neptuno-sync-catalog-query.sql"
$liveSqlPath = Join-Path $repoRoot "docs/sql/neptuno-sync-live-query.sql"
$resolvedOutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$fixturePath = Join-Path $resolvedOutputDirectory "fixtures/fixture.json"
$runOutput = Join-Path $resolvedOutputDirectory "run"

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-PowerShellParser {
    param([Parameter(Mandatory)][string]$Path)

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "PowerShell parser failed for '$Path': $($errors[0].Message)"
    }
}

function Import-MainFunctionForSmoke {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $functionAst = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true))[0]
    Assert-True -Condition ($null -ne $functionAst) -Message "Main function '$Name' was not found."
    Set-Item -Path "Function:script:$Name" -Value $functionAst.Body.GetScriptBlock()
}

function Assert-SelectOnlySqlFile {
    param([Parameter(Mandatory)][string]$Path)

    $sql = Get-Content -Raw -LiteralPath $Path -Encoding UTF8
    $withoutComments = [regex]::Replace($sql, '(?s)/\*.*?\*/|--[^\r\n]*', '')
    Assert-True -Condition ($withoutComments -notmatch '(?i)\b(INSERT|UPDATE|DELETE|MERGE|ALTER|DROP|TRUNCATE|EXEC(?:UTE)?|GRANT|REVOKE|DENY)\b') -Message "Unsafe SQL statement found in '$Path'."
    Assert-True -Condition ($withoutComments.Trim() -match '^(?i)(SELECT|WITH)\b') -Message "SQL is not SELECT/CTE-only: '$Path'."
}

function New-FixtureCatalogRow {
    param(
        [Parameter(Mandatory)][string]$ExternalId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][decimal]$Price,
        [Parameter()][string]$CanSell = "S",
        [Parameter()][string]$CategoryName = "MEDICAMENTOS"
    )

    return [pscustomobject][ordered]@{
        externalId = $ExternalId
        nombreOriginal = $Name
        nombreLargo = $Name
        precioOrigen = $Price
        aplicaIvaOrigen = "N"
        ivaOrigenId = "0"
        categoriaExternalId = "MED"
        categoriaNombre = $CategoryName
        subcategoriaExternalId = "LIP"
        subcategoriaNombre = "LIPIDOS"
        estadoExternalId = "ACT"
        estadoNombre = "ACTIVO"
        puedeVender = $CanSell
        presentacionCodigo = "COM"
        presentacionNombre = "COMPRIMIDOS"
        medidaCodigo = "MG10"
        medidaNombre = "600 MG"
        concentracionCodigo = "G134"
        concentracionNombre = "600 MG"
        unidadesPorCaja = 20
        fabricanteExternalId = "100"
        fabricanteCodigo = "ECUA"
        fabricanteNombre = "LABORATORIO EJEMPLO"
        generico = "S"
        restriccionMedica = "N"
        cronico = "S"
        requiereMedico = "N"
        vademecumExternalId = "1809"
        vademecumNombre = "GEMFIBROZILO"
        vademecumSectionNames = "ACCION|INDICACIONES|DOSIS|CONTRAINDICACIONES Y ADVERTENCIAS"
    }
}

function New-FixtureLiveRow {
    param(
        [Parameter(Mandatory)][string]$ExternalId,
        [Parameter(Mandatory)][decimal]$Price,
        [Parameter(Mandatory)][decimal]$StockUnit,
        [Parameter(Mandatory)][decimal]$StockFraction,
        [Parameter()][string]$CanSell = "S",
        [Parameter()][string]$WarehouseEnabled = "S"
    )

    return [pscustomobject][ordered]@{
        externalId = $ExternalId
        bodegaExternalId = "1"
        bodegaNombre = "PRINCIPAL"
        precioActual = $Price
        stockUnidad = $StockUnit
        stockFraccion = $StockFraction
        estadoExternalId = "ACT"
        estadoNombre = "ACTIVO"
        puedeVender = $CanSell
        aplicaIvaOrigen = "N"
        ivaOrigenId = "0"
        bodegaHabilitado = $WarehouseEnabled
    }
}

function Write-Fixture {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][decimal]$Price9102 = 6.20,
        [Parameter()][string]$Category9102 = "MEDICAMENTOS"
    )

    $fixture = [pscustomobject][ordered]@{
        catalogRows = @(
            New-FixtureCatalogRow -ExternalId "9102" -Name $Name -Price $Price9102 -CategoryName $Category9102
            New-FixtureCatalogRow -ExternalId "1982" -Name "PRODUCTO STOCK NEGATIVO" -Price 5.00
            New-FixtureCatalogRow -ExternalId "3000" -Name "PRODUCTO PRECIO NEGATIVO" -Price -1.00
            New-FixtureCatalogRow -ExternalId "4000" -Name "PRODUCTO STOCK CERO" -Price 4.00
            New-FixtureCatalogRow -ExternalId "5000" -Name "PRODUCTO NO VENDIBLE" -Price 5.00 -CanSell "N"
            New-FixtureCatalogRow -ExternalId "6000" -Name "PRODUCTO BODEGA DESHABILITADA" -Price 6.00
        )
        liveRows = @(
            New-FixtureLiveRow -ExternalId "9102" -Price $Price9102 -StockUnit 1 -StockFraction 3
            New-FixtureLiveRow -ExternalId "1982" -Price 5.00 -StockUnit -2 -StockFraction -1
            New-FixtureLiveRow -ExternalId "3000" -Price -1.00 -StockUnit 2 -StockFraction 0
            New-FixtureLiveRow -ExternalId "4000" -Price 4.00 -StockUnit 0 -StockFraction 0
            New-FixtureLiveRow -ExternalId "5000" -Price 5.00 -StockUnit 1 -StockFraction 0 -CanSell "N"
            New-FixtureLiveRow -ExternalId "6000" -Price 6.00 -StockUnit 1 -StockFraction 0 -WarehouseEnabled "N"
        )
    }
    [System.IO.File]::WriteAllText($fixturePath, (($fixture | ConvertTo-Json -Depth 10) + "`n"), [System.Text.UTF8Encoding]::new($false))
}

function Get-LatestRunDirectory {
    param([Parameter(Mandatory)][string]$Root)

    $summaryPath = Join-Path $Root "latest/sync-summary.json"
    Assert-True -Condition ([System.IO.File]::Exists($summaryPath)) -Message "Latest summary is missing in '$Root'."
    $summary = Get-Content -Raw -LiteralPath $summaryPath -Encoding UTF8 | ConvertFrom-Json
    $runDirectory = Join-Path (Join-Path $Root "runs") $summary.syncRunId
    Assert-True -Condition ([System.IO.Directory]::Exists($runDirectory)) -Message "Latest run directory is missing in '$Root'."
    return $runDirectory
}

Assert-PowerShellParser -Path $mainScript
Assert-PowerShellParser -Path $PSCommandPath
Assert-SelectOnlySqlFile -Path $catalogSqlPath
Assert-SelectOnlySqlFile -Path $liveSqlPath
Import-MainFunctionForSmoke -Path $mainScript -Name "Get-NormalizedExternalIds"
Import-MainFunctionForSmoke -Path $mainScript -Name "Add-ExternalIdsSqlFilter"
$normalizedMissingIds = Get-NormalizedExternalIds -Values @()
Assert-True -Condition ($null -eq $normalizedMissingIds) -Message "Empty ExternalIds did not normalize to null."
$normalizedIds = @(Get-NormalizedExternalIds -Values @(" 9102 ", "9102,1982", "", "1982"))
Assert-True -Condition ($normalizedIds.Count -eq 2 -and $normalizedIds[0] -eq "9102" -and $normalizedIds[1] -eq "1982") -Message "ExternalIds trim/dedup normalization failed."
$unfilteredSql = Add-ExternalIdsSqlFilter -Sql "SELECT 1 WHERE 1 = 1 /*__EXTERNAL_IDS_FILTER__*/;" -Parameters @{} -Ids $normalizedMissingIds
Assert-True -Condition ($unfilteredSql.Sql -notmatch 'EXTERNAL_IDS_FILTER' -and $unfilteredSql.Parameters.Count -eq 0) -Message "Empty ExternalIds SQL binding failed."

if ([System.IO.Directory]::Exists($resolvedOutputDirectory)) {
    $allowedSmokeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "exports")).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedOutputDirectory.StartsWith($allowedSmokeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Smoke cleanup refused an OutputDirectory outside repo exports."
    }
    Remove-Item -LiteralPath $resolvedOutputDirectory -Recurse -Force
}
[System.IO.Directory]::CreateDirectory($resolvedOutputDirectory) | Out-Null
[System.IO.Directory]::CreateDirectory((Split-Path -Parent $fixturePath)) | Out-Null
Write-Fixture -Name "GEMFIBROZILO COMx600MGx20 ECUA"

$savedApiUrl = $env:VIDALINKCO_NEPTUNO_SYNC_URL
$savedApiToken = $env:VIDALINKCO_NEPTUNO_SYNC_TOKEN
try {
    Remove-Item Env:VIDALINKCO_NEPTUNO_SYNC_URL -ErrorAction SilentlyContinue
    Remove-Item Env:VIDALINKCO_NEPTUNO_SYNC_TOKEN -ErrorAction SilentlyContinue
    $missingUrlRejected = $false
    try {
        & $mainScript -FixturePath $fixturePath -OutputDirectory (Join-Path $resolvedOutputDirectory "send-guard") -Send -ApiToken "smoke-value-never-sent"
    }
    catch {
        $missingUrlRejected = $_.Exception.Message -match 'ApiUrl'
    }
    Assert-True -Condition $missingUrlRejected -Message "-Send did not reject a missing ApiUrl before network access."

    $missingTokenRejected = $false
    try {
        & $mainScript -FixturePath $fixturePath -OutputDirectory (Join-Path $resolvedOutputDirectory "send-guard") -Send -ApiUrl "https://127.0.0.1:1/must-not-connect"
    }
    catch {
        $missingTokenRejected = $_.Exception.Message -match 'ApiToken'
    }
    Assert-True -Condition $missingTokenRejected -Message "-Send did not reject a missing ApiToken before network access."
}
finally {
    if ($null -eq $savedApiUrl) { Remove-Item Env:VIDALINKCO_NEPTUNO_SYNC_URL -ErrorAction SilentlyContinue } else { $env:VIDALINKCO_NEPTUNO_SYNC_URL = $savedApiUrl }
    if ($null -eq $savedApiToken) { Remove-Item Env:VIDALINKCO_NEPTUNO_SYNC_TOKEN -ErrorAction SilentlyContinue } else { $env:VIDALINKCO_NEPTUNO_SYNC_TOKEN = $savedApiToken }
}

$commonArguments = @{
    FixturePath = $fixturePath
    OutputDirectory = $runOutput
    SourceKey = "neptuno-smoke"
    BodegaId = 1
    Mode = "All"
    Eligibility = "AllForAudit"
    OnInvalidLive = "Quarantine"
    DryRun = $true
    ApiUrl = "https://127.0.0.1:1/must-not-connect"
    ApiToken = "smoke-value-never-sent"
}

& $mainScript @commonArguments -RunType "Bootstrap" -RebuildState
$bootstrapRun = Get-LatestRunDirectory -Root $runOutput
$summary1 = Get-Content -Raw -LiteralPath (Join-Path $bootstrapRun "sync-summary.json") -Encoding UTF8 | ConvertFrom-Json
$state1 = Get-Content -Raw -LiteralPath (Join-Path $runOutput "state/fingerprints.json") -Encoding UTF8 | ConvertFrom-Json
$cursors1 = Get-Content -Raw -LiteralPath (Join-Path $runOutput "state/cursors.json") -Encoding UTF8 | ConvertFrom-Json
$catalog1 = Get-Content -Raw -LiteralPath (Join-Path $bootstrapRun "catalog-payload.json") -Encoding UTF8 | ConvertFrom-Json
$live1 = Get-Content -Raw -LiteralPath (Join-Path $bootstrapRun "live-payload.json") -Encoding UTF8 | ConvertFrom-Json
$delta1 = Get-Content -Raw -LiteralPath (Join-Path $bootstrapRun "changed-products.json") -Encoding UTF8 | ConvertFrom-Json
$quarantine1 = Get-Content -Raw -LiteralPath (Join-Path $bootstrapRun "quarantine-items.json") -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition ($summary1.runType -eq "Bootstrap") -Message "Bootstrap run type was not recorded."
Assert-True -Condition ($summary1.externalIdsFilterApplied -eq $false) -Message "Missing ExternalIds was serialized as an applied filter."
Assert-True -Condition ($summary1.dryRun -eq $true -and $summary1.sendAttempted -eq $false) -Message "Dry-run attempted network send."
Assert-True -Condition ($summary1.changedCatalogItems -eq 6 -and $summary1.changedLiveItems -eq 5) -Message "Initial changed-products detection failed."
Assert-True -Condition ($summary1.quarantinedItems -eq 2 -and $summary1.warnings -eq 1) -Message "Quarantine summary counts are invalid."
Assert-True -Condition ($summary1.negativePriceItems -eq 1 -and $summary1.negativeStockItems -eq 1) -Message "Negative live counters are invalid."
Assert-True -Condition ($null -ne $delta1.PSObject.Properties["catalogChangedItems"] -and $null -ne $delta1.PSObject.Properties["liveChangedItems"]) -Message "Delta v2 changed item arrays are missing."
Assert-True -Condition ($null -eq $delta1.PSObject.Properties["catalogItems"] -and $null -eq $delta1.PSObject.Properties["liveItems"]) -Message "Legacy delta field names reappeared."
Assert-True -Condition (@($catalog1.items[0].vademecumSecciones).Count -eq 4) -Message "Vademecum section metadata must be a flat string array."
Assert-True -Condition ($catalog1.items[0].vademecumSecciones[0] -is [string]) -Message "Vademecum section metadata contains a nested value."
Assert-True -Condition (@($state1.sentCatalog.PSObject.Properties).Count -eq 0 -and @($state1.sentLive.PSObject.Properties).Count -eq 0) -Message "Dry-run consumed pending send fingerprints."
$negativeStockItem = @($live1.items | Where-Object { $_.externalId -eq "1982" })[0]
Assert-True -Condition ($negativeStockItem.stockUnidad -eq 0 -and $negativeStockItem.stockFraccion -eq 0) -Message "Negative stock was not clamped to zero."
Assert-True -Condition ($negativeStockItem.rawOperativo.sourceStockUnidad -eq -2 -and $negativeStockItem.rawOperativo.sourceStockFraccion -eq -1) -Message "Negative source stock metadata was lost."
Assert-True -Condition ($negativeStockItem.rawOperativo.stockNormalizedReason -eq "NEGATIVE_STOCK_CLAMPED") -Message "Negative stock normalization reason is missing."
Assert-True -Condition (@($live1.items | Where-Object { $_.externalId -eq "3000" }).Count -eq 0) -Message "Negative price item entered live payload."
Assert-True -Condition (@($catalog1.items | Where-Object { $_.externalId -eq "3000" }).Count -eq 1) -Message "Negative price item metadata was removed from catalog."
Assert-True -Condition (@($quarantine1.items | Where-Object { $_.reason -eq "NEGATIVE_PRICE" -and $_.externalId -eq "3000" }).Count -eq 1) -Message "Negative price quarantine record is missing."
Assert-True -Condition (@($quarantine1.items | Where-Object { $_.reason -eq "NEGATIVE_STOCK_CLAMPED" -and $_.externalId -eq "1982" }).Count -eq 1) -Message "Negative stock warning record is missing."
Assert-True -Condition ($null -ne $cursors1.lastCatalogSyncAt -and $null -ne $cursors1.lastLiveSyncAt) -Message "Bootstrap cursors were not created."
Assert-True -Condition ($null -eq $cursors1.lastSuccessfulSendAt) -Message "Bootstrap dry-run incorrectly confirmed a send cursor."
Assert-True -Condition ($cursors1.queryStrategy.catalog -eq "eligible-scan-fingerprint-fallback") -Message "Cursor fallback strategy is missing."

& $mainScript @commonArguments -RunType "Incremental"
$incrementalRun = Get-LatestRunDirectory -Root $runOutput
$summary2 = Get-Content -Raw -LiteralPath (Join-Path $incrementalRun "sync-summary.json") -Encoding UTF8 | ConvertFrom-Json
$state2 = Get-Content -Raw -LiteralPath (Join-Path $runOutput "state/fingerprints.json") -Encoding UTF8 | ConvertFrom-Json
$incrementalCatalog = Get-Content -Raw -LiteralPath (Join-Path $incrementalRun "catalog-payload.json") -Encoding UTF8 | ConvertFrom-Json
$incrementalLive = Get-Content -Raw -LiteralPath (Join-Path $incrementalRun "live-payload.json") -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition ($summary2.changedCatalogItems -eq 0 -and $summary2.changedLiveItems -eq 0) -Message "Deterministic unchanged detection failed."
Assert-True -Condition (@($incrementalCatalog.items).Count -eq 0 -and @($incrementalLive.items).Count -eq 0) -Message "Incremental payload included unchanged items."
Assert-True -Condition ($state1.catalog."9102" -eq $state2.catalog."9102") -Message "Catalog fingerprint is not deterministic."
Assert-True -Condition ($state1.live."9102|1" -eq $state2.live."9102|1") -Message "Live fingerprint is not deterministic."
Assert-True -Condition (@($state2.sentCatalog.PSObject.Properties).Count -eq 0 -and @($state2.sentLive.PSObject.Properties).Count -eq 0) -Message "Incremental dry-run consumed pending send fingerprints."

$sendArguments = $commonArguments.Clone()
[void]$sendArguments.Remove("DryRun")
$sendArguments["Send"] = $true
$sendArguments["MockSendSuccess"] = $true
$sendArguments["RunType"] = "Incremental"
& $mainScript @sendArguments
$sentRun = Get-LatestRunDirectory -Root $runOutput
$sentSummary = Get-Content -Raw -LiteralPath (Join-Path $sentRun "sync-summary.json") -Encoding UTF8 | ConvertFrom-Json
$sentState = Get-Content -Raw -LiteralPath (Join-Path $runOutput "state/fingerprints.json") -Encoding UTF8 | ConvertFrom-Json
$sentCursors = Get-Content -Raw -LiteralPath (Join-Path $runOutput "state/cursors.json") -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition ($sentSummary.sendStatus -eq "sent" -and $sentSummary.sendAttempted -eq $true) -Message "Mock successful send was not recorded."
Assert-True -Condition (@($sentState.sentCatalog.PSObject.Properties).Count -eq 6 -and @($sentState.sentLive.PSObject.Properties).Count -eq 5) -Message "Successful send did not confirm fingerprints."
Assert-True -Condition ($null -ne $sentCursors.lastSuccessfulSendAt) -Message "Successful send cursor is missing."

Write-Fixture -Name "GEMFIBROZILO COMx600MGx20 ECUA" -Price9102 6.50
& $mainScript @commonArguments -RunType "Incremental"
$priceRun = Get-LatestRunDirectory -Root $runOutput
$priceSummary = Get-Content -Raw -LiteralPath (Join-Path $priceRun "sync-summary.json") -Encoding UTF8 | ConvertFrom-Json
$priceCatalog = Get-Content -Raw -LiteralPath (Join-Path $priceRun "catalog-payload.json") -Encoding UTF8 | ConvertFrom-Json
$priceLive = Get-Content -Raw -LiteralPath (Join-Path $priceRun "live-payload.json") -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition ($priceSummary.changedCatalogItems -eq 0 -and $priceSummary.changedLiveItems -eq 1) -Message "Price change did not produce live-only delta."
Assert-True -Condition (@($priceCatalog.items).Count -eq 0 -and @($priceLive.items).Count -eq 1 -and $priceLive.items[0].externalId -eq "9102") -Message "Price incremental payload is not live-only."

Write-Fixture -Name "GEMFIBROZILO NOMBRE CAMBIADO" -Price9102 6.50 -Category9102 "CARDIOVASCULAR"
& $mainScript @commonArguments -RunType "Incremental"
$catalogChangeRun = Get-LatestRunDirectory -Root $runOutput
$summary3 = Get-Content -Raw -LiteralPath (Join-Path $catalogChangeRun "sync-summary.json") -Encoding UTF8 | ConvertFrom-Json
$catalogChangePayload = Get-Content -Raw -LiteralPath (Join-Path $catalogChangeRun "catalog-payload.json") -Encoding UTF8 | ConvertFrom-Json
$liveAfterCatalogChange = Get-Content -Raw -LiteralPath (Join-Path $catalogChangeRun "live-payload.json") -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition ($summary3.changedCatalogItems -eq 1 -and $summary3.changedLiveItems -eq 0) -Message "Master data change did not produce catalog-only delta."
Assert-True -Condition (@($catalogChangePayload.items).Count -eq 1 -and @($liveAfterCatalogChange.items).Count -eq 0) -Message "Master data incremental payload is not catalog-only."

$filteredOutput = Join-Path $resolvedOutputDirectory "external-ids"
$filteredArguments = $commonArguments.Clone()
$filteredArguments["OutputDirectory"] = $filteredOutput
$filteredArguments["ExternalIds"] = @("9102", "1982")
$filteredArguments["RunType"] = "Audit"
$filteredArguments["RebuildState"] = $true
& $mainScript @filteredArguments
$filteredRun = Get-LatestRunDirectory -Root $filteredOutput
$filteredSummary = Get-Content -Raw -LiteralPath (Join-Path $filteredRun "sync-summary.json") -Encoding UTF8 | ConvertFrom-Json
$filteredCatalog = Get-Content -Raw -LiteralPath (Join-Path $filteredRun "catalog-payload.json") -Encoding UTF8 | ConvertFrom-Json
$filteredLive = Get-Content -Raw -LiteralPath (Join-Path $filteredRun "live-payload.json") -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition ($filteredSummary.externalIdsFilterApplied -eq $true) -Message "ExternalIds filter was not reported."
Assert-True -Condition (@($filteredCatalog.items).Count -eq 2 -and @($filteredLive.items).Count -eq 2) -Message "ExternalIds did not filter catalog and live payloads."
Assert-True -Condition (@($filteredCatalog.items | Where-Object { $_.externalId -notin @("9102", "1982") }).Count -eq 0) -Message "ExternalIds leaked another catalog item."
Assert-True -Condition ($filteredSummary.runType -eq "Audit" -and $filteredSummary.sendAttempted -eq $false -and $filteredSummary.stateUpdated -eq $false) -Message "Audit run mutated state or attempted send."

$emptyFilterOutput = Join-Path $resolvedOutputDirectory "empty-external-ids"
$emptyFilterArguments = $commonArguments.Clone()
$emptyFilterArguments["OutputDirectory"] = $emptyFilterOutput
$emptyFilterArguments["ExternalIds"] = @("", " ", ",")
$emptyFilterArguments["RunType"] = "Audit"
& $mainScript @emptyFilterArguments
$emptyFilterRun = Get-LatestRunDirectory -Root $emptyFilterOutput
$emptyFilterSummary = Get-Content -Raw -LiteralPath (Join-Path $emptyFilterRun "sync-summary.json") -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition ($emptyFilterSummary.externalIdsFilterApplied -eq $false -and $emptyFilterSummary.catalogItems -eq 6) -Message "Empty ExternalIds did not behave as no filter."

$withStockOutput = Join-Path $resolvedOutputDirectory "active-with-stock"
$withStockArguments = $commonArguments.Clone()
$withStockArguments["OutputDirectory"] = $withStockOutput
$withStockArguments["Eligibility"] = "ActiveSellableWithStock"
$withStockArguments["RunType"] = "Audit"
$withStockArguments["RebuildState"] = $true
& $mainScript @withStockArguments
$withStockRun = Get-LatestRunDirectory -Root $withStockOutput
$withStockLive = Get-Content -Raw -LiteralPath (Join-Path $withStockRun "live-payload.json") -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition (@($withStockLive.items).Count -eq 1 -and $withStockLive.items[0].externalId -eq "9102") -Message "ActiveSellableWithStock did not exclude zero, unsellable or disabled stock."

$failFastOutput = Join-Path $resolvedOutputDirectory "fail-fast"
$failFastRejected = $false
$failFastArguments = $commonArguments.Clone()
$failFastArguments["OutputDirectory"] = $failFastOutput
$failFastArguments["OnInvalidLive"] = "FailFast"
$failFastArguments["RunType"] = "Audit"
$failFastArguments["RebuildState"] = $true
try {
    & $mainScript @failFastArguments
}
catch {
    $failFastRejected = $_.Exception.Message -match 'FailFast'
}
Assert-True -Condition $failFastRejected -Message "OnInvalidLive=FailFast did not reject negative price."
$failFastRun = Get-LatestRunDirectory -Root $failFastOutput
$failFastSummary = Get-Content -Raw -LiteralPath (Join-Path $failFastRun "sync-summary.json") -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition ($failFastSummary.stateUpdated -eq $false -and $failFastSummary.negativePriceItems -eq 1) -Message "FailFast summary is incomplete."

$retentionOutput = Join-Path $resolvedOutputDirectory "retention"
$retentionArguments = $commonArguments.Clone()
$retentionArguments["OutputDirectory"] = $retentionOutput
$retentionArguments["ExternalIds"] = @("9102")
$retentionArguments["RetentionRuns"] = 2
1..3 | ForEach-Object {
    $retentionArguments["RunType"] = $(if ($_ -eq 1) { "Bootstrap" } else { "Incremental" })
    & $mainScript @retentionArguments
}
$retainedRuns = @(Get-ChildItem -LiteralPath (Join-Path $retentionOutput "runs") -Directory)
Assert-True -Condition ($retainedRuns.Count -eq 2) -Message "RetentionRuns did not remove old run directories."
Assert-True -Condition ([System.IO.File]::Exists((Join-Path $retentionOutput "state/fingerprints.json"))) -Message "Retention removed permanent fingerprint state."
Assert-True -Condition ([System.IO.File]::Exists((Join-Path $retentionOutput "state/cursors.json"))) -Message "Retention removed permanent cursors."

$splitModeOutput = Join-Path $resolvedOutputDirectory "split-mode"
$splitArguments = $commonArguments.Clone()
$splitArguments["OutputDirectory"] = $splitModeOutput
$splitArguments["ExternalIds"] = @("9102")
$splitArguments["RunType"] = "Bootstrap"
$splitArguments["Mode"] = "Catalog"
& $mainScript @splitArguments
$splitArguments["Mode"] = "Live"
& $mainScript @splitArguments
$splitState = Get-Content -Raw -LiteralPath (Join-Path $splitModeOutput "state/fingerprints.json") -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition (@($splitState.catalog.PSObject.Properties).Count -eq 1 -and @($splitState.live.PSObject.Properties).Count -eq 1) -Message "Separate Catalog/Live bootstrap erased the untouched branch."

$ignoredProbe = "exports/neptuno-sync-smoke/ignored-probe.json"
$ignoreResult = & git -C $repoRoot check-ignore $ignoredProbe
Assert-True -Condition ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($ignoreResult)) -Message "exports/ is not ignored by Git."

$requiredOutputs = @(
    "catalog-payload.json",
    "live-payload.json",
    "changed-products.json",
    "quarantine-items.json",
    "sync-summary.json",
    "sync-events.ndjson",
    "sync-warnings.ndjson"
)
foreach ($relativePath in $requiredOutputs) {
    Assert-True -Condition ([System.IO.File]::Exists((Join-Path $bootstrapRun $relativePath))) -Message "Missing bootstrap output '$relativePath'."
}
Assert-True -Condition ([System.IO.File]::Exists((Join-Path $runOutput "state/fingerprints.json"))) -Message "Permanent fingerprints output is missing."
Assert-True -Condition ([System.IO.File]::Exists((Join-Path $runOutput "state/cursors.json"))) -Message "Permanent cursors output is missing."
Assert-True -Condition ([System.IO.File]::Exists((Join-Path $runOutput "latest/sync-summary.json"))) -Message "Latest summary pointer is missing."
Assert-True -Condition (@(Get-ChildItem -LiteralPath $runOutput -File -Force).Count -eq 0) -Message "OutputDirectory root contains loose files."

$payloadJson = @(
    "catalog-payload.json",
    "live-payload.json",
    "changed-products.json",
    "quarantine-items.json"
) | ForEach-Object { Get-Content -Raw -LiteralPath (Join-Path $bootstrapRun $_) -Encoding UTF8 }
$combinedPayload = $payloadJson -join "`n"
Assert-True -Condition ($combinedPayload -notmatch '(?i)"[^\"]*(cabecera|contenido|blob|password|pwd|token|license|serial)[^\"]*"\s*:') -Message "Forbidden property found in generated payload."
Assert-True -Condition ($combinedPayload -notmatch 'System\.Byte\[\]') -Message "Binary marker found in generated payload."
Assert-True -Condition ($combinedPayload -match '"vademecumSecciones"') -Message "Vademecum section metadata is missing."
Assert-True -Condition ($combinedPayload -notmatch '(?i)textoClinico|clinicalText') -Message "Clinical vademecum text field found."

$events = @(Get-Content -LiteralPath (Join-Path $bootstrapRun "sync-events.ndjson") -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
$warnings = @(Get-Content -LiteralPath (Join-Path $bootstrapRun "sync-warnings.ndjson") -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
Assert-True -Condition (@($events | Where-Object { $_.eventType -eq "live-item-quarantined" }).Count -ge 1) -Message "Negative price sync event is missing."
Assert-True -Condition (@($events | Where-Object { $_.eventType -eq "live-stock-normalized" }).Count -ge 1) -Message "Negative stock sync event is missing."
Assert-True -Condition (@($warnings | Where-Object { $_.reason -eq "NEGATIVE_STOCK_CLAMPED" }).Count -ge 1) -Message "Negative stock warning NDJSON is missing."

Write-Host "NEPTUNO sync payload smoke passed."
Write-Host "PowerShell parser: OK"
Write-Host "SELECT-only SQL: OK"
Write-Host "Bootstrap and incremental fingerprints: OK"
Write-Host "Dry-run preserves pending send delta: OK"
Write-Host "Successful send confirms state: OK"
Write-Host "Catalog/live delta separation: OK"
Write-Host "Negative live quarantine and stock clamp: OK"
Write-Host "ExternalIds and eligibility filters: OK"
Write-Host "Missing and empty ExternalIds binding: OK"
Write-Host "Audit no-send behavior: OK"
Write-Host "FailFast policy: OK"
Write-Host "Run retention and permanent state: OK"
Write-Host "Separate Catalog/Live state preservation: OK"
Write-Host "Git ignore for exports: OK"
Write-Host "No loose root artifacts: OK"
Write-Host "Payload safety: OK"
Write-Host "Dry-run network isolation: OK"
Write-Host "Send credential guards: OK"
Write-Host "Smoke evidence root: $runOutput"
