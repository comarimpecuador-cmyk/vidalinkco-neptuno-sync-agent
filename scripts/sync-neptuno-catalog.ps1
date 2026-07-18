[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConnectionString = "Data Source=localhost;Initial Catalog=NEPTUNO;Integrated Security=True;Encrypt=False;ApplicationIntent=ReadOnly",

    [Parameter()]
    [string]$OutputDirectory,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SourceKey = "neptuno-farmacia-universal",

    [Parameter()]
    [ValidateRange(1, [long]::MaxValue)]
    [long]$BodegaId = 1,

    [Parameter()]
    [ValidateSet("Catalog", "Live", "All")]
    [string]$Mode = "All",

    [Parameter()]
    [ValidateRange(1, 1000000)]
    [Nullable[int]]$MaxProducts,

    [Parameter()]
    [ValidateRange(1, 5000)]
    [int]$BatchSize = 500,

    [Parameter()]
    [ValidateRange(0, [long]::MaxValue)]
    [Nullable[long]]$StartAfterExternalId,

    [Parameter()]
    [ValidateRange(1, 1000000)]
    [Nullable[int]]$MaxBatches,

    [Parameter()]
    [ValidateRange(1, 3600)]
    [int]$CommandTimeoutSeconds = 120,

    [Parameter()]
    [ValidateRange(1, 1000000)]
    [int]$ProgressEveryBatches = 1,

    [Parameter()]
    [switch]$Resume,

    [Parameter()]
    [AllowNull()]
    [AllowEmptyCollection()]
    [string[]]$ExternalIds,

    [Parameter()]
    [ValidateSet("AllForAudit", "ActiveSellable", "ActiveSellableWithStock")]
    [string]$Eligibility = "ActiveSellable",

    [Parameter()]
    [ValidateSet("Quarantine", "FailFast")]
    [string]$OnInvalidLive = "Quarantine",

    [Parameter()]
    [ValidateSet("Bootstrap", "Incremental", "Audit")]
    [string]$RunType = "Incremental",

    [Parameter()]
    [ValidateRange(1, 1000)]
    [int]$RetentionRuns = 10,

    [Parameter()]
    [bool]$RetentionEnabled = $true,

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
    [switch]$CleanupDryRun,

    [Parameter()]
    [switch]$Send,

    [Parameter()]
    [ValidateRange(1, 1000)]
    [int]$MaxSendItems = 1000,

    [Parameter()]
    [switch]$InitialBaseline,

    [Parameter()]
    [ValidateRange(1, 1000)]
    [int]$ChunkSize = 500,

    [Parameter()]
    [ValidateRange(0, 3600)]
    [int]$ChunkDelaySeconds = 5,

    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$MaxChunkAttempts = 8,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [string]$ApiUrl,

    [Parameter()]
    [string]$ApiToken,

    [Parameter()]
    [switch]$RebuildState,

    [Parameter(DontShow)]
    [string]$FixturePath,

    [Parameter(DontShow)]
    [switch]$MockSendSuccess,

    [Parameter(DontShow)]
    [ValidateRange(1, 1000000)]
    [Nullable[int]]$MockChunkFailureAt,

    [Parameter(DontShow)]
    [ValidateRange(1, 1000000)]
    [Nullable[int]]$MockChunkRateLimitAt,

    [Parameter(DontShow)]
    [ValidateRange(0, 3600)]
    [Nullable[int]]$MockRetryAfterSeconds,

    [Parameter(DontShow)]
    [ValidateRange(1, 1000000)]
    [Nullable[int]]$MockTimeoutAtBatch
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot "exports/neptuno-sync"
}
. (Join-Path $PSScriptRoot "NeptunoAudit.Common.ps1")
. (Join-Path $PSScriptRoot "NeptunoSyncRetention.ps1")

function Get-RowValue {
    param(
        [Parameter(Mandatory)]
        $Row,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($Row -is [System.Data.DataRow]) {
        if (-not $Row.Table.Columns.Contains($Name)) {
            return $null
        }
        $value = $Row[$Name]
        return $(if ($value -is [DBNull]) { $null } else { $value })
    }

    $property = $Row.PSObject.Properties[$Name]
    if ($null -eq $property -or $property.Value -is [DBNull]) {
        return $null
    }
    return $property.Value
}

function ConvertTo-NullableString {
    param([Parameter()]$Value)

    if ($null -eq $Value) {
        return $null
    }
    $text = ([string]$Value).Trim()
    return $(if ($text.Length -eq 0) { $null } else { $text })
}

function ConvertTo-RequiredDecimal {
    param(
        [Parameter()]$Value,
        [Parameter(Mandatory)][string]$FieldName,
        [Parameter(Mandatory)][string]$ExternalId
    )

    if ($null -eq $Value) {
        throw "Product '$ExternalId' has no required numeric field '$FieldName'."
    }
    if ($Value -is [decimal] -or $Value -is [double] -or $Value -is [float] -or
        $Value -is [int] -or $Value -is [long]) {
        return [decimal]$Value
    }

    $parsed = 0D
    $text = ([string]$Value).Trim()
    if ([decimal]::TryParse($text, [System.Globalization.NumberStyles]::Number, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -or
        [decimal]::TryParse($text, [System.Globalization.NumberStyles]::Number, [System.Globalization.CultureInfo]::CurrentCulture, [ref]$parsed)) {
        return $parsed
    }
    throw "Product '$ExternalId' has invalid numeric field '$FieldName'."
}

function ConvertTo-NullableDecimal {
    param(
        [Parameter()]$Value,
        [Parameter(Mandatory)][string]$FieldName,
        [Parameter(Mandatory)][string]$ExternalId
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    return ConvertTo-RequiredDecimal -Value $Value -FieldName $FieldName -ExternalId $ExternalId
}

function ConvertTo-NullableBool {
    param([Parameter()]$Value)

    $text = ConvertTo-NullableString -Value $Value
    if ($null -eq $text) {
        return $null
    }
    switch ($text.ToLowerInvariant()) {
        { $_ -in @("s", "si", "sí", "true", "1", "y", "yes") } { return $true }
        { $_ -in @("n", "no", "false", "0") } { return $false }
        default { return $null }
    }
}

function Get-NormalizedExternalIds {
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Values
    )

    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($Values)) {
        foreach ($candidate in @(([string]$value) -split ',')) {
            $id = $candidate.Trim()
            if ($id.Length -eq 0) {
                continue
            }
            if ($id -notmatch '^\d+$') {
                throw "ExternalIds accepts numeric NEPTUNO IDs only."
            }
            if (-not $ids.Contains($id)) {
                $ids.Add($id)
            }
        }
    }
    if ($ids.Count -gt 1000) {
        throw "ExternalIds accepts at most 1000 IDs per run."
    }
    if ($ids.Count -eq 0) {
        return $null
    }
    return $ids.ToArray()
}

function Add-ExternalIdsSqlFilter {
    param(
        [Parameter(Mandatory)][string]$Sql,
        [Parameter(Mandatory)][hashtable]$Parameters,
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Ids
    )

    $placeholder = '/*__EXTERNAL_IDS_FILTER__*/'
    if (-not $Sql.Contains($placeholder)) {
        throw "SQL query is missing the external IDs filter placeholder."
    }
    $normalizedIds = [System.Collections.Generic.List[string]]::new()
    foreach ($id in @($Ids)) {
        if ($null -ne $id) {
            $normalizedIds.Add([string]$id)
        }
    }
    if ($normalizedIds.Count -eq 0) {
        return [pscustomobject]@{
            Sql = $Sql.Replace($placeholder, '')
            Parameters = $Parameters
        }
    }

    $parameterNames = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $normalizedIds.Count; $index++) {
        $name = "ExternalId$index"
        $Parameters[$name] = $normalizedIds[$index]
        $parameterNames.Add("@$name")
    }
    $filter = "AND CAST(i.id_item AS varchar(50)) IN (" + ($parameterNames -join ', ') + ")"
    return [pscustomobject]@{
        Sql = $Sql.Replace($placeholder, $filter)
        Parameters = $Parameters
    }
}

function Get-VademecumSectionNames {
    param([Parameter()]$Value)

    if ($null -eq $Value) {
        return @()
    }
    $rawNames = if ($Value -is [string]) { $Value -split '\|' } else { @($Value) }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($rawName in $rawNames) {
        $name = ConvertTo-NullableString -Value $rawName
        if ($null -ne $name -and -not $names.Contains($name)) {
            $names.Add($name)
        }
    }
    return $names.ToArray()
}

function New-CatalogItem {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$ItemSourceKey
    )

    $externalId = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "externalId")
    if ($null -eq $externalId) {
        throw "Catalog row has no externalId."
    }
    $name = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "nombreOriginal")
    if ($null -eq $name) {
        throw "Product '$externalId' has no nombreOriginal."
    }
    $price = ConvertTo-RequiredDecimal -Value (Get-RowValue -Row $Row -Name "precioOrigen") -FieldName "precioOrigen" -ExternalId $externalId
    return [pscustomobject][ordered]@{
        externalId = $externalId
        sourceKey = $ItemSourceKey.Trim()
        nombreOriginal = $name
        nombreLargo = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "nombreLargo")
        precioOrigen = $price
        aplicaIvaOrigen = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "aplicaIvaOrigen")
        ivaOrigenId = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "ivaOrigenId")
        categoriaExternalId = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "categoriaExternalId")
        categoriaNombre = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "categoriaNombre")
        subcategoriaExternalId = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "subcategoriaExternalId")
        subcategoriaNombre = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "subcategoriaNombre")
        estadoExternalId = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "estadoExternalId")
        estadoNombre = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "estadoNombre")
        puedeVender = ConvertTo-NullableBool -Value (Get-RowValue -Row $Row -Name "puedeVender")
        presentacionCodigo = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "presentacionCodigo")
        presentacionNombre = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "presentacionNombre")
        medidaCodigo = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "medidaCodigo")
        medidaNombre = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "medidaNombre")
        concentracionCodigo = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "concentracionCodigo")
        concentracionNombre = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "concentracionNombre")
        unidadesPorCaja = ConvertTo-NullableDecimal -Value (Get-RowValue -Row $Row -Name "unidadesPorCaja") -FieldName "unidadesPorCaja" -ExternalId $externalId
        fabricanteExternalId = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "fabricanteExternalId")
        fabricanteCodigo = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "fabricanteCodigo")
        fabricanteNombre = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "fabricanteNombre")
        generico = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "generico")
        restriccionMedica = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "restriccionMedica")
        cronico = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "cronico")
        requiereMedico = ConvertTo-NullableBool -Value (Get-RowValue -Row $Row -Name "requiereMedico")
        vademecumExternalId = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "vademecumExternalId")
        vademecumNombre = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "vademecumNombre")
        vademecumSecciones = @(Get-VademecumSectionNames -Value (Get-RowValue -Row $Row -Name "vademecumSectionNames"))
    }
}

function Get-LiveItemEvaluation {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$ItemSourceKey,
        [Parameter(Mandatory)][string]$CapturedAt,
        [Parameter(Mandatory)][string]$EligibilityPolicy
    )

    $externalId = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "externalId")
    if ($null -eq $externalId) {
        throw "Live row has no externalId."
    }
    $warehouseId = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "bodegaExternalId")
    if ($null -eq $warehouseId) {
        throw "Product '$externalId' has no bodegaExternalId."
    }
    $price = ConvertTo-RequiredDecimal -Value (Get-RowValue -Row $Row -Name "precioActual") -FieldName "precioActual" -ExternalId $externalId
    $sourceStockUnit = ConvertTo-RequiredDecimal -Value (Get-RowValue -Row $Row -Name "stockUnidad") -FieldName "stockUnidad" -ExternalId $externalId
    $sourceStockFraction = ConvertTo-RequiredDecimal -Value (Get-RowValue -Row $Row -Name "stockFraccion") -FieldName "stockFraccion" -ExternalId $externalId
    $hasNegativeStock = $sourceStockUnit -lt 0 -or $sourceStockFraction -lt 0
    $stockUnit = [Math]::Max(0D, $sourceStockUnit)
    $stockFraction = [Math]::Max(0D, $sourceStockFraction)
    $canSell = ConvertTo-NullableBool -Value (Get-RowValue -Row $Row -Name "puedeVender")
    $warehouseEnabledSource = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "bodegaHabilitado")
    $warehouseEnabled = ConvertTo-NullableBool -Value $warehouseEnabledSource

    $item = [pscustomobject][ordered]@{
        externalId = $externalId
        sourceKey = $ItemSourceKey.Trim()
        bodegaExternalId = $warehouseId
        bodegaNombre = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "bodegaNombre")
        precioActual = $price
        stockUnidad = $stockUnit
        stockFraccion = $stockFraction
        estadoExternalId = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "estadoExternalId")
        estadoNombre = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "estadoNombre")
        puedeVender = $canSell
        aplicaIvaOrigen = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "aplicaIvaOrigen")
        capturedAt = $CapturedAt
        rawOperativo = [pscustomobject][ordered]@{
            ivaOrigenId = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "ivaOrigenId")
            bodegaHabilitado = $warehouseEnabledSource
            sourceStockUnidad = $(if ($hasNegativeStock) { $sourceStockUnit } else { $null })
            sourceStockFraccion = $(if ($hasNegativeStock) { $sourceStockFraction } else { $null })
            stockNormalizedReason = $(if ($hasNegativeStock) { "NEGATIVE_STOCK_CLAMPED" } else { $null })
        }
    }

    $eligible = $true
    if ($EligibilityPolicy -ne "AllForAudit") {
        $eligible = $canSell -ne $false -and $warehouseEnabled -ne $false
        if ($eligible -and $EligibilityPolicy -eq "ActiveSellableWithStock") {
            $eligible = $stockUnit -gt 0 -or $stockFraction -gt 0
        }
    }

    return [pscustomobject][ordered]@{
        item = $item
        eligible = $eligible
        negativePrice = $price -lt 0
        negativeStock = $hasNegativeStock
        sourcePrice = $price
        sourceStockUnidad = $sourceStockUnit
        sourceStockFraccion = $sourceStockFraction
    }
}

function ConvertTo-StableValue {
    param([Parameter()]$Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [string]) {
        return $Value.Trim()
    }
    if ($Value -is [DateTime] -or $Value -is [DateTimeOffset]) {
        return $Value.ToString("o")
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
            $ordered[$key] = ConvertTo-StableValue -Value $Value[$key]
        }
        return [pscustomobject]$ordered
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $items.Add((ConvertTo-StableValue -Value $item))
        }
        return ,$items.ToArray()
    }
    if ($Value -is [psobject]) {
        $ordered = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
            $ordered[$property.Name] = ConvertTo-StableValue -Value $property.Value
        }
        return [pscustomobject]$ordered
    }
    return $Value
}

function Get-StableFingerprint {
    param([Parameter(Mandatory)]$Value)

    $stableJson = (ConvertTo-StableValue -Value $Value) | ConvertTo-Json -Compress -Depth 30
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($stableJson)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-LiveFingerprintProjection {
    param([Parameter(Mandatory)]$Item)

    $projection = [ordered]@{}
    foreach ($property in $Item.PSObject.Properties) {
        if ($property.Name -ne "capturedAt") {
            $projection[$property.Name] = $property.Value
        }
    }
    return [pscustomobject]$projection
}

function Get-CatalogFingerprintProjection {
    param([Parameter(Mandatory)]$Item)

    $projection = [ordered]@{}
    foreach ($property in $Item.PSObject.Properties) {
        if ($property.Name -ne "precioOrigen") {
            $projection[$property.Name] = $property.Value
        }
    }
    return [pscustomobject]$projection
}

function ConvertTo-FingerprintMap {
    param([Parameter()]$Value)

    $map = @{}
    if ($null -eq $Value) {
        return $map
    }
    foreach ($property in $Value.PSObject.Properties) {
        $map[$property.Name] = [string]$property.Value
    }
    return $map
}

function Copy-Map {
    param([Parameter(Mandatory)][hashtable]$Map)

    $copy = @{}
    foreach ($key in $Map.Keys) {
        $copy[$key] = $Map[$key]
    }
    return $copy
}

function ConvertTo-OrderedMap {
    param([Parameter(Mandatory)][hashtable]$Map)

    $ordered = [ordered]@{}
    foreach ($key in @($Map.Keys | Sort-Object)) {
        $ordered[$key] = $Map[$key]
    }
    return [pscustomobject]$ordered
}

function Assert-SafePayload {
    param(
        [Parameter()]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    if ($null -eq $Value) {
        return
    }
    if ($Value -is [byte[]]) {
        throw "Unsafe binary value detected at $Path."
    }
    if ($Value -is [string]) {
        if ($Value -match '(?i)System\.Byte\[\]|password|\bpwd\b|\btoken\b|license|serial') {
            throw "Unsafe secret or binary marker detected at $Path."
        }
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            $name = [string]$key
            if ($name -match '(?i)cabecera|contenido|blob|password|\bpwd\b|token|license|serial') {
                throw "Forbidden payload property '$name' detected at $Path."
            }
            Assert-SafePayload -Value $Value[$key] -Path "$Path.$name"
        }
        return
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $index = 0
        foreach ($item in $Value) {
            Assert-SafePayload -Value $item -Path "$Path[$index]"
            $index++
        }
        return
    }
    if ($Value -is [psobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -match '(?i)cabecera|contenido|blob|password|\bpwd\b|token|license|serial') {
                throw "Forbidden payload property '$($property.Name)' detected at $Path."
            }
            Assert-SafePayload -Value $property.Value -Path "$Path.$($property.Name)"
        }
    }
}

function Assert-ReadOnlySql {
    param(
        [Parameter(Mandatory)][string]$Sql,
        [Parameter(Mandatory)][string]$Name
    )

    $withoutComments = [regex]::Replace($Sql, '(?s)/\*.*?\*/|--[^\r\n]*', '')
    if ($withoutComments -match '(?i)\b(INSERT|UPDATE|DELETE|MERGE|ALTER|DROP|TRUNCATE|EXEC(?:UTE)?|GRANT|REVOKE|DENY)\b') {
        throw "SQL file '$Name' contains a forbidden statement."
    }
    if ($withoutComments.Trim() -notmatch '^(?i)(SELECT|WITH)\b') {
        throw "SQL file '$Name' must start with SELECT or WITH."
    }
}

function Invoke-NeptunoSelectRows {
    param(
        [Parameter(Mandatory)][string]$SafeConnectionString,
        [Parameter(Mandatory)][string]$Sql,
        [Parameter(Mandatory)][hashtable]$Parameters,
        [Parameter(Mandatory)][int]$CommandTimeoutSeconds
    )

    $connection = [System.Data.SqlClient.SqlConnection]::new($SafeConnectionString)
    try {
        $connection.Open()
        $table = Invoke-NeptunoQuery -Connection $connection -Query $Sql -Parameters $Parameters -CommandTimeout $CommandTimeoutSeconds
        return @($table.Rows)
    }
    finally {
        if ($connection.State -ne [System.Data.ConnectionState]::Closed) {
            $connection.Close()
        }
        $connection.Dispose()
    }
}

function Get-HttpStatusCode {
    param([Parameter(Mandatory)]$Exception)

    if ($null -ne $Exception.Data -and $Exception.Data.Contains("HttpStatusCode")) {
        return [int]$Exception.Data["HttpStatusCode"]
    }
    $responseProperty = $Exception.PSObject.Properties["Response"]
    if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
        $statusProperty = $responseProperty.Value.PSObject.Properties["StatusCode"]
        if ($null -ne $statusProperty -and $null -ne $statusProperty.Value) {
            return [int]$statusProperty.Value
        }
    }
    return $null
}

function Get-RetryAfterSeconds {
    param(
        [Parameter(Mandatory)]$Exception,
        [Parameter()][ValidateRange(0, 86400)][int]$DefaultSeconds = 120
    )

    if ($null -ne $Exception.Data -and $Exception.Data.Contains("RetryAfterSeconds")) {
        return [Math]::Max(0, [int]$Exception.Data["RetryAfterSeconds"])
    }

    $headerValue = $null
    $responseProperty = $Exception.PSObject.Properties["Response"]
    if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
        $headersProperty = $responseProperty.Value.PSObject.Properties["Headers"]
        if ($null -ne $headersProperty -and $null -ne $headersProperty.Value) {
            try { $headerValue = [string]$headersProperty.Value["Retry-After"] } catch { $headerValue = $null }
        }
    }
    if ([string]::IsNullOrWhiteSpace($headerValue)) {
        return $DefaultSeconds
    }

    $deltaSeconds = 0
    if ([int]::TryParse($headerValue.Trim(), [ref]$deltaSeconds)) {
        return [Math]::Max(0, $deltaSeconds)
    }
    $retryAt = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($headerValue.Trim(), [ref]$retryAt)) {
        return [Math]::Max(0, [int][Math]::Ceiling(($retryAt.ToUniversalTime() - [DateTimeOffset]::UtcNow).TotalSeconds))
    }
    return $DefaultSeconds
}

function Invoke-DeltaRequest {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$BearerToken,
        [Parameter(Mandatory)][string]$IdempotencyKey,
        [Parameter(Mandatory)]$Payload
    )

    $headers = @{
        Authorization = "Bearer $BearerToken"
        "Idempotency-Key" = $IdempotencyKey
    }
    $body = $Payload | ConvertTo-Json -Compress -Depth 30
    $response = Invoke-WebRequest -Uri $Uri -Method Post -Headers $headers -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 30 -UseBasicParsing
    $envelope = $response.Content | ConvertFrom-Json
    $okProperty = $envelope.PSObject.Properties["ok"]
    if ($null -eq $okProperty -or -not [bool]$okProperty.Value) {
        throw "Vidalinkco returned a rejected or invalid response envelope."
    }
}

function Invoke-DeltaSend {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$BearerToken,
        [Parameter(Mandatory)][string]$IdempotencyKey,
        [Parameter(Mandatory)]$Payload
    )

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-DeltaRequest -Uri $Uri -BearerToken $BearerToken -IdempotencyKey $IdempotencyKey -Payload $Payload
            return
        }
        catch {
            $statusCode = Get-HttpStatusCode -Exception $_.Exception
            $transient = $null -eq $statusCode -or $statusCode -in @(408, 429, 500, 502, 503, 504)
            if (-not $transient -or $attempt -eq 3) {
                if ($null -eq $statusCode) {
                    throw "Vidalinkco send failed after $attempt attempt(s); no response status was available."
                }
                throw "Vidalinkco send failed after $attempt attempt(s) with HTTP $statusCode."
            }
            Start-Sleep -Seconds ([Math]::Pow(2, $attempt - 1))
        }
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )

    Assert-SafePayload -Value $Value -Path '$'
    Write-Utf8NoBomLf -Path $Path -Content (($Value | ConvertTo-Json -Depth 30) + "`n")
}

function Add-NdjsonEvents {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][object[]]$Events = @()
    )

    $normalizedEvents = [System.Collections.Generic.List[object]]::new()
    foreach ($event in @($Events)) {
        if ($null -ne $event) { $normalizedEvents.Add($event) }
    }
    if ($normalizedEvents.Count -eq 0) {
        if (-not [System.IO.File]::Exists($Path)) {
            [System.IO.File]::WriteAllText($Path, "", [System.Text.UTF8Encoding]::new($false))
        }
        return
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($event in $normalizedEvents) {
        Assert-SafePayload -Value $event -Path '$.event'
        $lines.Add(($event | ConvertTo-Json -Compress -Depth 10))
    }
    [System.IO.File]::AppendAllText($Path, (($lines.ToArray() -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
}

function Write-JsonFileAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )

    Assert-SafePayload -Value $Value -Path '$'
    $parent = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporaryPath = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
    $backupPath = "$Path.bak-$([Guid]::NewGuid().ToString('N'))"
    try {
        Write-Utf8NoBomLf -Path $temporaryPath -Content (($Value | ConvertTo-Json -Depth 40) + "`n")
        if ([System.IO.File]::Exists($Path)) {
            [System.IO.File]::Replace($temporaryPath, $Path, $backupPath)
            [System.IO.File]::Delete($backupPath)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
        if ([System.IO.File]::Exists($backupPath)) {
            [System.IO.File]::Delete($backupPath)
        }
    }
}

function Get-OrCreateInitialBaselineChunkManifest {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$ParentSyncRunId,
        [Parameter(Mandatory)][int]$RequestedChunkSize,
        [Parameter(Mandatory)]$DeltaPayload
    )

    $chunksDirectory = Join-Path $RunDirectory "chunks"
    $manifestPath = Join-Path $chunksDirectory "manifest.json"
    [System.IO.Directory]::CreateDirectory($chunksDirectory) | Out-Null

    $catalogItems = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($DeltaPayload.catalogChangedItems)) {
        if ($null -ne $item) { $catalogItems.Add($item) }
    }
    $liveItems = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($DeltaPayload.liveChangedItems)) {
        if ($null -ne $item) { $liveItems.Add($item) }
    }
    $totalItems = $catalogItems.Count + $liveItems.Count
    $expectedChunkCount = if ($totalItems -eq 0) { 0 } else { [int][Math]::Ceiling($totalItems / [double]$RequestedChunkSize) }
    $deltaFingerprint = Get-StableFingerprint -Value $DeltaPayload

    if ([System.IO.File]::Exists($manifestPath)) {
        $manifest = Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8 | ConvertFrom-Json
        $manifestFingerprintProperty = $manifest.PSObject.Properties["deltaFingerprint"]
        if ([string]$manifest.parentSyncRunId -ne $ParentSyncRunId -or
            [int]$manifest.chunkSize -ne $RequestedChunkSize -or
            [int]$manifest.totalItems -ne $totalItems -or
            [int]$manifest.totalChunks -ne $expectedChunkCount -or
            $null -eq $manifestFingerprintProperty -or
            [string]$manifestFingerprintProperty.Value -ne $deltaFingerprint) {
            throw "Initial baseline chunk manifest does not match the resumed delta."
        }
        foreach ($chunk in @($manifest.chunks)) {
            if ($null -eq $chunk.PSObject.Properties["rateLimitCount"]) {
                $chunk | Add-Member -NotePropertyName rateLimitCount -NotePropertyValue 0
            }
            if ($null -eq $chunk.PSObject.Properties["lastRetryAfterSeconds"]) {
                $chunk | Add-Member -NotePropertyName lastRetryAfterSeconds -NotePropertyValue $null
            }
            $payloadPath = Join-Path $RunDirectory ([string]$chunk.payloadRelativePath)
            if (-not [System.IO.File]::Exists($payloadPath)) {
                throw "Initial baseline chunk evidence is incomplete: missing payload for chunk $($chunk.index)."
            }
        }
        return $manifest
    }

    $chunkEntries = [System.Collections.Generic.List[object]]::new()
    $catalogIndex = 0
    $liveIndex = 0
    for ($chunkIndex = 1; $chunkIndex -le $expectedChunkCount; $chunkIndex++) {
        $chunkCatalog = [System.Collections.Generic.List[object]]::new()
        $chunkLive = [System.Collections.Generic.List[object]]::new()
        while (($chunkCatalog.Count + $chunkLive.Count) -lt $RequestedChunkSize -and $catalogIndex -lt $catalogItems.Count) {
            $chunkCatalog.Add($catalogItems[$catalogIndex])
            $catalogIndex++
        }
        while (($chunkCatalog.Count + $chunkLive.Count) -lt $RequestedChunkSize -and $liveIndex -lt $liveItems.Count) {
            $chunkLive.Add($liveItems[$liveIndex])
            $liveIndex++
        }

        $chunkItemCount = $chunkCatalog.Count + $chunkLive.Count
        if ($chunkItemCount -gt 1000 -or $chunkCatalog.Count -gt 5000 -or $chunkLive.Count -gt 10000 -or $chunkItemCount -gt 10000) {
            throw "Initial baseline chunk exceeds the operational or web contract limits."
        }

        $chunkSyncRunId = "{0}-chunk-{1:D6}" -f $ParentSyncRunId, $chunkIndex
        $chunkDirectoryName = "chunk-{0:D6}" -f $chunkIndex
        $chunkDirectory = Join-Path $chunksDirectory $chunkDirectoryName
        [System.IO.Directory]::CreateDirectory($chunkDirectory) | Out-Null
        $payloadRelativePath = "chunks/$chunkDirectoryName/payload.json"
        $chunkPayload = [pscustomobject][ordered]@{
            contractVersion = [int]$DeltaPayload.contractVersion
            source = [string]$DeltaPayload.source
            sourceKey = [string]$DeltaPayload.sourceKey
            syncRunId = $chunkSyncRunId
            idempotencyKey = $chunkSyncRunId
            runType = [string]$DeltaPayload.runType
            mode = [string]$DeltaPayload.mode
            capturedAt = [string]$DeltaPayload.capturedAt
            catalogChangedItems = $chunkCatalog.ToArray()
            liveChangedItems = $chunkLive.ToArray()
            quarantinedItems = $(if ($chunkIndex -eq 1) {
                $DeltaPayload.quarantinedItems
            } else {
                [pscustomobject][ordered]@{ total = 0; negativePrice = 0; negativeStockWarnings = 0 }
            })
        }
        Write-JsonFileAtomic -Path (Join-Path $RunDirectory $payloadRelativePath) -Value $chunkPayload
        $chunkEntries.Add([pscustomobject][ordered]@{
            index = $chunkIndex
            syncRunId = $chunkSyncRunId
            idempotencyKey = $chunkSyncRunId
            catalogItems = $chunkCatalog.Count
            liveItems = $chunkLive.Count
            itemCount = $chunkItemCount
            payloadRelativePath = $payloadRelativePath
            status = "pending"
            attemptCount = 0
            rateLimitCount = 0
            lastRetryAfterSeconds = $null
            sentAt = $null
        })
    }

    $createdAt = [DateTimeOffset]::UtcNow.ToString("o")
    $manifest = [pscustomobject][ordered]@{
        version = 1
        mode = "initial-baseline"
        parentSyncRunId = $ParentSyncRunId
        chunkSize = $RequestedChunkSize
        catalogItems = $catalogItems.Count
        liveItems = $liveItems.Count
        totalItems = $totalItems
        totalChunks = $expectedChunkCount
        deltaFingerprint = $deltaFingerprint
        sentChunks = 0
        status = "pending"
        createdAt = $createdAt
        updatedAt = $createdAt
        completedAt = $null
        chunks = $chunkEntries.ToArray()
    }
    Write-JsonFileAtomic -Path $manifestPath -Value $manifest
    return $manifest
}

function Invoke-InitialBaselineChunkSend {
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$ParentSyncRunId,
        [Parameter(Mandatory)][int]$RequestedChunkSize,
        [Parameter(Mandatory)]$DeltaPayload,
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$BearerToken,
        [Parameter(Mandatory)][bool]$UseMockSend,
        [Parameter(Mandatory)][int]$DelayBetweenChunksSeconds,
        [Parameter(Mandatory)][int]$MaximumAttemptsPerChunk,
        [Parameter()][Nullable[int]]$FailAtChunk,
        [Parameter()][Nullable[int]]$RateLimitAtChunk,
        [Parameter()][Nullable[int]]$SimulatedRetryAfterSeconds
    )

    $manifestPath = Join-Path $RunDirectory "chunks/manifest.json"
    $manifest = Get-OrCreateInitialBaselineChunkManifest `
        -RunDirectory $RunDirectory `
        -ParentSyncRunId $ParentSyncRunId `
        -RequestedChunkSize $RequestedChunkSize `
        -DeltaPayload $DeltaPayload

    foreach ($chunk in @($manifest.chunks)) {
        if ([string]$chunk.status -eq "sent") {
            Write-Host "Skipping chunk $($chunk.index)/$($manifest.totalChunks); already sent."
            continue
        }

        $chunkDirectory = Split-Path -Parent (Join-Path $RunDirectory ([string]$chunk.payloadRelativePath))
        $resultPath = Join-Path $chunkDirectory "result.json"
        $chunkPayload = $null
        if (-not $UseMockSend) {
            $chunkPayload = Get-Content -Raw -LiteralPath (Join-Path $RunDirectory ([string]$chunk.payloadRelativePath)) -Encoding UTF8 | ConvertFrom-Json
        }
        $attemptInInvocation = 0
        $chunkSent = $false

        while (-not $chunkSent -and $attemptInInvocation -lt $MaximumAttemptsPerChunk) {
            $attemptInInvocation++
            $chunk.attemptCount = [int]$chunk.attemptCount + 1
            $chunk.status = "sending"
            $manifest.status = "sending"
            $manifest.updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
            Write-JsonFileAtomic -Path $manifestPath -Value $manifest
            Write-Host "Sending chunk $($chunk.index)/$($manifest.totalChunks)..."

            try {
                if ($null -ne $FailAtChunk -and [int]$FailAtChunk -eq [int]$chunk.index) {
                    $failure = [System.Exception]::new("Synthetic initial baseline chunk failure at chunk $($chunk.index).")
                    $failure.Data["HttpStatusCode"] = 400
                    throw $failure
                }
                if ($null -ne $RateLimitAtChunk -and [int]$RateLimitAtChunk -eq [int]$chunk.index -and $attemptInInvocation -eq 1) {
                    $rateLimit = [System.Exception]::new("Synthetic HTTP 429 at chunk $($chunk.index).")
                    $rateLimit.Data["HttpStatusCode"] = 429
                    if ($null -ne $SimulatedRetryAfterSeconds) {
                        $rateLimit.Data["RetryAfterSeconds"] = [int]$SimulatedRetryAfterSeconds
                    }
                    throw $rateLimit
                }
                if (-not $UseMockSend) {
                    Invoke-DeltaRequest -Uri $Uri -BearerToken $BearerToken -IdempotencyKey ([string]$chunk.idempotencyKey) -Payload $chunkPayload
                }

                $sentAt = [DateTimeOffset]::UtcNow.ToString("o")
                $chunk.status = "sent"
                $chunk.sentAt = $sentAt
                $manifest.sentChunks = @($manifest.chunks | Where-Object { [string]$_.status -eq "sent" }).Count
                $manifest.updatedAt = $sentAt
                Write-JsonFileAtomic -Path $resultPath -Value ([pscustomobject][ordered]@{
                    parentSyncRunId = $ParentSyncRunId
                    syncRunId = [string]$chunk.syncRunId
                    idempotencyKey = [string]$chunk.idempotencyKey
                    chunkIndex = [int]$chunk.index
                    attemptCount = [int]$chunk.attemptCount
                    rateLimitCount = [int]$chunk.rateLimitCount
                    status = "sent"
                    sentAt = $sentAt
                })
                Write-JsonFileAtomic -Path $manifestPath -Value $manifest
                Write-Host "Chunk $($chunk.index) sent"
                $chunkSent = $true
            }
            catch {
                $statusCode = Get-HttpStatusCode -Exception $_.Exception
                $transient = $null -eq $statusCode -or $statusCode -in @(408, 429, 500, 502, 503, 504)
                if ($transient -and $attemptInInvocation -lt $MaximumAttemptsPerChunk) {
                    $retryDelaySeconds = if ($statusCode -eq 429) {
                        Get-RetryAfterSeconds -Exception $_.Exception -DefaultSeconds 120
                    } else {
                        [Math]::Min(120, [int][Math]::Pow(2, $attemptInInvocation - 1))
                    }
                    if ($statusCode -eq 429) {
                        $chunk.rateLimitCount = [int]$chunk.rateLimitCount + 1
                        $chunk.lastRetryAfterSeconds = $retryDelaySeconds
                        Write-Host "HTTP 429 on chunk $($chunk.index); waiting $retryDelaySeconds seconds before retry..."
                    }
                    else {
                        Write-Host "Transient send failure on chunk $($chunk.index); waiting $retryDelaySeconds seconds before retry..."
                    }
                    $chunk.status = "waiting-retry"
                    $manifest.status = "waiting-retry"
                    $manifest.updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
                    Write-JsonFileAtomic -Path $resultPath -Value ([pscustomobject][ordered]@{
                        parentSyncRunId = $ParentSyncRunId
                        syncRunId = [string]$chunk.syncRunId
                        idempotencyKey = [string]$chunk.idempotencyKey
                        chunkIndex = [int]$chunk.index
                        attemptCount = [int]$chunk.attemptCount
                        status = "waiting-retry"
                        httpStatusCode = $statusCode
                        retryAfterSeconds = $retryDelaySeconds
                    })
                    Write-JsonFileAtomic -Path $manifestPath -Value $manifest
                    if ($retryDelaySeconds -gt 0) { Start-Sleep -Seconds $retryDelaySeconds }
                    continue
                }

                $failedAt = [DateTimeOffset]::UtcNow.ToString("o")
                $chunk.status = "failed"
                $manifest.status = "failed"
                $manifest.updatedAt = $failedAt
                Write-JsonFileAtomic -Path $resultPath -Value ([pscustomobject][ordered]@{
                    parentSyncRunId = $ParentSyncRunId
                    syncRunId = [string]$chunk.syncRunId
                    idempotencyKey = [string]$chunk.idempotencyKey
                    chunkIndex = [int]$chunk.index
                    attemptCount = [int]$chunk.attemptCount
                    status = "failed"
                    httpStatusCode = $statusCode
                    failedAt = $failedAt
                    failureType = $_.Exception.GetType().Name
                })
                Write-JsonFileAtomic -Path $manifestPath -Value $manifest
                throw
            }
        }

        $remainingChunks = @($manifest.chunks | Where-Object { [string]$_.status -ne "sent" }).Count
        if ($chunkSent -and $remainingChunks -gt 0 -and $DelayBetweenChunksSeconds -gt 0) {
            Write-Host "Waiting $DelayBetweenChunksSeconds seconds before next chunk..."
            Start-Sleep -Seconds $DelayBetweenChunksSeconds
        }
    }

    $manifest.sentChunks = @($manifest.chunks | Where-Object { [string]$_.status -eq "sent" }).Count
    $manifest.status = "completed"
    $manifest.completedAt = [DateTimeOffset]::UtcNow.ToString("o")
    $manifest.updatedAt = $manifest.completedAt
    Write-JsonFileAtomic -Path $manifestPath -Value $manifest
    return $manifest
}

function Write-NdjsonBatchFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][object[]]$Items = @()
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $Items) {
        Assert-SafePayload -Value $item -Path '$.batchItem'
        $lines.Add(($item | ConvertTo-Json -Compress -Depth 30))
    }
    Write-Utf8NoBomLf -Path $Path -Content $(if ($lines.Count -eq 0) { "" } else { ($lines.ToArray() -join "`n") + "`n" })
}

function Write-NdjsonArrayToWriter {
    param(
        [Parameter(Mandatory)][System.IO.StreamWriter]$Writer,
        [Parameter()][System.IO.FileInfo[]]$Files = @()
    )

    $first = $true
    foreach ($file in @($Files | Sort-Object Name)) {
        $reader = [System.IO.File]::OpenText($file.FullName)
        try {
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if ([string]::IsNullOrWhiteSpace($line)) {
                    continue
                }
                if (-not $first) { $Writer.Write(',') }
                $Writer.Write($line)
                $first = $false
            }
        }
        finally {
            $reader.Dispose()
        }
    }
}

function Write-EnvelopeFromNdjson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Header,
        [Parameter(Mandatory)][string]$ItemsProperty,
        [Parameter()][System.IO.FileInfo[]]$Files = @()
    )

    Assert-SafePayload -Value $Header -Path '$.header'
    $headerJson = $Header | ConvertTo-Json -Compress -Depth 20
    $writer = [System.IO.StreamWriter]::new($Path, $false, [System.Text.UTF8Encoding]::new($false))
    $writer.NewLine = "`n"
    try {
        $writer.Write($headerJson.Substring(0, $headerJson.Length - 1))
        $writer.Write(',"' + $ItemsProperty + '":[')
        Write-NdjsonArrayToWriter -Writer $writer -Files $Files
        $writer.Write("]}`n")
    }
    finally {
        $writer.Dispose()
    }
}

function Write-DeltaFromNdjson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Header,
        [Parameter()][System.IO.FileInfo[]]$CatalogFiles = @(),
        [Parameter()][System.IO.FileInfo[]]$LiveFiles = @()
    )

    Assert-SafePayload -Value $Header -Path '$.deltaHeader'
    $headerJson = $Header | ConvertTo-Json -Compress -Depth 20
    $writer = [System.IO.StreamWriter]::new($Path, $false, [System.Text.UTF8Encoding]::new($false))
    $writer.NewLine = "`n"
    try {
        $writer.Write($headerJson.Substring(0, $headerJson.Length - 1))
        $writer.Write(',"catalogChangedItems":[')
        Write-NdjsonArrayToWriter -Writer $writer -Files $CatalogFiles
        $writer.Write('],"liveChangedItems":[')
        Write-NdjsonArrayToWriter -Writer $writer -Files $LiveFiles
        $writer.Write("]}`n")
    }
    finally {
        $writer.Dispose()
    }
}

function Merge-NdjsonFiles {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][System.IO.FileInfo[]]$Files = @(),
        [Parameter()][object[]]$TrailingEvents = @()
    )

    $writer = [System.IO.StreamWriter]::new($Path, $false, [System.Text.UTF8Encoding]::new($false))
    $writer.NewLine = "`n"
    try {
        foreach ($file in @($Files | Sort-Object Name)) {
            $reader = [System.IO.File]::OpenText($file.FullName)
            try {
                while (-not $reader.EndOfStream) {
                    $line = $reader.ReadLine()
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        $writer.WriteLine($line)
                    }
                }
            }
            finally {
                $reader.Dispose()
            }
        }
        foreach ($event in $TrailingEvents) {
            Assert-SafePayload -Value $event -Path '$.trailingEvent'
            $writer.WriteLine(($event | ConvertTo-Json -Compress -Depth 10))
        }
    }
    finally {
        $writer.Dispose()
    }
}

function Get-CompatibleIncompleteRun {
    param(
        [Parameter(Mandatory)][string]$RunsDirectory,
        [Parameter(Mandatory)][string]$SourceKey,
        [Parameter(Mandatory)][string]$RunType,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Eligibility,
        [Parameter(Mandatory)][long]$BodegaId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExternalIdsKey,
        [Parameter(Mandatory)][bool]$SendRequested,
        [Parameter(Mandatory)][bool]$InitialBaselineRequested
    )

    if (-not [System.IO.Directory]::Exists($RunsDirectory)) {
        return $null
    }
    foreach ($run in @(Get-ChildItem -LiteralPath $RunsDirectory -Directory | Sort-Object Name -Descending)) {
        $checkpointPath = Join-Path $run.FullName "checkpoint.json"
        if (-not [System.IO.File]::Exists($checkpointPath)) { continue }
        $checkpoint = Get-Content -Raw -LiteralPath $checkpointPath -Encoding UTF8 | ConvertFrom-Json
        if ($checkpoint.status -notin @("running", "interrupted", "failed")) { continue }
        $checkpointInitialBaselineProperty = $checkpoint.PSObject.Properties["initialBaseline"]
        $checkpointInitialBaseline = $null -ne $checkpointInitialBaselineProperty -and [bool]$checkpointInitialBaselineProperty.Value
        if ([string]$checkpoint.sourceKey -eq $SourceKey -and
            [string]$checkpoint.runType -eq $RunType -and
            [string]$checkpoint.mode -eq $Mode -and
            [string]$checkpoint.eligibility -eq $Eligibility -and
            [long]$checkpoint.bodegaId -eq $BodegaId -and
            [string]$checkpoint.externalIdsKey -eq $ExternalIdsKey -and
            [bool]$checkpoint.sendRequested -eq $SendRequested -and
            $checkpointInitialBaseline -eq $InitialBaselineRequested) {
            return [pscustomobject]@{ Directory = $run.FullName; Checkpoint = $checkpoint }
        }
    }
    return $null
}

function Invoke-RunRetention {
    param(
        [Parameter(Mandatory)][string]$RunsDirectory,
        [Parameter(Mandatory)][int]$Keep
    )

    if (-not [System.IO.Directory]::Exists($RunsDirectory)) {
        return
    }
    $runs = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()
    foreach ($run in @(Get-ChildItem -LiteralPath $RunsDirectory -Directory -Force | Sort-Object Name -Descending)) {
        $checkpointPath = Join-Path $run.FullName "checkpoint.json"
        if (-not [System.IO.File]::Exists($checkpointPath)) { continue }
        $checkpoint = Get-Content -Raw -LiteralPath $checkpointPath -Encoding UTF8 | ConvertFrom-Json
        if ($checkpoint.status -in @("completed", "failed")) {
            $runs.Add($run)
        }
    }
    $resolvedRunsDirectory = [System.IO.Path]::GetFullPath($RunsDirectory).TrimEnd('\', '/')
    $runsPrefix = $resolvedRunsDirectory + [System.IO.Path]::DirectorySeparatorChar
    foreach ($run in @($runs.ToArray() | Select-Object -Skip $Keep)) {
        $resolvedRun = [System.IO.Path]::GetFullPath($run.FullName)
        if (-not $resolvedRun.StartsWith($runsPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals((Split-Path -Parent $resolvedRun), $resolvedRunsDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Retention refused a path outside the direct runs directory."
        }
        if (($run.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Retention refused a reparse-point run directory."
        }
        Remove-Item -LiteralPath $resolvedRun -Recurse -Force
    }
}

if ([string]::IsNullOrWhiteSpace($SourceKey)) {
    throw "SourceKey is required."
}
if ($Send -and $DryRun) {
    throw "Use either -Send or -DryRun, not both."
}
if ($InitialBaseline -and -not $Send) {
    throw "InitialBaseline requires -Send."
}
if ($InitialBaseline -and $RunType -ne "Incremental") {
    throw "InitialBaseline requires RunType Incremental."
}
if ($InitialBaseline -and (
    $PSBoundParameters.ContainsKey("MaxProducts") -or
    $PSBoundParameters.ContainsKey("StartAfterExternalId") -or
    $PSBoundParameters.ContainsKey("MaxBatches") -or
    $PSBoundParameters.ContainsKey("ExternalIds")
)) {
    throw "InitialBaseline requires the complete unfiltered dataset. MaxProducts, StartAfterExternalId, MaxBatches and ExternalIds are not allowed."
}
if ($RunType -eq "Audit" -and $Send) {
    throw "RunType Audit never sends data."
}
if ($RunType -eq "Incremental" -and $RebuildState) {
    throw "RebuildState is not valid for Incremental. Use RunType Bootstrap to rebuild the baseline."
}
if ($MockSendSuccess -and -not $Send) {
    throw "MockSendSuccess is a smoke-only option and requires -Send."
}
if ($null -ne $MockChunkFailureAt -and (-not $InitialBaseline -or -not $MockSendSuccess)) {
    throw "MockChunkFailureAt is a smoke-only option and requires InitialBaseline with MockSendSuccess."
}
if ($null -ne $MockChunkRateLimitAt -and (-not $InitialBaseline -or -not $MockSendSuccess)) {
    throw "MockChunkRateLimitAt is a smoke-only option and requires InitialBaseline with MockSendSuccess."
}
if ($null -ne $MockRetryAfterSeconds -and $null -eq $MockChunkRateLimitAt) {
    throw "MockRetryAfterSeconds requires MockChunkRateLimitAt."
}
if ($PSBoundParameters.ContainsKey("RetentionRuns") -and -not $PSBoundParameters.ContainsKey("MinimumSuccessfulRunsToKeep")) {
    $MinimumSuccessfulRunsToKeep = $RetentionRuns
}
$effectiveDryRun = -not $Send
$effectiveApiUrl = if ([string]::IsNullOrWhiteSpace($ApiUrl)) { $env:VIDALINKCO_NEPTUNO_SYNC_URL } else { $ApiUrl }
$effectiveApiToken = if ([string]::IsNullOrWhiteSpace($ApiToken)) { $env:VIDALINKCO_NEPTUNO_SYNC_TOKEN } else { $ApiToken }
if ($Send) {
    if ([string]::IsNullOrWhiteSpace($effectiveApiUrl)) {
        throw "ApiUrl or VIDALINKCO_NEPTUNO_SYNC_URL is required with -Send."
    }
    if ([string]::IsNullOrWhiteSpace($effectiveApiToken)) {
        throw "ApiToken or VIDALINKCO_NEPTUNO_SYNC_TOKEN is required with -Send."
    }
    $parsedApiUri = $null
    if (-not [uri]::TryCreate($effectiveApiUrl, [System.UriKind]::Absolute, [ref]$parsedApiUri) -or $parsedApiUri.Scheme -ne "https") {
        throw "ApiUrl must be an absolute HTTPS URL."
    }
}

$resolvedOutputDirectory = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($OutputDirectory))
$stateDirectory = Join-Path $resolvedOutputDirectory "state"
$statePath = Join-Path $stateDirectory "fingerprints.json"
$cursorPath = Join-Path $stateDirectory "cursors.json"
$runsDirectory = Join-Path $resolvedOutputDirectory "runs"
$latestDirectory = Join-Path $resolvedOutputDirectory "latest"
$capturedAt = [DateTimeOffset]::UtcNow.ToString("o")
$normalizedExternalIdList = [System.Collections.Generic.List[string]]::new()
foreach ($normalizedExternalId in @(Get-NormalizedExternalIds -Values $ExternalIds)) {
    if ($null -ne $normalizedExternalId) {
        $normalizedExternalIdList.Add([string]$normalizedExternalId)
    }
}
if ($normalizedExternalIdList.Count -eq 0) {
    $normalizedExternalIds = $null
}
else {
    $normalizedExternalIds = $normalizedExternalIdList.ToArray()
}
$externalIdsFilterApplied = $null -ne $normalizedExternalIds
$externalIdsKey = if ($externalIdsFilterApplied) { @($normalizedExternalIds) -join "," } else { "" }
[System.IO.Directory]::CreateDirectory($resolvedOutputDirectory) | Out-Null
[System.IO.Directory]::CreateDirectory($stateDirectory) | Out-Null
[System.IO.Directory]::CreateDirectory($runsDirectory) | Out-Null
[System.IO.Directory]::CreateDirectory($latestDirectory) | Out-Null

function Invoke-NeptunoSyncRetentionSafely {
    if (-not $RetentionEnabled) {
        return
    }

    try {
        $plan = New-NeptunoSyncCleanupPlan `
            -OutputDirectory $resolvedOutputDirectory `
            -SuccessfulRunRetentionDays $SuccessfulRunRetentionDays `
            -FailedRunRetentionDays $FailedRunRetentionDays `
            -MinimumSuccessfulRunsToKeep $MinimumSuccessfulRunsToKeep `
            -MinimumFailedRunsToKeep $MinimumFailedRunsToKeep `
            -PreserveFullPayloads ([bool]$PreserveFullPayloads) `
            -PreserveFailedPayloads $PreserveFailedPayloads `
            -IncludeHistoricalTestDirectories $false
        $result = Invoke-NeptunoSyncCleanupPlan -Plan $plan -Apply:(!$CleanupDryRun)
        if (@($result.errors).Count -gt 0) {
            Write-Warning "Retention cleanup completed with errors: $($result.errors -join '; ')"
        }
        elseif ($CleanupDryRun) {
            Write-Host "Retention cleanup preview: $($plan.totals.candidateFiles) file(s), $($plan.totals.candidateBytes) byte(s) eligible."
        }
        else {
            Write-Host "Retention cleanup applied: $($result.deletedFiles) file(s), $($result.deletedBytes) byte(s) freed."
        }
    }
    catch {
        Write-Warning "Retention cleanup failed but sync result is preserved: $($_.Exception.Message)"
    }
}

$resumeRun = $null
if ($InitialBaseline -and -not $Resume) {
    $existingBaselineRun = Get-CompatibleIncompleteRun `
        -RunsDirectory $runsDirectory `
        -SourceKey $SourceKey.Trim() `
        -RunType $RunType `
        -Mode $Mode `
        -Eligibility $Eligibility `
        -BodegaId $BodegaId `
        -ExternalIdsKey $externalIdsKey `
        -SendRequested $true `
        -InitialBaselineRequested $true
    if ($null -ne $existingBaselineRun) {
        throw "An incomplete InitialBaseline already exists. Resume it with InitialBaseline and Resume before starting another baseline."
    }
}
if ($Resume) {
    $resumeRun = Get-CompatibleIncompleteRun `
        -RunsDirectory $runsDirectory `
        -SourceKey $SourceKey.Trim() `
        -RunType $RunType `
        -Mode $Mode `
        -Eligibility $Eligibility `
        -BodegaId $BodegaId `
        -ExternalIdsKey $externalIdsKey `
        -SendRequested ([bool]$Send) `
        -InitialBaselineRequested ([bool]$InitialBaseline)
    if ($null -eq $resumeRun) {
        throw "Resume did not find a compatible incomplete run."
    }
    $runDirectory = $resumeRun.Directory
    $syncRunId = Split-Path -Leaf $runDirectory
    $capturedAt = [string]$resumeRun.Checkpoint.startedAt
    $BatchSize = [int]$resumeRun.Checkpoint.batchSize
    $savedChunkSizeProperty = $resumeRun.Checkpoint.PSObject.Properties["chunkSize"]
    if ($null -ne $savedChunkSizeProperty) {
        $ChunkSize = [int]$savedChunkSizeProperty.Value
    }
    $StartAfterExternalId = [long]$resumeRun.Checkpoint.initialStartAfterExternalId
    $savedMaxProducts = $resumeRun.Checkpoint.PSObject.Properties["maxProducts"]
    if ($null -ne $savedMaxProducts -and $null -ne $savedMaxProducts.Value) {
        $MaxProducts = [Nullable[int]]([int]$savedMaxProducts.Value)
    }
}
else {
    $syncRunId = "neptuno-" + [DateTimeOffset]::UtcNow.ToString("yyyyMMddTHHmmssfffZ") + "-" + ([Guid]::NewGuid().ToString("N").Substring(0, 8))
    $runDirectory = Join-Path $runsDirectory $syncRunId
}
if ($RunType -eq "Incremental") {
    if (-not [System.IO.File]::Exists($statePath)) {
        throw "RunType Incremental requires fingerprint state. Run Bootstrap first for this OutputDirectory."
    }
    $preflightState = Get-Content -Raw -LiteralPath $statePath -Encoding UTF8 | ConvertFrom-Json
    if (-not [string]::Equals([string]$preflightState.sourceKey, $SourceKey.Trim(), [System.StringComparison]::Ordinal)) {
        throw "RunType Incremental found fingerprint state for a different SourceKey. Use the matching OutputDirectory or run Bootstrap deliberately."
    }
}
$effectiveMaxProducts = if ($null -eq $MaxProducts) { [int]::MaxValue } else { [int]$MaxProducts }
$catalogEnabled = $Mode -in @("Catalog", "All")
$liveEnabled = $Mode -in @("Live", "All")

$fixture = $null
$safeConnectionString = $null
$catalogSql = $null
$liveSql = $null
if (-not [string]::IsNullOrWhiteSpace($FixturePath)) {
    $resolvedFixturePath = [System.IO.Path]::GetFullPath($FixturePath)
    if (-not [System.IO.File]::Exists($resolvedFixturePath)) {
        throw "FixturePath does not exist."
    }
    $fixture = Get-Content -Raw -LiteralPath $resolvedFixturePath -Encoding UTF8 | ConvertFrom-Json
}
else {
    $catalogSqlPath = Join-Path $repoRoot "docs/sql/neptuno-sync-catalog-query.sql"
    $liveSqlPath = Join-Path $repoRoot "docs/sql/neptuno-sync-live-query.sql"
    $catalogSql = Get-Content -Raw -LiteralPath $catalogSqlPath -Encoding UTF8
    $liveSql = Get-Content -Raw -LiteralPath $liveSqlPath -Encoding UTF8
    Assert-ReadOnlySql -Sql $catalogSql -Name "neptuno-sync-catalog-query.sql"
    Assert-ReadOnlySql -Sql $liveSql -Name "neptuno-sync-live-query.sql"

    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new($ConnectionString)
    $builder.ApplicationIntent = [System.Data.SqlClient.ApplicationIntent]::ReadOnly
    $safeConnectionString = $builder.ConnectionString
}

$previousCatalog = @{}
$previousLive = @{}
$previousSentCatalog = @{}
$previousSentLive = @{}
$hasCompatibleState = $false
if (-not $RebuildState -and [System.IO.File]::Exists($statePath)) {
    $previousState = Get-Content -Raw -LiteralPath $statePath -Encoding UTF8 | ConvertFrom-Json
    if ([string]::Equals([string]$previousState.sourceKey, $SourceKey.Trim(), [System.StringComparison]::Ordinal)) {
        $hasCompatibleState = $true
        $previousCatalog = ConvertTo-FingerprintMap -Value $previousState.catalog
        $previousLive = ConvertTo-FingerprintMap -Value $previousState.live
        $sentCatalogProperty = $previousState.PSObject.Properties["sentCatalog"]
        $sentLiveProperty = $previousState.PSObject.Properties["sentLive"]
        if ($null -ne $sentCatalogProperty) {
            $previousSentCatalog = ConvertTo-FingerprintMap -Value $sentCatalogProperty.Value
        }
        if ($null -ne $sentLiveProperty) {
            $previousSentLive = ConvertTo-FingerprintMap -Value $sentLiveProperty.Value
        }
    }
}
if ($RunType -eq "Incremental" -and -not $hasCompatibleState) {
    throw "RunType Incremental requires compatible fingerprint state. Run Bootstrap first for this OutputDirectory and SourceKey."
}

$previousLastCatalogSyncAt = $null
$previousLastLiveSyncAt = $null
$previousLastSuccessfulSendAt = $null
if ([System.IO.File]::Exists($cursorPath)) {
    $previousCursors = Get-Content -Raw -LiteralPath $cursorPath -Encoding UTF8 | ConvertFrom-Json
    if ([string]::Equals([string]$previousCursors.sourceKey, $SourceKey.Trim(), [System.StringComparison]::Ordinal)) {
        foreach ($cursorName in @("lastCatalogSyncAt", "lastLiveSyncAt", "lastSuccessfulSendAt")) {
            $property = $previousCursors.PSObject.Properties[$cursorName]
            if ($null -ne $property) {
                Set-Variable -Name ("previous" + $cursorName.Substring(0, 1).ToUpperInvariant() + $cursorName.Substring(1)) -Value $property.Value
            }
        }
    }
}

$limitedRun = $null -ne $MaxProducts -or $externalIdsFilterApplied
$baselineReset = $RebuildState -or $RunType -eq "Bootstrap"
$nextCatalog = if ($catalogEnabled -and ($baselineReset -or -not $limitedRun)) { @{} } else { Copy-Map -Map $previousCatalog }
$nextLive = if ($liveEnabled -and ($baselineReset -or -not $limitedRun)) { @{} } else { Copy-Map -Map $previousLive }
$nextSentCatalog = if ($catalogEnabled -and ($baselineReset -or ($Send -and -not $limitedRun))) { @{} } else { Copy-Map -Map $previousSentCatalog }
$nextSentLive = if ($liveEnabled -and ($baselineReset -or ($Send -and -not $limitedRun))) { @{} } else { Copy-Map -Map $previousSentLive }
$catalogComparison = if ($Send) { $previousSentCatalog } else { $previousCatalog }
$liveComparison = if ($Send) { $previousSentLive } else { $previousLive }
$emitFullPayloads = $RunType -in @("Bootstrap", "Audit")
$workDirectory = Join-Path $runDirectory "work"
$batchWorkDirectory = Join-Path $workDirectory "batches"
$progressWorkDirectory = Join-Path $workDirectory "progress"
$progressStatePath = Join-Path $workDirectory "progress-state.json"
$checkpointPath = Join-Path $runDirectory "checkpoint.json"
[System.IO.Directory]::CreateDirectory($runDirectory) | Out-Null
[System.IO.Directory]::CreateDirectory($batchWorkDirectory) | Out-Null

$initialStartAfter = if ($null -eq $StartAfterExternalId) { 0L } else { [long]$StartAfterExternalId }
$catalogLastExternalId = $initialStartAfter
$liveLastExternalId = $initialStartAfter
$catalogComplete = -not $catalogEnabled
$liveComplete = -not $liveEnabled
$batchesCompleted = 0
$catalogItemsSeen = 0
$liveItemsSeen = 0
$liveEligibleSeen = 0
$catalogChangedSeen = 0
$liveChangedSeen = 0
$quarantinedSeen = 0
$warningsSeen = 0
$negativePriceSeen = 0
$negativeStockSeen = 0
$runStartedAt = $capturedAt

if ($Resume) {
    $checkpoint = $resumeRun.Checkpoint
    $catalogLastExternalId = [long]$checkpoint.catalogLastExternalId
    $liveLastExternalId = [long]$checkpoint.liveLastExternalId
    $catalogComplete = [bool]$checkpoint.catalogComplete
    $liveComplete = [bool]$checkpoint.liveComplete
    $batchesCompleted = [int]$checkpoint.batchesCompleted
    $catalogItemsSeen = [int]$checkpoint.catalogItemsSeen
    $liveItemsSeen = [int]$checkpoint.liveItemsSeen
    $liveEligibleSeen = [int]$checkpoint.liveEligibleSeen
    $catalogChangedSeen = [int]$checkpoint.catalogChangedSeen
    $liveChangedSeen = [int]$checkpoint.liveChangedSeen
    $quarantinedSeen = [int]$checkpoint.quarantinedSeen
    $warningsSeen = [int]$checkpoint.warningsSeen
    $negativePriceSeen = [int]$checkpoint.negativePriceSeen
    $negativeStockSeen = [int]$checkpoint.negativeStockSeen
    $runStartedAt = [string]$checkpoint.startedAt
    if ($batchesCompleted -gt 0) {
        $progressPath = $progressStatePath
        if (-not [System.IO.File]::Exists($progressPath)) {
            $progressPath = Join-Path $progressWorkDirectory ("{0:D8}.json" -f $batchesCompleted)
        }
        if (-not [System.IO.File]::Exists($progressPath)) {
            throw "Resume checkpoint has no matching progress state."
        }
        $progress = Get-Content -Raw -LiteralPath $progressPath -Encoding UTF8 | ConvertFrom-Json
        $nextCatalog = ConvertTo-FingerprintMap -Value $progress.catalog
        $nextLive = ConvertTo-FingerprintMap -Value $progress.live
        $nextSentCatalog = ConvertTo-FingerprintMap -Value $progress.sentCatalog
        $nextSentLive = ConvertTo-FingerprintMap -Value $progress.sentLive
    }
}

$checkpoint = [pscustomobject][ordered]@{
    version = 2
    sourceKey = $SourceKey.Trim()
    syncRunId = $syncRunId
    runType = $RunType
    mode = $Mode
    eligibility = $Eligibility
    bodegaId = $BodegaId
    externalIdsKey = $externalIdsKey
    sendRequested = [bool]$Send
    initialBaseline = [bool]$InitialBaseline
    chunkSize = $ChunkSize
    chunkDelaySeconds = $ChunkDelaySeconds
    maxChunkAttempts = $MaxChunkAttempts
    batchSize = $BatchSize
    maxProducts = $(if ($null -eq $MaxProducts) { $null } else { [int]$MaxProducts })
    commandTimeoutSeconds = $CommandTimeoutSeconds
    initialStartAfterExternalId = $initialStartAfter
    catalogLastExternalId = $catalogLastExternalId
    liveLastExternalId = $liveLastExternalId
    lastProcessedExternalId = [Math]::Max($catalogLastExternalId, $liveLastExternalId)
    batchesCompleted = $batchesCompleted
    catalogItemsSeen = $catalogItemsSeen
    liveItemsSeen = $liveItemsSeen
    liveEligibleSeen = $liveEligibleSeen
    catalogChangedSeen = $catalogChangedSeen
    liveChangedSeen = $liveChangedSeen
    quarantinedSeen = $quarantinedSeen
    warningsSeen = $warningsSeen
    negativePriceSeen = $negativePriceSeen
    negativeStockSeen = $negativeStockSeen
    counts = [pscustomobject][ordered]@{
        catalogRowsSeen = $catalogItemsSeen
        liveRowsSeen = $liveItemsSeen
        liveEligibleSeen = $liveEligibleSeen
        catalogChanged = $catalogChangedSeen
        liveChanged = $liveChangedSeen
        quarantined = $quarantinedSeen
        warnings = $warningsSeen
    }
    catalogComplete = $catalogComplete
    liveComplete = $liveComplete
    status = "running"
    startedAt = $runStartedAt
    updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
}
Write-JsonFileAtomic -Path $checkpointPath -Value $checkpoint

$runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$invocationBatches = 0
$controlledInterruption = $false
$runFailure = $null

try {
    while (-not ($catalogComplete -and $liveComplete)) {
        if ($null -ne $MaxBatches -and $invocationBatches -ge [int]$MaxBatches) {
            $controlledInterruption = $true
            break
        }
        $batchNumber = $batchesCompleted + 1
        $invocationBatches++
        if ($null -ne $MockTimeoutAtBatch -and $invocationBatches -eq [int]$MockTimeoutAtBatch) {
            throw [TimeoutException]::new("Mock SQL batch exceeded CommandTimeoutSeconds=$CommandTimeoutSeconds.")
        }

        [object[]]$catalogRows = @()
        [object[]]$liveRows = @()
        $catalogTake = [Math]::Min($BatchSize, $effectiveMaxProducts - $catalogItemsSeen)
        $liveTake = [Math]::Min($BatchSize, $effectiveMaxProducts - $liveItemsSeen)
        if ($catalogEnabled -and -not $catalogComplete) {
            if ($catalogTake -le 0) {
                $catalogComplete = $true
            }
            elseif ($null -ne $fixture) {
                $catalogRows = @($fixture.catalogRows | Where-Object {
                    [long]$_.externalId -gt $catalogLastExternalId -and
                    (-not $externalIdsFilterApplied -or $normalizedExternalIds -contains ([string]$_.externalId).Trim())
                } | Sort-Object { [long]$_.externalId } | Select-Object -First $catalogTake)
            }
            else {
                $catalogQuery = Add-ExternalIdsSqlFilter -Sql $catalogSql -Parameters @{
                    BatchSize = $catalogTake
                    StartAfterExternalId = $catalogLastExternalId
                } -Ids $normalizedExternalIds
                Assert-ReadOnlySql -Sql $catalogQuery.Sql -Name "neptuno-sync-catalog-query.sql (runtime)"
                $catalogRows = @(Invoke-NeptunoSelectRows -SafeConnectionString $safeConnectionString -Sql $catalogQuery.Sql -Parameters $catalogQuery.Parameters -CommandTimeoutSeconds $CommandTimeoutSeconds)
            }
        }
        if ($liveEnabled -and -not $liveComplete) {
            if ($liveTake -le 0) {
                $liveComplete = $true
            }
            elseif ($null -ne $fixture) {
                $liveRows = @($fixture.liveRows | Where-Object {
                    [long]$_.externalId -gt $liveLastExternalId -and
                    [long]$_.bodegaExternalId -eq $BodegaId -and
                    (-not $externalIdsFilterApplied -or $normalizedExternalIds -contains ([string]$_.externalId).Trim())
                } | Sort-Object { [long]$_.externalId } | Select-Object -First $liveTake)
            }
            else {
                $liveQuery = Add-ExternalIdsSqlFilter -Sql $liveSql -Parameters @{
                    BodegaId = $BodegaId
                    BatchSize = $liveTake
                    StartAfterExternalId = $liveLastExternalId
                } -Ids $normalizedExternalIds
                Assert-ReadOnlySql -Sql $liveQuery.Sql -Name "neptuno-sync-live-query.sql (runtime)"
                $liveRows = @(Invoke-NeptunoSelectRows -SafeConnectionString $safeConnectionString -Sql $liveQuery.Sql -Parameters $liveQuery.Parameters -CommandTimeoutSeconds $CommandTimeoutSeconds)
            }
        }

        # PowerShell 5.1 unwraps single pipeline results. Keep both branches as
        # arrays before Count, iteration and cumulative accounting.
        [object[]]$catalogRows = @($catalogRows)
        [object[]]$liveRows = @($liveRows)
        $catalogRowCount = $catalogRows.Count
        $liveRowCount = $liveRows.Count

        $batchCatalogPayload = [System.Collections.Generic.List[object]]::new()
        $batchCatalogChanged = [System.Collections.Generic.List[object]]::new()
        $batchLivePayload = [System.Collections.Generic.List[object]]::new()
        $batchLiveChanged = [System.Collections.Generic.List[object]]::new()
        $batchQuarantine = [System.Collections.Generic.List[object]]::new()
        $batchWarnings = [System.Collections.Generic.List[object]]::new()
        $batchEvents = [System.Collections.Generic.List[object]]::new()
        $batchQuarantineKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $batchNegativePriceKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $batchNegativeStockKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $batchLiveEligibleCount = 0
        $failFastViolation = $false

        foreach ($row in @($catalogRows)) {
            $item = New-CatalogItem -Row $row -ItemSourceKey $SourceKey
            $hash = Get-StableFingerprint -Value (Get-CatalogFingerprintProjection -Item $item)
            $changed = -not $catalogComparison.ContainsKey($item.externalId) -or $catalogComparison[$item.externalId] -ne $hash -or $baselineReset
            if ($emitFullPayloads -or $changed) { $batchCatalogPayload.Add($item) }
            if ($changed) { $batchCatalogChanged.Add($item) }
            $nextCatalog[$item.externalId] = $hash
            if ($Send) { $nextSentCatalog[$item.externalId] = $hash }
        }

        foreach ($row in @($liveRows)) {
            $evaluation = Get-LiveItemEvaluation -Row $row -ItemSourceKey $SourceKey -CapturedAt $capturedAt -EligibilityPolicy $Eligibility
            $itemKey = "$($evaluation.item.externalId)|$($evaluation.item.bodegaExternalId)"
            if ($evaluation.negativeStock) {
                [void]$batchQuarantineKeys.Add($itemKey)
                [void]$batchNegativeStockKeys.Add($itemKey)
                $batchQuarantine.Add([pscustomobject][ordered]@{
                    externalId = $evaluation.item.externalId
                    bodegaExternalId = $evaluation.item.bodegaExternalId
                    severity = "warning"
                    blocking = $false
                    reason = "NEGATIVE_STOCK_CLAMPED"
                    sourceStockUnidad = $evaluation.sourceStockUnidad
                    sourceStockFraccion = $evaluation.sourceStockFraccion
                    normalizedStockUnidad = $evaluation.item.stockUnidad
                    normalizedStockFraccion = $evaluation.item.stockFraccion
                })
                $warningEvent = [pscustomobject][ordered]@{
                    eventType = "live-stock-normalized"
                    syncRunId = $syncRunId
                    occurredAt = [DateTimeOffset]::UtcNow.ToString("o")
                    externalId = $evaluation.item.externalId
                    bodegaExternalId = $evaluation.item.bodegaExternalId
                    reason = "NEGATIVE_STOCK_CLAMPED"
                }
                $batchWarnings.Add($warningEvent)
                $batchEvents.Add($warningEvent)
            }
            if ($evaluation.negativePrice) {
                [void]$batchQuarantineKeys.Add($itemKey)
                [void]$batchNegativePriceKeys.Add($itemKey)
                $batchQuarantine.Add([pscustomobject][ordered]@{
                    externalId = $evaluation.item.externalId
                    bodegaExternalId = $evaluation.item.bodegaExternalId
                    severity = "error"
                    blocking = $true
                    reason = "NEGATIVE_PRICE"
                    sourcePrecioActual = $evaluation.sourcePrice
                })
                $batchEvents.Add([pscustomobject][ordered]@{
                    eventType = "live-item-quarantined"
                    syncRunId = $syncRunId
                    occurredAt = [DateTimeOffset]::UtcNow.ToString("o")
                    externalId = $evaluation.item.externalId
                    bodegaExternalId = $evaluation.item.bodegaExternalId
                    reason = "NEGATIVE_PRICE"
                })
                if ($OnInvalidLive -eq "FailFast") { $failFastViolation = $true }
                continue
            }
            if ($evaluation.eligible) {
                $batchLiveEligibleCount++
                $hash = Get-StableFingerprint -Value (Get-LiveFingerprintProjection -Item $evaluation.item)
                $changed = -not $liveComparison.ContainsKey($itemKey) -or $liveComparison[$itemKey] -ne $hash -or $baselineReset
                if ($emitFullPayloads -or $changed) { $batchLivePayload.Add($evaluation.item) }
                if ($changed) { $batchLiveChanged.Add($evaluation.item) }
                $nextLive[$itemKey] = $hash
                if ($Send) { $nextSentLive[$itemKey] = $hash }
            }
        }

        $batchPrefix = "{0:D8}" -f $batchNumber
        Write-NdjsonBatchFile -Path (Join-Path $batchWorkDirectory "$batchPrefix.catalog-payload.ndjson") -Items $batchCatalogPayload.ToArray()
        Write-NdjsonBatchFile -Path (Join-Path $batchWorkDirectory "$batchPrefix.catalog-changed.ndjson") -Items $batchCatalogChanged.ToArray()
        Write-NdjsonBatchFile -Path (Join-Path $batchWorkDirectory "$batchPrefix.live-payload.ndjson") -Items $batchLivePayload.ToArray()
        Write-NdjsonBatchFile -Path (Join-Path $batchWorkDirectory "$batchPrefix.live-changed.ndjson") -Items $batchLiveChanged.ToArray()
        Write-NdjsonBatchFile -Path (Join-Path $batchWorkDirectory "$batchPrefix.quarantine.ndjson") -Items $batchQuarantine.ToArray()
        Write-NdjsonBatchFile -Path (Join-Path $batchWorkDirectory "$batchPrefix.events.ndjson") -Items $batchEvents.ToArray()
        Write-NdjsonBatchFile -Path (Join-Path $batchWorkDirectory "$batchPrefix.warnings.ndjson") -Items $batchWarnings.ToArray()

        $catalogItemsSeen += $catalogRowCount
        $liveItemsSeen += $liveRowCount
        $liveEligibleSeen += $batchLiveEligibleCount
        $catalogChangedSeen += $batchCatalogChanged.Count
        $liveChangedSeen += $batchLiveChanged.Count
        $quarantinedSeen += $batchQuarantineKeys.Count
        $warningsSeen += $batchWarnings.Count
        $negativePriceSeen += $batchNegativePriceKeys.Count
        $negativeStockSeen += $batchNegativeStockKeys.Count
        if ($catalogRowCount -gt 0) {
            $catalogLastExternalId = [long](($catalogRows | ForEach-Object { [long](Get-RowValue -Row $_ -Name "externalId") } | Measure-Object -Maximum).Maximum)
        }
        if ($liveRowCount -gt 0) {
            $liveLastExternalId = [long](($liveRows | ForEach-Object { [long](Get-RowValue -Row $_ -Name "externalId") } | Measure-Object -Maximum).Maximum)
        }
        if ($catalogEnabled -and ($catalogRowCount -lt $catalogTake -or $catalogItemsSeen -ge $effectiveMaxProducts)) { $catalogComplete = $true }
        if ($liveEnabled -and ($liveRowCount -lt $liveTake -or $liveItemsSeen -ge $effectiveMaxProducts)) { $liveComplete = $true }
        $batchesCompleted = $batchNumber

        $progressState = [pscustomobject][ordered]@{
            catalog = ConvertTo-OrderedMap -Map $nextCatalog
            live = ConvertTo-OrderedMap -Map $nextLive
            sentCatalog = ConvertTo-OrderedMap -Map $nextSentCatalog
            sentLive = ConvertTo-OrderedMap -Map $nextSentLive
        }
        Write-JsonFileAtomic -Path $progressStatePath -Value $progressState

        $checkpoint.catalogLastExternalId = $catalogLastExternalId
        $checkpoint.liveLastExternalId = $liveLastExternalId
        $checkpoint.lastProcessedExternalId = [Math]::Max($catalogLastExternalId, $liveLastExternalId)
        $checkpoint.batchesCompleted = $batchesCompleted
        $checkpoint.catalogItemsSeen = $catalogItemsSeen
        $checkpoint.liveItemsSeen = $liveItemsSeen
        $checkpoint.liveEligibleSeen = $liveEligibleSeen
        $checkpoint.catalogChangedSeen = $catalogChangedSeen
        $checkpoint.liveChangedSeen = $liveChangedSeen
        $checkpoint.quarantinedSeen = $quarantinedSeen
        $checkpoint.warningsSeen = $warningsSeen
        $checkpoint.negativePriceSeen = $negativePriceSeen
        $checkpoint.negativeStockSeen = $negativeStockSeen
        $checkpoint.counts = [pscustomobject][ordered]@{
            catalogRowsSeen = $catalogItemsSeen
            liveRowsSeen = $liveItemsSeen
            liveEligibleSeen = $liveEligibleSeen
            catalogChanged = $catalogChangedSeen
            liveChanged = $liveChangedSeen
            quarantined = $quarantinedSeen
            warnings = $warningsSeen
        }
        $checkpoint.catalogComplete = $catalogComplete
        $checkpoint.liveComplete = $liveComplete
        $checkpoint.status = "running"
        $checkpoint.updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
        Write-JsonFileAtomic -Path $checkpointPath -Value $checkpoint

        if ($failFastViolation) {
            throw "Live data contains negative price item(s); OnInvalidLive=FailFast stopped the run."
        }

        if (($batchesCompleted % $ProgressEveryBatches) -eq 0) {
            Write-Host ("Batch {0} completed. syncRunId={1} runType={2} lastExternalId={3} catalogSeen={4} liveSeen={5} catalogChanged={6} liveChanged={7} quarantine={8} elapsed={9}" -f `
                $batchesCompleted, $syncRunId, $RunType, $checkpoint.lastProcessedExternalId, $catalogItemsSeen, $liveItemsSeen, $catalogChangedSeen, $liveChangedSeen, $quarantinedSeen, $runStopwatch.Elapsed.ToString("hh\:mm\:ss"))
        }
    }
}
catch {
    $runFailure = $_
}

$catalogPayloadFiles = @(Get-ChildItem -LiteralPath $batchWorkDirectory -File -Filter "*.catalog-payload.ndjson")
$catalogChangedFiles = @(Get-ChildItem -LiteralPath $batchWorkDirectory -File -Filter "*.catalog-changed.ndjson")
$livePayloadFiles = @(Get-ChildItem -LiteralPath $batchWorkDirectory -File -Filter "*.live-payload.ndjson")
$liveChangedFiles = @(Get-ChildItem -LiteralPath $batchWorkDirectory -File -Filter "*.live-changed.ndjson")
$quarantineFiles = @(Get-ChildItem -LiteralPath $batchWorkDirectory -File -Filter "*.quarantine.ndjson")
$eventFiles = @(Get-ChildItem -LiteralPath $batchWorkDirectory -File -Filter "*.events.ndjson")
$warningFiles = @(Get-ChildItem -LiteralPath $batchWorkDirectory -File -Filter "*.warnings.ndjson")

$commonPayloadHeader = [pscustomobject][ordered]@{
    source = "neptuno"
    sourceKey = $SourceKey.Trim()
    agentId = $SourceKey.Trim()
    syncRunId = $syncRunId
    runType = $RunType
    capturedAt = $capturedAt
}
$deltaHeader = [pscustomobject][ordered]@{
    contractVersion = 2
    source = "neptuno"
    sourceKey = $SourceKey.Trim()
    syncRunId = $syncRunId
    idempotencyKey = $syncRunId
    runType = $RunType
    mode = $Mode
    capturedAt = $capturedAt
    quarantinedItems = [pscustomobject][ordered]@{
        total = $quarantinedSeen
        negativePrice = $negativePriceSeen
        negativeStockWarnings = $negativeStockSeen
    }
}
$quarantineHeader = [pscustomobject][ordered]@{
    source = "neptuno"
    sourceKey = $SourceKey.Trim()
    syncRunId = $syncRunId
    runType = $RunType
    capturedAt = $capturedAt
}

Write-EnvelopeFromNdjson -Path (Join-Path $runDirectory "catalog-payload.json") -Header $commonPayloadHeader -ItemsProperty "items" -Files $catalogPayloadFiles
Write-EnvelopeFromNdjson -Path (Join-Path $runDirectory "live-payload.json") -Header $commonPayloadHeader -ItemsProperty "items" -Files $livePayloadFiles
Write-DeltaFromNdjson -Path (Join-Path $runDirectory "changed-products.json") -Header $deltaHeader -CatalogFiles $catalogChangedFiles -LiveFiles $liveChangedFiles
Write-EnvelopeFromNdjson -Path (Join-Path $runDirectory "quarantine-items.json") -Header $quarantineHeader -ItemsProperty "items" -Files $quarantineFiles

if ($null -ne $runFailure) {
    $failedAt = [DateTimeOffset]::UtcNow.ToString("o")
    $checkpoint.status = "failed"
    $checkpoint.updatedAt = $failedAt
    $checkpoint | Add-Member -NotePropertyName failedAt -NotePropertyValue $failedAt -Force
    $checkpoint | Add-Member -NotePropertyName failureType -NotePropertyValue $runFailure.Exception.GetType().Name -Force
    Write-JsonFileAtomic -Path $checkpointPath -Value $checkpoint
    $failedEvent = [pscustomobject][ordered]@{
        eventType = "sync-failed"
        syncRunId = $syncRunId
        occurredAt = $failedAt
        runType = $RunType
        mode = $Mode
        failureType = $runFailure.Exception.GetType().Name
        sendAttempted = $false
    }
    Merge-NdjsonFiles -Path (Join-Path $runDirectory "sync-events.ndjson") -Files $eventFiles -TrailingEvents @($failedEvent)
    Merge-NdjsonFiles -Path (Join-Path $runDirectory "sync-warnings.ndjson") -Files $warningFiles
    $failedSummary = [pscustomobject][ordered]@{
        status = "failed"
        sourceKey = $SourceKey.Trim()
        syncRunId = $syncRunId
        runType = $RunType
        mode = $Mode
        dryRun = $effectiveDryRun
        sendRequested = [bool]$Send
        sendAttempted = $false
        sendStatus = "not-attempted"
        batchesCompleted = $batchesCompleted
        catalogItems = $catalogItemsSeen
        liveItems = $liveEligibleSeen
        catalogRowsSeen = $catalogItemsSeen
        liveRowsSeen = $liveItemsSeen
        changedCatalogItems = $catalogChangedSeen
        changedLiveItems = $liveChangedSeen
        quarantinedItems = $quarantinedSeen
        warnings = $warningsSeen
        negativePriceItems = $negativePriceSeen
        negativeStockItems = $negativeStockSeen
        eligibility = $Eligibility
        externalIdsFilterApplied = $externalIdsFilterApplied
        commandTimeoutSeconds = $CommandTimeoutSeconds
        stateUpdated = $false
        cursorsUpdated = $false
        failedAt = $failedAt
        failureType = $runFailure.Exception.GetType().Name
    }
    Write-JsonFileAtomic -Path (Join-Path $runDirectory "sync-summary.json") -Value $failedSummary
    Invoke-NeptunoSyncRetentionSafely
    throw "Batch execution failed. checkpoint=$checkpointPath reason=$($runFailure.Exception.Message)"
}

if ($controlledInterruption) {
    $interruptedAt = [DateTimeOffset]::UtcNow.ToString("o")
    $checkpoint.status = "interrupted"
    $checkpoint.updatedAt = $interruptedAt
    $checkpoint | Add-Member -NotePropertyName interruptedAt -NotePropertyValue $interruptedAt -Force
    Write-JsonFileAtomic -Path $checkpointPath -Value $checkpoint
    $interruptedEvent = [pscustomobject][ordered]@{
        eventType = "sync-interrupted"
        syncRunId = $syncRunId
        occurredAt = $interruptedAt
        runType = $RunType
        mode = $Mode
        reason = "MAX_BATCHES_REACHED"
    }
    Merge-NdjsonFiles -Path (Join-Path $runDirectory "sync-events.ndjson") -Files $eventFiles -TrailingEvents @($interruptedEvent)
    Merge-NdjsonFiles -Path (Join-Path $runDirectory "sync-warnings.ndjson") -Files $warningFiles
    $interruptedSummary = [pscustomobject][ordered]@{
        status = "interrupted"
        sourceKey = $SourceKey.Trim()
        syncRunId = $syncRunId
        runType = $RunType
        mode = $Mode
        dryRun = $effectiveDryRun
        sendRequested = [bool]$Send
        sendAttempted = $false
        sendStatus = "not-attempted"
        batchesCompleted = $batchesCompleted
        catalogItems = $catalogItemsSeen
        liveItems = $liveEligibleSeen
        catalogRowsSeen = $catalogItemsSeen
        liveRowsSeen = $liveItemsSeen
        changedCatalogItems = $catalogChangedSeen
        changedLiveItems = $liveChangedSeen
        quarantinedItems = $quarantinedSeen
        warnings = $warningsSeen
        negativePriceItems = $negativePriceSeen
        negativeStockItems = $negativeStockSeen
        eligibility = $Eligibility
        externalIdsFilterApplied = $externalIdsFilterApplied
        commandTimeoutSeconds = $CommandTimeoutSeconds
        stateUpdated = $false
        cursorsUpdated = $false
        interruptedAt = $interruptedAt
    }
    Write-JsonFileAtomic -Path (Join-Path $runDirectory "sync-summary.json") -Value $interruptedSummary
    Write-Host "Run interrupted after $batchesCompleted batch(es). State and latest were not updated."
    Write-Host "Resume with the same arguments plus -Resume. Checkpoint: $checkpointPath"
    return
}

$sendStatus = "dry-run"
$sendAttempted = $false
$stateUpdated = $false
$cursorsUpdated = $false
$chunksTotal = 0
$chunksSent = 0
try {
    $changedSendItems = [long]$catalogChangedSeen + [long]$liveChangedSeen
    if ($Send -and -not $InitialBaseline -and $changedSendItems -gt $MaxSendItems) {
        throw "Send guardrail blocked POST: changedCatalogItems + changedLiveItems is $changedSendItems, above MaxSendItems=$MaxSendItems."
    }

    if ($Send -and $changedSendItems -gt 0) {
        $sendAttempted = $true
        $deltaPayload = Get-Content -Raw -LiteralPath (Join-Path $runDirectory "changed-products.json") -Encoding UTF8 | ConvertFrom-Json
        if ($InitialBaseline) {
            $chunkManifest = Invoke-InitialBaselineChunkSend `
                -RunDirectory $runDirectory `
                -ParentSyncRunId $syncRunId `
                -RequestedChunkSize $ChunkSize `
                -DeltaPayload $deltaPayload `
                -Uri $parsedApiUri `
                -BearerToken $effectiveApiToken `
                -UseMockSend ([bool]$MockSendSuccess) `
                -DelayBetweenChunksSeconds $ChunkDelaySeconds `
                -MaximumAttemptsPerChunk $MaxChunkAttempts `
                -FailAtChunk $MockChunkFailureAt `
                -RateLimitAtChunk $MockChunkRateLimitAt `
                -SimulatedRetryAfterSeconds $MockRetryAfterSeconds
            $chunksTotal = [int]$chunkManifest.totalChunks
            $chunksSent = [int]$chunkManifest.sentChunks
            $sendStatus = "sent-chunked"
        }
        else {
            if (-not $MockSendSuccess) {
                Invoke-DeltaSend -Uri $parsedApiUri -BearerToken $effectiveApiToken -IdempotencyKey $syncRunId -Payload $deltaPayload
            }
            $sendStatus = "sent"
        }
    }
    elseif ($Send) {
        $sendStatus = "no-changes"
    }

    if ($RunType -ne "Audit") {
        $stateUpdatedAt = [DateTimeOffset]::UtcNow.ToString("o")
        $nextState = [pscustomobject][ordered]@{
            version = 2
            sourceKey = $SourceKey.Trim()
            updatedAt = $stateUpdatedAt
            catalog = ConvertTo-OrderedMap -Map $nextCatalog
            live = ConvertTo-OrderedMap -Map $nextLive
            sentCatalog = ConvertTo-OrderedMap -Map $nextSentCatalog
            sentLive = ConvertTo-OrderedMap -Map $nextSentLive
        }
        Assert-SafePayload -Value $nextState -Path '$.state'
        Write-JsonFileAtomic -Path $statePath -Value $nextState
        $stateUpdated = $true
        $nextCursors = [pscustomobject][ordered]@{
            version = 1
            sourceKey = $SourceKey.Trim()
            lastCatalogSyncAt = $(if ($catalogEnabled) { $stateUpdatedAt } else { $previousLastCatalogSyncAt })
            lastLiveSyncAt = $(if ($liveEnabled) { $stateUpdatedAt } else { $previousLastLiveSyncAt })
            lastSuccessfulSendAt = $(if ($sendStatus -in @("sent", "sent-chunked")) { $stateUpdatedAt } else { $previousLastSuccessfulSendAt })
            sourceHighWatermarks = [pscustomobject][ordered]@{
                catalogLastExternalId = $(if ($catalogEnabled) { $catalogLastExternalId } else { $null })
                liveLastExternalId = $(if ($liveEnabled) { $liveLastExternalId } else { $null })
            }
            queryStrategy = [pscustomobject][ordered]@{
                catalog = "external-id-keyset-batches-with-fingerprint-fallback"
                live = "external-id-keyset-batches-with-fingerprint-fallback"
            }
            schemaConfidence = [pscustomobject][ordered]@{
                catalog = "no-reliable-audit-column-confirmed"
                live = "operational-event-dates-not-safe-as-global-cursor"
            }
        }
        Write-JsonFileAtomic -Path $cursorPath -Value $nextCursors
        $cursorsUpdated = $true
    }
}
catch {
    $finalizationFailure = $_
    $chunkManifestPath = Join-Path $runDirectory "chunks/manifest.json"
    if ($InitialBaseline -and [System.IO.File]::Exists($chunkManifestPath)) {
        $failedChunkManifest = Get-Content -Raw -LiteralPath $chunkManifestPath -Encoding UTF8 | ConvertFrom-Json
        $chunksTotal = [int]$failedChunkManifest.totalChunks
        $chunksSent = [int]$failedChunkManifest.sentChunks
    }
    $failedAt = [DateTimeOffset]::UtcNow.ToString("o")
    $checkpoint.status = "failed"
    $checkpoint.updatedAt = $failedAt
    $checkpoint | Add-Member -NotePropertyName failedAt -NotePropertyValue $failedAt -Force
    $checkpoint | Add-Member -NotePropertyName failureType -NotePropertyValue $finalizationFailure.Exception.GetType().Name -Force
    Write-JsonFileAtomic -Path $checkpointPath -Value $checkpoint
    Merge-NdjsonFiles -Path (Join-Path $runDirectory "sync-events.ndjson") -Files $eventFiles -TrailingEvents @(
        [pscustomobject][ordered]@{
            eventType = "sync-failed"
            syncRunId = $syncRunId
            occurredAt = $failedAt
            runType = $RunType
            mode = $Mode
            failureType = $finalizationFailure.Exception.GetType().Name
            sendAttempted = $sendAttempted
        }
    )
    Merge-NdjsonFiles -Path (Join-Path $runDirectory "sync-warnings.ndjson") -Files $warningFiles
    $failedSummary = [pscustomobject][ordered]@{
        status = "failed"
        sourceKey = $SourceKey.Trim()
        syncRunId = $syncRunId
        runType = $RunType
        mode = $Mode
        dryRun = $effectiveDryRun
        sendRequested = [bool]$Send
        sendAttempted = $sendAttempted
        sendStatus = "failed"
        initialBaseline = [bool]$InitialBaseline
        chunkSize = $(if ($InitialBaseline) { $ChunkSize } else { $null })
        chunkDelaySeconds = $(if ($InitialBaseline) { $ChunkDelaySeconds } else { $null })
        maxChunkAttempts = $(if ($InitialBaseline) { $MaxChunkAttempts } else { $null })
        chunksTotal = $chunksTotal
        chunksSent = $chunksSent
        batchesCompleted = $batchesCompleted
        catalogItems = $catalogItemsSeen
        liveItems = $liveEligibleSeen
        catalogRowsSeen = $catalogItemsSeen
        liveRowsSeen = $liveItemsSeen
        changedCatalogItems = $catalogChangedSeen
        changedLiveItems = $liveChangedSeen
        quarantinedItems = $quarantinedSeen
        warnings = $warningsSeen
        negativePriceItems = $negativePriceSeen
        negativeStockItems = $negativeStockSeen
        eligibility = $Eligibility
        externalIdsFilterApplied = $externalIdsFilterApplied
        commandTimeoutSeconds = $CommandTimeoutSeconds
        stateUpdated = $stateUpdated
        cursorsUpdated = $cursorsUpdated
        failedAt = $failedAt
        failureType = $finalizationFailure.Exception.GetType().Name
    }
    Write-JsonFileAtomic -Path (Join-Path $runDirectory "sync-summary.json") -Value $failedSummary
    Invoke-NeptunoSyncRetentionSafely
    throw "Run finalization failed. checkpoint=$checkpointPath reason=$($finalizationFailure.Exception.Message)"
}

$completedAt = [DateTimeOffset]::UtcNow.ToString("o")
$checkpoint.status = "completed"
$checkpoint.updatedAt = $completedAt
$checkpoint | Add-Member -NotePropertyName completedAt -NotePropertyValue $completedAt -Force
Write-JsonFileAtomic -Path $checkpointPath -Value $checkpoint
$summary = [pscustomobject][ordered]@{
    status = "completed"
    sourceKey = $SourceKey.Trim()
    syncRunId = $syncRunId
    runType = $RunType
    mode = $Mode
    dryRun = $effectiveDryRun
    resumed = [bool]$Resume
    sendRequested = [bool]$Send
    sendAttempted = $sendAttempted
    sendStatus = $sendStatus
    initialBaseline = [bool]$InitialBaseline
    chunkSize = $(if ($InitialBaseline) { $ChunkSize } else { $null })
    chunkDelaySeconds = $(if ($InitialBaseline) { $ChunkDelaySeconds } else { $null })
    maxChunkAttempts = $(if ($InitialBaseline) { $MaxChunkAttempts } else { $null })
    chunksTotal = $chunksTotal
    chunksSent = $chunksSent
    batchesCompleted = $batchesCompleted
    catalogItems = $catalogItemsSeen
    liveItems = $liveEligibleSeen
    catalogRowsSeen = $catalogItemsSeen
    liveRowsSeen = $liveItemsSeen
    changedCatalogItems = $catalogChangedSeen
    changedLiveItems = $liveChangedSeen
    quarantinedItems = $quarantinedSeen
    warnings = $warningsSeen
    negativePriceItems = $negativePriceSeen
    negativeStockItems = $negativeStockSeen
    eligibility = $Eligibility
    externalIdsFilterApplied = $externalIdsFilterApplied
    commandTimeoutSeconds = $CommandTimeoutSeconds
    stateUpdated = $stateUpdated
    cursorsUpdated = $cursorsUpdated
    completedAt = $completedAt
}
Write-JsonFileAtomic -Path (Join-Path $runDirectory "sync-summary.json") -Value $summary
Merge-NdjsonFiles -Path (Join-Path $runDirectory "sync-events.ndjson") -Files $eventFiles -TrailingEvents @(
    [pscustomobject][ordered]@{
        eventType = "sync-completed"
        syncRunId = $syncRunId
        occurredAt = $completedAt
        runType = $RunType
        mode = $Mode
        dryRun = $effectiveDryRun
        sendStatus = $sendStatus
        batchesCompleted = $batchesCompleted
        catalogItems = $catalogItemsSeen
        liveItems = $liveEligibleSeen
        changedCatalogItems = $catalogChangedSeen
        changedLiveItems = $liveChangedSeen
        quarantinedItems = $quarantinedSeen
        warnings = $warningsSeen
    }
)
Merge-NdjsonFiles -Path (Join-Path $runDirectory "sync-warnings.ndjson") -Files $warningFiles
Write-JsonFileAtomic -Path (Join-Path $latestDirectory "sync-summary.json") -Value $summary

$resolvedWorkDirectory = [System.IO.Path]::GetFullPath($workDirectory)
$resolvedRunDirectory = [System.IO.Path]::GetFullPath($runDirectory).TrimEnd('\', '/')
$runPrefix = $resolvedRunDirectory + [System.IO.Path]::DirectorySeparatorChar
if ($resolvedWorkDirectory.StartsWith($runPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
    -not ((Get-Item -LiteralPath $resolvedWorkDirectory -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    Remove-Item -LiteralPath $resolvedWorkDirectory -Recurse -Force
}
Invoke-NeptunoSyncRetentionSafely

Write-Host "NEPTUNO sync completed."
Write-Host "Run type: $RunType; mode: $Mode; batches: $batchesCompleted; dry-run: $effectiveDryRun"
Write-Host "Catalog items: $($summary.catalogItems); changed: $($summary.changedCatalogItems)"
Write-Host "Live items: $($summary.liveItems); changed: $($summary.changedLiveItems)"
Write-Host "Quarantined items: $($summary.quarantinedItems); warnings: $($summary.warnings)"
Write-Host "Send status: $sendStatus"
Write-Host "Run output: $runDirectory"
Write-Host "Permanent state: $stateDirectory"
