[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Server = "localhost",

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Database = "NEPTUNO",

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

$connection = New-NeptunoReadOnlyConnection `
    -Server $Server `
    -Database $Database `
    -ApplicationName "Vidalinkco NEPTUNO Schema Audit"

$relevantTables = @(
    "in_item",
    "in_producto",
    "in_estado_item",
    "in_nodo_clasif_1",
    "in_nodo_clasif_2",
    "in_fabricante",
    "co_ente",
    "fa_vademecum",
    "fa_seccion_vademecum",
    "pa_catalogo",
    "pa_item_catalogo",
    "in_presentacion",
    "in_medida",
    "in_concentracion",
    "in_item_bodega",
    "in_bodega",
    "in_producto_comercial",
    "ve_mensaje_producto",
    "ve_mensaje_producto_cab",
    "ve_mensaje_producto_det",
    "ve_producto_mensaje",
    "fa_auxilios_producto",
    "fa_primeros_aux",
    "in_valor_atributo_item",
    "mc_plan_producto",
    "in_producto_convenio",
    "in_item_complement",
    "in_item_datos_asegensa"
)

try {
    $connection.Open()

    $tables = Invoke-NeptunoQuery -Connection $connection -Query @"
SELECT
    s.name AS schemaName,
    t.name AS tableName,
    SUM(p.rows) AS approximateRows
FROM sys.tables t
JOIN sys.schemas s
    ON s.schema_id = t.schema_id
LEFT JOIN sys.partitions p
    ON p.object_id = t.object_id
   AND p.index_id IN (0, 1)
WHERE t.name IN (
    'in_item', 'in_producto', 'in_estado_item', 'in_nodo_clasif_1', 'in_nodo_clasif_2',
    'in_fabricante', 'co_ente', 'fa_vademecum', 'fa_seccion_vademecum',
    'pa_catalogo', 'pa_item_catalogo', 'in_presentacion', 'in_medida', 'in_concentracion',
    'in_item_bodega', 'in_bodega', 'in_producto_comercial', 've_mensaje_producto',
    've_mensaje_producto_cab', 've_mensaje_producto_det', 've_producto_mensaje',
    'fa_auxilios_producto', 'fa_primeros_aux', 'in_valor_atributo_item',
    'mc_plan_producto', 'in_producto_convenio', 'in_item_complement', 'in_item_datos_asegensa'
)
GROUP BY s.name, t.name
ORDER BY t.name;
"@

    $columns = Invoke-NeptunoQuery -Connection $connection -Query @"
SELECT
    s.name AS schemaName,
    t.name AS tableName,
    c.column_id AS columnId,
    c.name AS columnName,
    ty.name AS dataType,
    c.max_length AS maxLength,
    c.precision AS numericPrecision,
    c.scale AS numericScale,
    c.is_nullable AS isNullable,
    c.is_identity AS isIdentity
FROM sys.tables t
JOIN sys.schemas s
    ON s.schema_id = t.schema_id
JOIN sys.columns c
    ON c.object_id = t.object_id
JOIN sys.types ty
    ON ty.user_type_id = c.user_type_id
WHERE t.name IN (
    'in_item', 'in_producto', 'in_estado_item', 'in_nodo_clasif_1', 'in_nodo_clasif_2',
    'in_fabricante', 'co_ente', 'fa_vademecum', 'fa_seccion_vademecum',
    'pa_catalogo', 'pa_item_catalogo', 'in_presentacion', 'in_medida', 'in_concentracion',
    'in_item_bodega', 'in_bodega', 'in_producto_comercial', 've_mensaje_producto',
    've_mensaje_producto_cab', 've_mensaje_producto_det', 've_producto_mensaje',
    'fa_auxilios_producto', 'fa_primeros_aux', 'in_valor_atributo_item',
    'mc_plan_producto', 'in_producto_convenio', 'in_item_complement', 'in_item_datos_asegensa'
)
ORDER BY t.name, c.column_id;
"@

    $foreignKeys = Invoke-NeptunoQuery -Connection $connection -Query @"
SELECT
    fk.name AS foreignKeyName,
    OBJECT_SCHEMA_NAME(fk.parent_object_id) AS sourceSchema,
    OBJECT_NAME(fk.parent_object_id) AS sourceTable,
    pc.name AS sourceColumn,
    OBJECT_SCHEMA_NAME(fk.referenced_object_id) AS targetSchema,
    OBJECT_NAME(fk.referenced_object_id) AS targetTable,
    rc.name AS targetColumn
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc
    ON fkc.constraint_object_id = fk.object_id
JOIN sys.columns pc
    ON pc.object_id = fkc.parent_object_id
   AND pc.column_id = fkc.parent_column_id
JOIN sys.columns rc
    ON rc.object_id = fkc.referenced_object_id
   AND rc.column_id = fkc.referenced_column_id
WHERE
    OBJECT_NAME(fk.parent_object_id) IN (
        'in_item', 'in_producto', 'in_item_bodega', 'fa_vademecum', 'fa_seccion_vademecum',
        'pa_catalogo', 'pa_item_catalogo', 'in_presentacion', 'in_medida', 'in_concentracion'
    )
    OR OBJECT_NAME(fk.referenced_object_id) IN (
        'in_item', 'in_producto', 'in_item_bodega', 'fa_vademecum', 'fa_seccion_vademecum',
        'pa_catalogo', 'pa_item_catalogo', 'in_presentacion', 'in_medida', 'in_concentracion'
    )
ORDER BY sourceTable, foreignKeyName, fkc.constraint_column_id;
"@

    $keywordTables = Invoke-NeptunoQuery -Connection $connection -Query @"
SELECT
    s.name AS schemaName,
    t.name AS tableName
FROM sys.tables t
JOIN sys.schemas s
    ON s.schema_id = t.schema_id
WHERE
    LOWER(t.name) LIKE '%producto%'
    OR LOWER(t.name) LIKE '%medicina%'
    OR LOWER(t.name) LIKE '%vademecum%'
    OR LOWER(t.name) LIKE '%dosis%'
    OR LOWER(t.name) LIKE '%posologia%'
    OR LOWER(t.name) LIKE '%indicacion%'
    OR LOWER(t.name) LIKE '%advertencia%'
    OR LOWER(t.name) LIKE '%laboratorio%'
    OR LOWER(t.name) LIKE '%atributo%'
    OR LOWER(t.name) LIKE '%mensaje%'
ORDER BY t.name;
"@

    $catalogRows = [System.Collections.Generic.List[object]]::new()
    foreach ($catalogTable in @("pa_catalogo", "pa_item_catalogo")) {
        if (Test-NeptunoTable -Connection $connection -TableName $catalogTable) {
            $catalogColumns = Get-NeptunoTableColumns -Connection $connection -TableName $catalogTable
            $searchColumns = @(
                $catalogColumns.Rows |
                    Where-Object {
                        [string]$_["dataType"] -in @("char", "nchar", "varchar", "nvarchar")
                    } |
                    ForEach-Object { [string]$_["columnName"] }
            )
            $safeTable = "[" + $catalogTable.Replace("]", "]]") + "]"
            $predicates = @(
                $searchColumns | ForEach-Object {
                    $safeColumn = "[" + $_.Replace("]", "]]") + "]"
                    "LTRIM(RTRIM(CONVERT(nvarchar(4000), $safeColumn))) = @Code"
                }
            )
            foreach ($knownCode in @("COM", "MG10", "G134")) {
                if ($predicates.Count -eq 0) {
                    break
                }
                $catalogQuery = "SELECT TOP (100) * FROM $safeTable WHERE " + ($predicates -join " OR ") + ";"
                $catalogData = Invoke-NeptunoQuery `
                    -Connection $connection `
                    -Query $catalogQuery `
                    -Parameters @{ Code = $knownCode }
                foreach ($row in (ConvertFrom-NeptunoDataTable -Table $catalogData)) {
                    $catalogRows.Add([pscustomobject]@{
                        sourceTable = $catalogTable
                        searchedCode = $knownCode
                        row = ($row | ConvertTo-Json -Compress -Depth 10)
                    })
                }
            }
        }
    }
}
finally {
    if ($connection.State -ne [System.Data.ConnectionState]::Closed) {
        $connection.Close()
    }
    $connection.Dispose()
}

$tableObjects = @(ConvertFrom-NeptunoDataTable -Table $tables)
$columnObjects = @(ConvertFrom-NeptunoDataTable -Table $columns)
$foreignKeyObjects = @(ConvertFrom-NeptunoDataTable -Table $foreignKeys)
$keywordTableObjects = @(ConvertFrom-NeptunoDataTable -Table $keywordTables)
$foundNames = @($tableObjects | ForEach-Object { $_.tableName })
$missingNames = @($relevantTables | Where-Object { $foundNames -notcontains $_ })

Write-Host "NEPTUNO schema audit completed (read-only)."
Write-Host "Relevant tables found: $($foundNames.Count)"
Write-Host "Relevant tables missing: $($missingNames.Count)"
Write-Host "Relevant columns: $($columnObjects.Count)"
Write-Host "Foreign-key rows: $($foreignKeyObjects.Count)"
Write-Host "Keyword table matches: $($keywordTableObjects.Count)"

if ($missingNames.Count -gt 0) {
    Write-Host "Missing: $($missingNames -join ', ')"
}

if ($Export) {
    $resolvedOutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
    [System.IO.Directory]::CreateDirectory($resolvedOutputDirectory) | Out-Null
    $report = [ordered]@{
        audit = "NEPTUNO schema read-only audit"
        server = $Server
        database = $Database
        generatedAtUtc = [DateTime]::UtcNow.ToString("o")
        relevantTables = $tableObjects
        missingRelevantTables = $missingNames
        columns = $columnObjects
        foreignKeys = $foreignKeyObjects
        keywordTables = $keywordTableObjects
        catalogPreview = $catalogRows.ToArray()
    }
    Write-Utf8NoBomLf `
        -Path (Join-Path $resolvedOutputDirectory "schema-audit.json") `
        -Content (($report | ConvertTo-Json -Depth 20) + "`n")
    Write-Host "Local schema export written to: $resolvedOutputDirectory"
    Write-Host "Do not commit or share this file."
}
