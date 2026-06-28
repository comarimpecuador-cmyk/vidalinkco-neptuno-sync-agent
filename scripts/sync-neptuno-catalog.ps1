[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConnectionString = "Data Source=localhost;Initial Catalog=NEPTUNO;Integrated Security=True;Encrypt=False;ApplicationIntent=ReadOnly",

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) "exports/neptuno-sync"),

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
    [switch]$Send,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [string]$ApiUrl,

    [Parameter()]
    [string]$ApiToken,

    [Parameter()]
    [switch]$RebuildState,

    [Parameter(DontShow)]
    [string]$FixturePath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "NeptunoAudit.Common.ps1")

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
    if ($price -lt 0) {
        throw "Product '$externalId' has a negative precioOrigen."
    }

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

function New-LiveItem {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$ItemSourceKey,
        [Parameter(Mandatory)][string]$CapturedAt
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
    $stockUnit = ConvertTo-RequiredDecimal -Value (Get-RowValue -Row $Row -Name "stockUnidad") -FieldName "stockUnidad" -ExternalId $externalId
    $stockFraction = ConvertTo-RequiredDecimal -Value (Get-RowValue -Row $Row -Name "stockFraccion") -FieldName "stockFraccion" -ExternalId $externalId
    if ($price -lt 0 -or $stockUnit -lt 0 -or $stockFraction -lt 0) {
        throw "Product '$externalId' has negative live price or stock."
    }

    return [pscustomobject][ordered]@{
        externalId = $externalId
        sourceKey = $ItemSourceKey.Trim()
        bodegaExternalId = $warehouseId
        bodegaNombre = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "bodegaNombre")
        precioActual = $price
        stockUnidad = $stockUnit
        stockFraccion = $stockFraction
        estadoExternalId = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "estadoExternalId")
        estadoNombre = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "estadoNombre")
        puedeVender = ConvertTo-NullableBool -Value (Get-RowValue -Row $Row -Name "puedeVender")
        aplicaIvaOrigen = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "aplicaIvaOrigen")
        capturedAt = $CapturedAt
        rawOperativo = [pscustomobject][ordered]@{
            ivaOrigenId = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "ivaOrigenId")
            bodegaHabilitado = ConvertTo-NullableString -Value (Get-RowValue -Row $Row -Name "bodegaHabilitado")
        }
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
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    $connection = [System.Data.SqlClient.SqlConnection]::new($SafeConnectionString)
    try {
        $connection.Open()
        $table = Invoke-NeptunoQuery -Connection $connection -Query $Sql -Parameters $Parameters -CommandTimeout 120
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

    $responseProperty = $Exception.PSObject.Properties["Response"]
    if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
        $statusProperty = $responseProperty.Value.PSObject.Properties["StatusCode"]
        if ($null -ne $statusProperty -and $null -ne $statusProperty.Value) {
            return [int]$statusProperty.Value
        }
    }
    return $null
}

function Invoke-DeltaSend {
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
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $Uri -Method Post -Headers $headers -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 30 -UseBasicParsing
            $envelope = $response.Content | ConvertFrom-Json
            $okProperty = $envelope.PSObject.Properties["ok"]
            if ($null -eq $okProperty -or -not [bool]$okProperty.Value) {
                throw "Vidalinkco returned a rejected or invalid response envelope."
            }
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

if ([string]::IsNullOrWhiteSpace($SourceKey)) {
    throw "SourceKey is required."
}
if ($Send -and $DryRun) {
    throw "Use either -Send or -DryRun, not both."
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
$capturedAt = [DateTimeOffset]::UtcNow.ToString("o")
$syncRunId = "neptuno-" + [DateTimeOffset]::UtcNow.ToString("yyyyMMddTHHmmssfffZ") + "-" + ([Guid]::NewGuid().ToString("N").Substring(0, 8))
$effectiveMaxProducts = if ($null -eq $MaxProducts) { [int]::MaxValue } else { [int]$MaxProducts }
$catalogEnabled = $Mode -in @("Catalog", "All")
$liveEnabled = $Mode -in @("Live", "All")

$catalogRows = @()
$liveRows = @()
if (-not [string]::IsNullOrWhiteSpace($FixturePath)) {
    $resolvedFixturePath = [System.IO.Path]::GetFullPath($FixturePath)
    if (-not [System.IO.File]::Exists($resolvedFixturePath)) {
        throw "FixturePath does not exist."
    }
    $fixture = Get-Content -Raw -LiteralPath $resolvedFixturePath -Encoding UTF8 | ConvertFrom-Json
    if ($catalogEnabled) { $catalogRows = @($fixture.catalogRows | Select-Object -First $effectiveMaxProducts) }
    if ($liveEnabled) { $liveRows = @($fixture.liveRows | Where-Object { [long]$_.bodegaExternalId -eq $BodegaId } | Select-Object -First $effectiveMaxProducts) }
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
    if ($catalogEnabled) {
        $catalogRows = Invoke-NeptunoSelectRows -SafeConnectionString $builder.ConnectionString -Sql $catalogSql -Parameters @{ MaxProducts = $effectiveMaxProducts }
    }
    if ($liveEnabled) {
        $liveRows = Invoke-NeptunoSelectRows -SafeConnectionString $builder.ConnectionString -Sql $liveSql -Parameters @{ BodegaId = $BodegaId; MaxProducts = $effectiveMaxProducts }
    }
}

$catalogItems = [System.Collections.Generic.List[object]]::new()
foreach ($row in $catalogRows) {
    $catalogItems.Add((New-CatalogItem -Row $row -ItemSourceKey $SourceKey))
}
$liveItems = [System.Collections.Generic.List[object]]::new()
foreach ($row in $liveRows) {
    $liveItems.Add((New-LiveItem -Row $row -ItemSourceKey $SourceKey -CapturedAt $capturedAt))
}
$sortedCatalogItems = @($catalogItems.ToArray() | Sort-Object externalId)
$sortedLiveItems = @($liveItems.ToArray() | Sort-Object externalId, bodegaExternalId)

$previousCatalog = @{}
$previousLive = @{}
$previousSentCatalog = @{}
$previousSentLive = @{}
if (-not $RebuildState -and [System.IO.File]::Exists($statePath)) {
    $previousState = Get-Content -Raw -LiteralPath $statePath -Encoding UTF8 | ConvertFrom-Json
    if ([string]::Equals([string]$previousState.sourceKey, $SourceKey.Trim(), [System.StringComparison]::Ordinal)) {
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

$limitedRun = $null -ne $MaxProducts
$nextCatalog = if ($RebuildState -or ($catalogEnabled -and -not $limitedRun)) { @{} } else { Copy-Map -Map $previousCatalog }
$nextLive = if ($RebuildState -or ($liveEnabled -and -not $limitedRun)) { @{} } else { Copy-Map -Map $previousLive }
$nextSentCatalog = if ($RebuildState -or ($Send -and $catalogEnabled -and -not $limitedRun)) { @{} } else { Copy-Map -Map $previousSentCatalog }
$nextSentLive = if ($RebuildState -or ($Send -and $liveEnabled -and -not $limitedRun)) { @{} } else { Copy-Map -Map $previousSentLive }
$catalogComparison = if ($Send) { $previousSentCatalog } else { $previousCatalog }
$liveComparison = if ($Send) { $previousSentLive } else { $previousLive }
$changedCatalog = [System.Collections.Generic.List[object]]::new()
$changedLive = [System.Collections.Generic.List[object]]::new()

if ($catalogEnabled) {
    foreach ($item in $sortedCatalogItems) {
        $hash = Get-StableFingerprint -Value $item
        if (-not $catalogComparison.ContainsKey($item.externalId) -or $catalogComparison[$item.externalId] -ne $hash -or $RebuildState) {
            $changedCatalog.Add($item)
        }
        $nextCatalog[$item.externalId] = $hash
        if ($Send) {
            $nextSentCatalog[$item.externalId] = $hash
        }
    }
}
if ($liveEnabled) {
    foreach ($item in $sortedLiveItems) {
        $key = "$($item.externalId)|$($item.bodegaExternalId)"
        $hash = Get-StableFingerprint -Value (Get-LiveFingerprintProjection -Item $item)
        if (-not $liveComparison.ContainsKey($key) -or $liveComparison[$key] -ne $hash -or $RebuildState) {
            $changedLive.Add($item)
        }
        $nextLive[$key] = $hash
        if ($Send) {
            $nextSentLive[$key] = $hash
        }
    }
}

$catalogPayload = [pscustomobject][ordered]@{
    source = "neptuno"
    sourceKey = $SourceKey.Trim()
    agentId = $SourceKey.Trim()
    syncRunId = $syncRunId
    capturedAt = $capturedAt
    items = $sortedCatalogItems
}
$livePayload = [pscustomobject][ordered]@{
    source = "neptuno"
    sourceKey = $SourceKey.Trim()
    agentId = $SourceKey.Trim()
    syncRunId = $syncRunId
    capturedAt = $capturedAt
    items = $sortedLiveItems
}
$deltaPayload = [pscustomobject][ordered]@{
    source = "neptuno"
    sourceKey = $SourceKey.Trim()
    syncRunId = $syncRunId
    mode = $Mode
    capturedAt = $capturedAt
    catalogItems = $changedCatalog.ToArray()
    liveItems = $changedLive.ToArray()
}
$nextState = [pscustomobject][ordered]@{
    version = 2
    sourceKey = $SourceKey.Trim()
    updatedAt = $capturedAt
    catalog = ConvertTo-OrderedMap -Map $nextCatalog
    live = ConvertTo-OrderedMap -Map $nextLive
    sentCatalog = ConvertTo-OrderedMap -Map $nextSentCatalog
    sentLive = ConvertTo-OrderedMap -Map $nextSentLive
}

Assert-SafePayload -Value $catalogPayload -Path '$.catalog'
Assert-SafePayload -Value $livePayload -Path '$.live'
Assert-SafePayload -Value $deltaPayload -Path '$.changes'
Assert-SafePayload -Value $nextState -Path '$.state'

[System.IO.Directory]::CreateDirectory($resolvedOutputDirectory) | Out-Null
[System.IO.Directory]::CreateDirectory($stateDirectory) | Out-Null
Write-JsonFile -Path (Join-Path $resolvedOutputDirectory "catalog-payload.json") -Value $catalogPayload
Write-JsonFile -Path (Join-Path $resolvedOutputDirectory "live-payload.json") -Value $livePayload
Write-JsonFile -Path (Join-Path $resolvedOutputDirectory "changed-products.json") -Value $deltaPayload

$sendStatus = "dry-run"
$sendAttempted = $false
try {
    if ($Send -and ($changedCatalog.Count + $changedLive.Count) -gt 0) {
        $sendAttempted = $true
        Invoke-DeltaSend -Uri $parsedApiUri -BearerToken $effectiveApiToken -IdempotencyKey $syncRunId -Payload $deltaPayload
        $sendStatus = "sent"
    }
    elseif ($Send) {
        $sendStatus = "no-changes"
    }

    Write-JsonFile -Path $statePath -Value $nextState
}
catch {
    $sendStatus = "failed"
    $failedSummary = [pscustomobject][ordered]@{
        sourceKey = $SourceKey.Trim()
        syncRunId = $syncRunId
        mode = $Mode
        dryRun = $effectiveDryRun
        sendRequested = [bool]$Send
        sendAttempted = $sendAttempted
        sendStatus = $sendStatus
        catalogItems = $sortedCatalogItems.Count
        liveItems = $sortedLiveItems.Count
        changedCatalogItems = $changedCatalog.Count
        changedLiveItems = $changedLive.Count
        stateUpdated = $false
        completedAt = [DateTimeOffset]::UtcNow.ToString("o")
    }
    Write-JsonFile -Path (Join-Path $resolvedOutputDirectory "sync-summary.json") -Value $failedSummary
    $failedEvent = [pscustomobject][ordered]@{
        eventType = "sync-failed"
        syncRunId = $syncRunId
        occurredAt = [DateTimeOffset]::UtcNow.ToString("o")
        mode = $Mode
        sendAttempted = $sendAttempted
    }
    [System.IO.File]::AppendAllText((Join-Path $resolvedOutputDirectory "sync-events.ndjson"), (($failedEvent | ConvertTo-Json -Compress) + "`n"), [System.Text.UTF8Encoding]::new($false))
    throw
}

$summary = [pscustomobject][ordered]@{
    sourceKey = $SourceKey.Trim()
    syncRunId = $syncRunId
    mode = $Mode
    dryRun = $effectiveDryRun
    sendRequested = [bool]$Send
    sendAttempted = $sendAttempted
    sendStatus = $sendStatus
    catalogItems = $sortedCatalogItems.Count
    liveItems = $sortedLiveItems.Count
    changedCatalogItems = $changedCatalog.Count
    changedLiveItems = $changedLive.Count
    stateUpdated = $true
    completedAt = [DateTimeOffset]::UtcNow.ToString("o")
}
Write-JsonFile -Path (Join-Path $resolvedOutputDirectory "sync-summary.json") -Value $summary
$event = [pscustomobject][ordered]@{
    eventType = "sync-completed"
    syncRunId = $syncRunId
    occurredAt = $summary.completedAt
    mode = $Mode
    dryRun = $effectiveDryRun
    sendStatus = $sendStatus
    catalogItems = $summary.catalogItems
    liveItems = $summary.liveItems
    changedCatalogItems = $summary.changedCatalogItems
    changedLiveItems = $summary.changedLiveItems
}
Assert-SafePayload -Value $event -Path '$.event'
[System.IO.File]::AppendAllText((Join-Path $resolvedOutputDirectory "sync-events.ndjson"), (($event | ConvertTo-Json -Compress) + "`n"), [System.Text.UTF8Encoding]::new($false))

Write-Host "NEPTUNO Phase 9A-1 sync completed."
Write-Host "Mode: $Mode"
Write-Host "Dry-run: $effectiveDryRun"
Write-Host "Catalog items: $($summary.catalogItems); changed: $($summary.changedCatalogItems)"
Write-Host "Live items: $($summary.liveItems); changed: $($summary.changedLiveItems)"
Write-Host "Send status: $sendStatus"
Write-Host "Output: $resolvedOutputDirectory"
