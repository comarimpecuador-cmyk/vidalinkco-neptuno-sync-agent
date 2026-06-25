[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputDir = "samples/vademecum-blobs",

    [Parameter()]
    [ValidateRange(1, 50)]
    [int]$Top = 5,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Database = "NEPTUNO",

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ServerInstance = "."
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Data

$resolvedOutputDir = [System.IO.Path]::GetFullPath(
    [Environment]::ExpandEnvironmentVariables($OutputDir)
)
[System.IO.Directory]::CreateDirectory($resolvedOutputDir) | Out-Null

$connectionString = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$connectionString.DataSource = $ServerInstance
$connectionString.InitialCatalog = $Database
$connectionString.IntegratedSecurity = $true
$connectionString.ApplicationIntent = [System.Data.SqlClient.ApplicationIntent]::ReadOnly
$connectionString.Encrypt = $false
$connectionString.ConnectTimeout = 15
$connectionString.ApplicationName = "Vidalinkco Neptuno Vademecum Blob Audit"

$connection = New-Object System.Data.SqlClient.SqlConnection $connectionString.ConnectionString
$metadata = [System.Collections.Generic.List[object]]::new()

function ConvertTo-SafeFilePart {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $builder = [System.Text.StringBuilder]::new()

    foreach ($character in $Value.ToCharArray()) {
        if ($invalidChars -contains $character) {
            [void]$builder.Append("_")
        }
        else {
            [void]$builder.Append($character)
        }
    }

    $safeValue = $builder.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($safeValue)) {
        return "unnamed"
    }

    if ($safeValue.Length -gt 80) {
        return $safeValue.Substring(0, 80)
    }

    return $safeValue
}

function ConvertTo-FirstBytesHex {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes,

        [Parameter()]
        [int]$Length = 32
    )

    $take = [Math]::Min($Length, $Bytes.Length)
    if ($take -eq 0) {
        return ""
    }

    return "0x" + [BitConverter]::ToString($Bytes, 0, $take).Replace("-", "")
}

function Export-BlobQuery {
    param(
        [Parameter(Mandatory)]
        [System.Data.SqlClient.SqlConnection]$SqlConnection,

        [Parameter(Mandatory)]
        [string]$Query,

        [Parameter(Mandatory)]
        [string]$Kind
    )

    $command = $SqlConnection.CreateCommand()
    $command.CommandText = $Query
    $command.CommandTimeout = 30
    [void]$command.Parameters.Add("@Top", [System.Data.SqlDbType]::Int)
    $command.Parameters["@Top"].Value = $Top

    $reader = $command.ExecuteReader([System.Data.CommandBehavior]::SequentialAccess)
    try {
        while ($reader.Read()) {
            $recordId = [string]$reader["recordId"]
            $vademecumId = [string]$reader["vademecumId"]
            $name = if ($reader["name"] -is [DBNull]) { "" } else { [string]$reader["name"] }
            $bytes = [byte[]]$reader["blobData"]

            $safeName = ConvertTo-SafeFilePart -Value $name
            $fileName = "{0}-{1}-vademecum-{2}-{3}.bin" -f $Kind, $recordId, $vademecumId, $safeName
            $filePath = Join-Path $resolvedOutputDir $fileName
            [System.IO.File]::WriteAllBytes($filePath, $bytes)

            $metadata.Add([pscustomobject]@{
                kind = $Kind
                recordId = $recordId
                vademecumId = $vademecumId
                name = $name
                bytes = $bytes.Length
                firstBytesHex = ConvertTo-FirstBytesHex -Bytes $bytes
                fileName = $fileName
            })
        }
    }
    finally {
        $reader.Dispose()
        $command.Dispose()
    }
}

$headerQuery = @"
SET NOCOUNT ON;
SELECT TOP (@Top)
  CAST(v.id_vademecum AS varchar(50)) AS recordId,
  CAST(v.id_vademecum AS varchar(50)) AS vademecumId,
  CAST(v.descripcion AS varchar(250)) AS name,
  CAST(v.cabecera AS varbinary(max)) AS blobData
FROM fa_vademecum v
WHERE DATALENGTH(v.cabecera) > 0
ORDER BY v.id_vademecum;
"@

$sectionQuery = @"
SET NOCOUNT ON;
SELECT TOP (@Top)
  CAST(s.id_seccion_vademecum AS varchar(50)) AS recordId,
  CAST(s.id_vademecum AS varchar(50)) AS vademecumId,
  CAST(s.nombre AS varchar(250)) AS name,
  CAST(s.contenido AS varbinary(max)) AS blobData
FROM fa_seccion_vademecum s
WHERE DATALENGTH(s.contenido) > 0
ORDER BY s.id_vademecum, s.secuencia, s.id_seccion_vademecum;
"@

try {
    $connection.Open()
    Export-BlobQuery -SqlConnection $connection -Query $headerQuery -Kind "header"
    Export-BlobQuery -SqlConnection $connection -Query $sectionQuery -Kind "section"
}
finally {
    if ($connection.State -ne [System.Data.ConnectionState]::Closed) {
        $connection.Close()
    }
    $connection.Dispose()
}

$metadataPath = Join-Path $resolvedOutputDir "metadata.csv"
$metadata |
    Sort-Object kind, vademecumId, recordId |
    Export-Csv -LiteralPath $metadataPath -NoTypeInformation -Encoding UTF8

Write-Host "Exported $($metadata.Count) limited read-only samples to: $resolvedOutputDir"
Write-Host "Metadata: $metadataPath"
Write-Host "Do not commit or share the generated files."
