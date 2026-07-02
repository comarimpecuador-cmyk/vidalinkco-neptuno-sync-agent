[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Server = "localhost",

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Database = "NEPTUNO",

    [Parameter()]
    [ValidateRange(1, [long]::MaxValue)]
    [long]$ProductId = 9102,

    [Parameter()]
    [Nullable[long]]$VademecumId,

    [Parameter()]
    [string]$OutputDirectory,

    [Parameter()]
    [switch]$Export
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot "exports/local-audit"
}
. (Join-Path $PSScriptRoot "NeptunoAudit.Common.ps1")

function Get-HexPreview {
    param(
        [Parameter()]
        [byte[]]$Bytes,

        [Parameter()]
        [int]$Length = 64
    )

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
        return ""
    }

    $take = [Math]::Min($Length, $Bytes.Length)
    return "0x" + [BitConverter]::ToString($Bytes, 0, $take).Replace("-", "")
}

function Get-SafeRawPreview {
    param(
        [Parameter()]
        [byte[]]$Bytes,

        [Parameter()]
        [int]$Length = 160
    )

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
        return ""
    }

    $take = [Math]::Min($Length, $Bytes.Length)
    $builder = [System.Text.StringBuilder]::new()
    for ($index = 0; $index -lt $take; $index++) {
        $value = $Bytes[$index]
        if ($value -ge 32 -and $value -le 126) {
            [void]$builder.Append([char]$value)
        }
        else {
            [void]$builder.Append(".")
        }
    }
    return $builder.ToString()
}

function Test-BytePrefix {
    param(
        [Parameter()]
        [byte[]]$Bytes,

        [Parameter(Mandatory)]
        [byte[]]$Prefix
    )

    if ($null -eq $Bytes -or $Bytes.Length -lt $Prefix.Length) {
        return $false
    }

    for ($index = 0; $index -lt $Prefix.Length; $index++) {
        if ($Bytes[$index] -ne $Prefix[$index]) {
            return $false
        }
    }

    return $true
}

function Get-FormatDetection {
    param(
        [Parameter()]
        [byte[]]$Bytes
    )

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
        return "empty"
    }

    if (Test-BytePrefix $Bytes ([byte[]](0x1F, 0x8B))) { return "gzip-signature" }
    if (Test-BytePrefix $Bytes ([byte[]](0x50, 0x4B, 0x03, 0x04))) { return "zip-signature" }
    if (Test-BytePrefix $Bytes ([byte[]](0x25, 0x50, 0x44, 0x46))) { return "pdf-signature" }
    if (Test-BytePrefix $Bytes ([byte[]](0x89, 0x50, 0x4E, 0x47))) { return "png-signature" }
    if (Test-BytePrefix $Bytes ([byte[]](0xFF, 0xD8, 0xFF))) { return "jpeg-signature" }
    if (Test-BytePrefix $Bytes ([byte[]](0xD0, 0xCF, 0x11, 0xE0))) { return "ole-compound-signature" }
    if (Test-BytePrefix $Bytes ([byte[]](0xEF, 0xBB, 0xBF))) { return "utf8-bom" }
    if (Test-BytePrefix $Bytes ([byte[]](0xFF, 0xFE))) { return "utf16-le-bom" }
    if (Test-BytePrefix $Bytes ([byte[]](0xFE, 0xFF))) { return "utf16-be-bom" }
    if ((Test-BytePrefix $Bytes ([byte[]](0x78, 0x01))) -or
        (Test-BytePrefix $Bytes ([byte[]](0x78, 0x5E))) -or
        (Test-BytePrefix $Bytes ([byte[]](0x78, 0x9C))) -or
        (Test-BytePrefix $Bytes ([byte[]](0x78, 0xDA)))) {
        return "possible-zlib-signature"
    }

    $ascii = [System.Text.Encoding]::ASCII.GetString($Bytes, 0, [Math]::Min($Bytes.Length, 32))
    if ($ascii.StartsWith('{\rtf')) { return "rtf-text-signature" }
    if ($ascii.TrimStart().StartsWith("<")) { return "possible-html-or-xml" }

    return "unknown-binary-or-proprietary"
}

$connection = New-NeptunoReadOnlyConnection `
    -Server $Server `
    -Database $Database `
    -ApplicationName "Vidalinkco NEPTUNO Vademecum Blob Audit"

try {
    $connection.Open()

    $resolvedVademecumId = if ($null -ne $VademecumId) {
        [long]$VademecumId
    }
    else {
        $resolved = Invoke-NeptunoQuery -Connection $connection -Query @"
SELECT TOP (1) id_vademecum
FROM in_producto
WHERE id_producto = @ProductId;
"@ -Parameters @{ ProductId = $ProductId }
        if ($resolved.Rows.Count -eq 0 -or $resolved.Rows[0]["id_vademecum"] -is [DBNull]) {
            throw "Could not resolve VademecumId from ProductId $ProductId. Pass -VademecumId explicitly."
        }
        [long]$resolved.Rows[0]["id_vademecum"]
    }

    $header = Invoke-NeptunoQuery -Connection $connection -Query @"
SELECT
    id_vademecum,
    descripcion,
    id_fabricante,
    activo,
    DATALENGTH(cabecera) AS cabeceraBytes,
    CAST(SUBSTRING(CAST(cabecera AS varbinary(max)), 1, 512) AS varbinary(512)) AS cabeceraPreviewBytes
FROM fa_vademecum
WHERE id_vademecum = @VademecumId;
"@ -Parameters @{ VademecumId = $resolvedVademecumId }

    $sections = Invoke-NeptunoQuery -Connection $connection -Query @"
SELECT
    id_seccion_vademecum,
    id_vademecum,
    secuencia,
    nombre,
    DATALENGTH(contenido) AS contenidoBytes,
    CAST(SUBSTRING(CAST(contenido AS varbinary(max)), 1, 512) AS varbinary(512)) AS contenidoPreviewBytes
FROM fa_seccion_vademecum
WHERE id_vademecum = @VademecumId
ORDER BY secuencia, id_seccion_vademecum;
"@ -Parameters @{ VademecumId = $resolvedVademecumId }
}
finally {
    if ($connection.State -ne [System.Data.ConnectionState]::Closed) {
        $connection.Close()
    }
    $connection.Dispose()
}

if ($header.Rows.Count -eq 0) {
    throw "VademecumId $resolvedVademecumId was not found."
}

$results = [System.Collections.Generic.List[object]]::new()
$headerBytes = if ($header.Rows[0]["cabeceraPreviewBytes"] -is [DBNull]) { $null } else { [byte[]]$header.Rows[0]["cabeceraPreviewBytes"] }
$results.Add([pscustomobject]@{
    kind = "header"
    recordId = $resolvedVademecumId
    vademecumId = $resolvedVademecumId
    name = [string]$header.Rows[0]["descripcion"]
    bytes = if ($header.Rows[0]["cabeceraBytes"] -is [DBNull]) { 0 } else { [long]$header.Rows[0]["cabeceraBytes"] }
    formatDetection = Get-FormatDetection -Bytes $headerBytes
    hexPreview = Get-HexPreview -Bytes $headerBytes
    safeRawPreview = Get-SafeRawPreview -Bytes $headerBytes
    publicationStatus = "pending-reliable-decoding-do-not-publish"
})

foreach ($section in $sections.Rows) {
    $bytes = if ($section["contenidoPreviewBytes"] -is [DBNull]) { $null } else { [byte[]]$section["contenidoPreviewBytes"] }
    $results.Add([pscustomobject]@{
        kind = "section"
        recordId = [long]$section["id_seccion_vademecum"]
        vademecumId = $resolvedVademecumId
        sequence = if ($section["secuencia"] -is [DBNull]) { $null } else { $section["secuencia"] }
        name = if ($section["nombre"] -is [DBNull]) { "" } else { [string]$section["nombre"] }
        bytes = if ($section["contenidoBytes"] -is [DBNull]) { 0 } else { [long]$section["contenidoBytes"] }
        formatDetection = Get-FormatDetection -Bytes $bytes
        hexPreview = Get-HexPreview -Bytes $bytes
        safeRawPreview = Get-SafeRawPreview -Bytes $bytes
        publicationStatus = "pending-reliable-decoding-do-not-publish"
    })
}

Write-Host "NEPTUNO vademecum blob audit completed (read-only)."
Write-Host "ProductId: $ProductId"
Write-Host "VademecumId: $resolvedVademecumId"
Write-Host "Name: $([string]$header.Rows[0]['descripcion'])"
Write-Host "Sections: $($sections.Rows.Count)"
foreach ($result in $results) {
    Write-Host ("{0} {1}: bytes={2}, format={3}, hex={4}" -f $result.kind, $result.recordId, $result.bytes, $result.formatDetection, $result.hexPreview)
}
Write-Host "Blob content remains pending reliable decoding and must not be published as final text."

if ($Export) {
    $resolvedOutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
    [System.IO.Directory]::CreateDirectory($resolvedOutputDirectory) | Out-Null
    $report = [ordered]@{
        audit = "NEPTUNO vademecum blob read-only audit"
        server = $Server
        database = $Database
        productId = $ProductId
        vademecumId = $resolvedVademecumId
        generatedAtUtc = [DateTime]::UtcNow.ToString("o")
        note = "Only bounded byte previews are included. Content is pending reliable decoding and is not publishable."
        records = $results.ToArray()
    }
    Write-Utf8NoBomLf `
        -Path (Join-Path $resolvedOutputDirectory "vademecum-blob-audit.json") `
        -Content (($report | ConvertTo-Json -Depth 10) + "`n")
    Write-Host "Local metadata export written to: $resolvedOutputDirectory"
    Write-Host "Do not commit or share this file."
}
