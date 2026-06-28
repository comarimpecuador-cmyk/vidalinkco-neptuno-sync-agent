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
$fixturePath = Join-Path $resolvedOutputDirectory "fixture.json"
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

function Assert-SelectOnlySqlFile {
    param([Parameter(Mandatory)][string]$Path)

    $sql = Get-Content -Raw -LiteralPath $Path -Encoding UTF8
    $withoutComments = [regex]::Replace($sql, '(?s)/\*.*?\*/|--[^\r\n]*', '')
    Assert-True -Condition ($withoutComments -notmatch '(?i)\b(INSERT|UPDATE|DELETE|MERGE|ALTER|DROP|TRUNCATE|EXEC(?:UTE)?|GRANT|REVOKE|DENY)\b') -Message "Unsafe SQL statement found in '$Path'."
    Assert-True -Condition ($withoutComments.Trim() -match '^(?i)(SELECT|WITH)\b') -Message "SQL is not SELECT/CTE-only: '$Path'."
}

function Write-Fixture {
    param([Parameter(Mandatory)][string]$Name)

    $fixture = [pscustomobject][ordered]@{
        catalogRows = @(
            [pscustomobject][ordered]@{
                externalId = "9102"
                nombreOriginal = $Name
                nombreLargo = "GEMFIBROZILO COM 600 MG"
                precioOrigen = 6.20
                aplicaIvaOrigen = "N"
                ivaOrigenId = "0"
                categoriaExternalId = "MED"
                categoriaNombre = "MEDICAMENTOS"
                subcategoriaExternalId = "LIP"
                subcategoriaNombre = "LIPIDOS"
                estadoExternalId = "ACT"
                estadoNombre = "ACTIVO"
                puedeVender = "S"
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
        )
        liveRows = @(
            [pscustomobject][ordered]@{
                externalId = "9102"
                bodegaExternalId = "1"
                bodegaNombre = "PRINCIPAL"
                precioActual = 6.20
                stockUnidad = 1
                stockFraccion = 3
                estadoExternalId = "ACT"
                estadoNombre = "ACTIVO"
                puedeVender = "S"
                aplicaIvaOrigen = "N"
                ivaOrigenId = "0"
                bodegaHabilitado = "S"
            }
        )
    }
    [System.IO.File]::WriteAllText($fixturePath, (($fixture | ConvertTo-Json -Depth 10) + "`n"), [System.Text.UTF8Encoding]::new($false))
}

Assert-PowerShellParser -Path $mainScript
Assert-PowerShellParser -Path $PSCommandPath
Assert-SelectOnlySqlFile -Path $catalogSqlPath
Assert-SelectOnlySqlFile -Path $liveSqlPath

if ([System.IO.Directory]::Exists($resolvedOutputDirectory)) {
    Remove-Item -LiteralPath $resolvedOutputDirectory -Recurse -Force
}
[System.IO.Directory]::CreateDirectory($resolvedOutputDirectory) | Out-Null
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
    DryRun = $true
    ApiUrl = "https://127.0.0.1:1/must-not-connect"
    ApiToken = "smoke-value-never-sent"
}

& $mainScript @commonArguments -RebuildState
$summary1 = Get-Content -Raw -LiteralPath (Join-Path $runOutput "sync-summary.json") -Encoding UTF8 | ConvertFrom-Json
$state1 = Get-Content -Raw -LiteralPath (Join-Path $runOutput "state/fingerprints.json") -Encoding UTF8 | ConvertFrom-Json
$catalog1 = Get-Content -Raw -LiteralPath (Join-Path $runOutput "catalog-payload.json") -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition ($summary1.dryRun -eq $true -and $summary1.sendAttempted -eq $false) -Message "Dry-run attempted network send."
Assert-True -Condition ($summary1.changedCatalogItems -eq 1 -and $summary1.changedLiveItems -eq 1) -Message "Initial changed-products detection failed."
Assert-True -Condition ($catalog1.items[0].vademecumSecciones.Count -eq 4) -Message "Vademecum section metadata must be a flat string array."
Assert-True -Condition ($catalog1.items[0].vademecumSecciones[0] -is [string]) -Message "Vademecum section metadata contains a nested value."
Assert-True -Condition (@($state1.sentCatalog.PSObject.Properties).Count -eq 0 -and @($state1.sentLive.PSObject.Properties).Count -eq 0) -Message "Dry-run consumed pending send fingerprints."

& $mainScript @commonArguments
$summary2 = Get-Content -Raw -LiteralPath (Join-Path $runOutput "sync-summary.json") -Encoding UTF8 | ConvertFrom-Json
$state2 = Get-Content -Raw -LiteralPath (Join-Path $runOutput "state/fingerprints.json") -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition ($summary2.changedCatalogItems -eq 0 -and $summary2.changedLiveItems -eq 0) -Message "Deterministic unchanged detection failed."
Assert-True -Condition ($state1.catalog."9102" -eq $state2.catalog."9102") -Message "Catalog fingerprint is not deterministic."
Assert-True -Condition ($state1.live."9102|1" -eq $state2.live."9102|1") -Message "Live fingerprint is not deterministic."

Write-Fixture -Name "GEMFIBROZILO COMx600MGx20 ECUA CAMBIO"
& $mainScript @commonArguments
$summary3 = Get-Content -Raw -LiteralPath (Join-Path $runOutput "sync-summary.json") -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition ($summary3.changedCatalogItems -eq 1 -and $summary3.changedLiveItems -eq 0) -Message "Changed catalog item detection failed."

$requiredOutputs = @(
    "catalog-payload.json",
    "live-payload.json",
    "changed-products.json",
    "sync-summary.json",
    "sync-events.ndjson",
    "state/fingerprints.json"
)
foreach ($relativePath in $requiredOutputs) {
    Assert-True -Condition ([System.IO.File]::Exists((Join-Path $runOutput $relativePath))) -Message "Missing output '$relativePath'."
}

$payloadJson = @(
    "catalog-payload.json",
    "live-payload.json",
    "changed-products.json"
) | ForEach-Object { Get-Content -Raw -LiteralPath (Join-Path $runOutput $_) -Encoding UTF8 }
$combinedPayload = $payloadJson -join "`n"
Assert-True -Condition ($combinedPayload -notmatch '(?i)"[^\"]*(cabecera|contenido|blob|password|pwd|token|license|serial)[^\"]*"\s*:') -Message "Forbidden property found in generated payload."
Assert-True -Condition ($combinedPayload -notmatch 'System\.Byte\[\]') -Message "Binary marker found in generated payload."
Assert-True -Condition ($combinedPayload -match '"vademecumSecciones"') -Message "Vademecum section metadata is missing."
Assert-True -Condition ($combinedPayload -notmatch '(?i)textoClinico|clinicalText') -Message "Clinical vademecum text field found."

$events = @(Get-Content -LiteralPath (Join-Path $runOutput "sync-events.ndjson") -Encoding UTF8)
Assert-True -Condition ($events.Count -eq 3) -Message "Expected three NDJSON smoke events."

Write-Host "NEPTUNO sync payload smoke passed."
Write-Host "PowerShell parser: OK"
Write-Host "SELECT-only SQL: OK"
Write-Host "Deterministic fingerprints: OK"
Write-Host "Dry-run preserves pending send delta: OK"
Write-Host "Changed-products detection: OK"
Write-Host "Payload safety: OK"
Write-Host "Dry-run network isolation: OK"
Write-Host "Send credential guards: OK"
Write-Host "Smoke evidence: $runOutput"
