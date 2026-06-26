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
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) "exports/local-audit"),

    [Parameter()]
    [switch]$Export
)

$ErrorActionPreference = "Stop"
$commonScript = Join-Path $PSScriptRoot "NeptunoAudit.Common.ps1"
. $commonScript

$connection = New-NeptunoReadOnlyConnection `
    -Server $Server `
    -Database $Database `
    -ApplicationName "Vidalinkco NEPTUNO Product Audit"

$tables = [ordered]@{}
$extraTableNames = @(
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

function Get-FirstRowValue {
    param(
        [Parameter()]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [string[]]$Names
    )

    if ($Rows.Count -eq 0) {
        return $null
    }

    foreach ($name in $Names) {
        $property = $Rows[0].PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return $property.Value
        }
    }

    return $null
}

function Add-AuditTable {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [long]$ReferenceId,

        [Parameter()]
        [string[]]$CandidateColumns = @("id_producto", "id_item")
    )

    $tables[$Name] = Get-NeptunoRowsByReference `
        -Connection $connection `
        -TableName $Name `
        -ReferenceId $ReferenceId `
        -CandidateColumns $CandidateColumns
}

try {
    $connection.Open()

    Add-AuditTable -Name "in_item" -ReferenceId $ProductId -CandidateColumns @("id_item", "id_producto")
    Add-AuditTable -Name "in_producto" -ReferenceId $ProductId -CandidateColumns @("id_producto", "id_item")

    $itemRows = @($tables["in_item"].rows)
    $productRows = @($tables["in_producto"].rows)

    $stateId = Get-FirstRowValue -Rows $itemRows -Names @("id_estado_item")
    $class1Id = Get-FirstRowValue -Rows $itemRows -Names @("id_clasif_1", "id_nodo_clasif_1")
    $class2Id = Get-FirstRowValue -Rows $itemRows -Names @("id_clasif_2", "id_nodo_clasif_2")
    $manufacturerId = Get-FirstRowValue -Rows $productRows -Names @("id_fabricante")
    $resolvedVademecumId = if ($null -ne $VademecumId) {
        [long]$VademecumId
    }
    else {
        $value = Get-FirstRowValue -Rows $productRows -Names @("id_vademecum")
        if ($null -eq $value) { $null } else { [long]$value }
    }

    if ($null -ne $stateId) {
        Add-AuditTable -Name "in_estado_item" -ReferenceId ([long]$stateId) -CandidateColumns @("id_estado_item")
    }
    if ($null -ne $class1Id) {
        Add-AuditTable -Name "in_nodo_clasif_1" -ReferenceId ([long]$class1Id) -CandidateColumns @("id_nodo_clasif_1", "id_clasif_1")
    }
    if ($null -ne $class2Id) {
        Add-AuditTable -Name "in_nodo_clasif_2" -ReferenceId ([long]$class2Id) -CandidateColumns @("id_nodo_clasif_2", "id_clasif_2")
    }
    if ($null -ne $manufacturerId) {
        Add-AuditTable -Name "in_fabricante" -ReferenceId ([long]$manufacturerId) -CandidateColumns @("id_ente", "id_fabricante")
        Add-AuditTable -Name "co_ente" -ReferenceId ([long]$manufacturerId) -CandidateColumns @("id_ente")
    }
    if ($null -ne $resolvedVademecumId) {
        Add-AuditTable -Name "fa_vademecum" -ReferenceId $resolvedVademecumId -CandidateColumns @("id_vademecum")
        Add-AuditTable -Name "fa_seccion_vademecum" -ReferenceId $resolvedVademecumId -CandidateColumns @("id_vademecum")
    }

    Add-AuditTable -Name "in_item_bodega" -ReferenceId $ProductId -CandidateColumns @("id_item", "id_producto")
    $stockRows = @($tables["in_item_bodega"].rows)
    $warehouseIds = @(
        $stockRows |
            ForEach-Object { $_.PSObject.Properties["id_bodega"].Value } |
            Where-Object { $null -ne $_ } |
            Select-Object -Unique
    )

    $warehouseRows = [System.Collections.Generic.List[object]]::new()
    if (Test-NeptunoTable -Connection $connection -TableName "in_bodega") {
        foreach ($warehouseId in $warehouseIds) {
            $result = Get-NeptunoRowsByReference `
                -Connection $connection `
                -TableName "in_bodega" `
                -ReferenceId ([long]$warehouseId) `
                -CandidateColumns @("id_bodega")
            foreach ($row in $result.rows) {
                $warehouseRows.Add($row)
            }
        }
        $tables["in_bodega"] = [pscustomobject]@{
            table = "in_bodega"
            status = "ok"
            filterColumn = "id_bodega"
            rows = $warehouseRows.ToArray()
        }
    }
    else {
        $tables["in_bodega"] = [pscustomobject]@{
            table = "in_bodega"
            status = "missing"
            filterColumn = $null
            rows = @()
        }
    }

    $catalogCodes = [System.Collections.Generic.List[string]]::new()
    foreach ($row in $productRows) {
        foreach ($name in @(
            "presentacion",
            "medida",
            "concentracion",
            "id_presentacion",
            "id_medida",
            "id_concentracion"
        )) {
            $property = $row.PSObject.Properties[$name]
            if ($null -ne $property -and $null -ne $property.Value) {
                $text = ([string]$property.Value).Trim()
                if (-not [string]::IsNullOrWhiteSpace($text) -and -not $catalogCodes.Contains($text)) {
                    $catalogCodes.Add($text)
                }
            }
        }
    }

    foreach ($catalogTable in @("pa_catalogo", "pa_item_catalogo")) {
        if (-not (Test-NeptunoTable -Connection $connection -TableName $catalogTable)) {
            $tables[$catalogTable] = [pscustomobject]@{
                table = $catalogTable
                status = "missing"
                filterColumn = $null
                rows = @()
            }
            continue
        }

        $columns = Get-NeptunoTableColumns -Connection $connection -TableName $catalogTable
        $searchColumns = @(
            $columns.Rows |
                Where-Object {
                    [string]$_["dataType"] -in @("char", "nchar", "varchar", "nvarchar")
                } |
                ForEach-Object { [string]$_["columnName"] }
        )

        $catalogRows = [System.Collections.Generic.List[object]]::new()
        foreach ($code in $catalogCodes) {
            if ($searchColumns.Count -eq 0) {
                break
            }

            $safeTable = "[" + $catalogTable.Replace("]", "]]") + "]"
            $predicates = @(
                $searchColumns | ForEach-Object {
                    $safeColumn = "[" + $_.Replace("]", "]]") + "]"
                    "LTRIM(RTRIM(CONVERT(nvarchar(4000), $safeColumn))) = @Code"
                }
            )
            $query = "SELECT TOP (100) * FROM $safeTable WHERE " + ($predicates -join " OR ") + ";"
            $matches = Invoke-NeptunoQuery -Connection $connection -Query $query -Parameters @{ Code = $code }
            foreach ($match in (ConvertFrom-NeptunoDataTable -Table $matches)) {
                $catalogRows.Add($match)
            }
        }

        $tables[$catalogTable] = [pscustomobject]@{
            table = $catalogTable
            status = "ok"
            filterColumn = "code lookup"
            rows = $catalogRows.ToArray()
        }
    }

    foreach ($extraTable in $extraTableNames) {
        Add-AuditTable `
            -Name $extraTable `
            -ReferenceId $ProductId `
            -CandidateColumns @("id_producto", "id_item", "id_producto_comercial")
    }
}
finally {
    if ($connection.State -ne [System.Data.ConnectionState]::Closed) {
        $connection.Close()
    }
    $connection.Dispose()
}

$flatFields = [System.Collections.Generic.List[object]]::new()
foreach ($tableEntry in $tables.GetEnumerator()) {
    $rowIndex = 0
    foreach ($row in @($tableEntry.Value.rows)) {
        $rowIndex++
        foreach ($property in $row.PSObject.Properties) {
            $flatFields.Add([pscustomobject]@{
                sourceTable = $tableEntry.Key
                row = $rowIndex
                field = $property.Name
                value = ConvertTo-DisplayValue -Value $property.Value
            })
        }
    }
}

$warehousesById = @{}
foreach ($warehouse in @($tables["in_bodega"].rows)) {
    $idProperty = $warehouse.PSObject.Properties["id_bodega"]
    if ($null -ne $idProperty) {
        $warehousesById[[string]$idProperty.Value] = $warehouse
    }
}

$stockExport = [System.Collections.Generic.List[object]]::new()
foreach ($stock in @($tables["in_item_bodega"].rows)) {
    $warehouseId = ConvertTo-DisplayValue -Value $stock.PSObject.Properties["id_bodega"].Value
    $warehouse = $warehousesById[$warehouseId]
    $stockExport.Add([pscustomobject]@{
        productId = $ProductId
        idBodega = $warehouseId
        bodegaNombre = if ($null -eq $warehouse) { "" } else { ConvertTo-DisplayValue $warehouse.PSObject.Properties["nombre"].Value }
        bodegaNombreLargo = if ($null -eq $warehouse -or $null -eq $warehouse.PSObject.Properties["nombre_largo"]) { "" } else { ConvertTo-DisplayValue $warehouse.PSObject.Properties["nombre_largo"].Value }
        bodegaNombreComercial = if ($null -eq $warehouse -or $null -eq $warehouse.PSObject.Properties["nombre_comercial"]) { "" } else { ConvertTo-DisplayValue $warehouse.PSObject.Properties["nombre_comercial"].Value }
        habilitado = if ($null -eq $stock.PSObject.Properties["habilitado"]) { "" } else { ConvertTo-DisplayValue $stock.PSObject.Properties["habilitado"].Value }
        stockUnidad = if ($null -eq $stock.PSObject.Properties["stock_unidad"]) { "" } else { ConvertTo-DisplayValue $stock.PSObject.Properties["stock_unidad"].Value }
        stockFraccion = if ($null -eq $stock.PSObject.Properties["stock_fraccion"]) { "" } else { ConvertTo-DisplayValue $stock.PSObject.Properties["stock_fraccion"].Value }
    })
}

$sectionExport = [System.Collections.Generic.List[object]]::new()
if ($tables.Contains("fa_seccion_vademecum")) {
    foreach ($section in @($tables["fa_seccion_vademecum"].rows)) {
        $sectionExport.Add([pscustomobject]@{
            idVademecum = if ($null -eq $section.PSObject.Properties["id_vademecum"]) { "" } else { ConvertTo-DisplayValue $section.PSObject.Properties["id_vademecum"].Value }
            idSeccion = if ($null -eq $section.PSObject.Properties["id_seccion_vademecum"]) { "" } else { ConvertTo-DisplayValue $section.PSObject.Properties["id_seccion_vademecum"].Value }
            secuencia = if ($null -eq $section.PSObject.Properties["secuencia"]) { "" } else { ConvertTo-DisplayValue $section.PSObject.Properties["secuencia"].Value }
            nombre = if ($null -eq $section.PSObject.Properties["nombre"]) { "" } else { ConvertTo-DisplayValue $section.PSObject.Properties["nombre"].Value }
            contenidoBytes = if ($null -eq $section.PSObject.Properties["contenido_bytes"]) { "" } else { ConvertTo-DisplayValue $section.PSObject.Properties["contenido_bytes"].Value }
            status = "metadata-only-pending-reliable-decoding"
        })
    }
}

$summary = [ordered]@{
    audit = "NEPTUNO product read-only audit"
    server = $Server
    database = $Database
    productId = $ProductId
    vademecumId = $resolvedVademecumId
    generatedAtUtc = [DateTime]::UtcNow.ToString("o")
    safety = [ordered]@{
        integratedSecurity = $true
        encrypt = $false
        applicationIntent = "ReadOnly"
        sentToVidalinkco = $false
        blobPublication = $false
    }
    tables = [ordered]@{}
}
foreach ($tableEntry in $tables.GetEnumerator()) {
    $summary.tables[$tableEntry.Key] = [ordered]@{
        status = $tableEntry.Value.status
        filterColumn = $tableEntry.Value.filterColumn
        rowCount = @($tableEntry.Value.rows).Count
        rows = @($tableEntry.Value.rows)
    }
}

Write-Host "NEPTUNO product audit completed (read-only)."
Write-Host "ProductId: $ProductId"
Write-Host "VademecumId: $(if ($null -eq $resolvedVademecumId) { 'not resolved' } else { $resolvedVademecumId })"
Write-Host "Tables audited: $($tables.Count)"
Write-Host "Stock rows: $($stockExport.Count)"
Write-Host "Vademecum sections: $($sectionExport.Count)"

if ($Export) {
    $resolvedOutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
    [System.IO.Directory]::CreateDirectory($resolvedOutputDirectory) | Out-Null

    Write-Utf8NoBomLf `
        -Path (Join-Path $resolvedOutputDirectory "product-summary.json") `
        -Content (($summary | ConvertTo-Json -Depth 20) + "`n")
    Export-Utf8NoBomCsv `
        -Path (Join-Path $resolvedOutputDirectory "product-flat-fields.csv") `
        -InputObject $flatFields.ToArray()
    Export-Utf8NoBomCsv `
        -Path (Join-Path $resolvedOutputDirectory "product-stock.csv") `
        -InputObject $stockExport.ToArray()
    Export-Utf8NoBomCsv `
        -Path (Join-Path $resolvedOutputDirectory "product-vademecum-sections.csv") `
        -InputObject $sectionExport.ToArray()

    $extraReport = [System.Collections.Generic.List[string]]::new()
    foreach ($extraTable in $extraTableNames) {
        $result = $tables[$extraTable]
        $extraReport.Add("[$extraTable] status=$($result.status) rows=$(@($result.rows).Count) filter=$($result.filterColumn)")
        foreach ($row in @($result.rows)) {
            $extraReport.Add(($row | ConvertTo-Json -Compress -Depth 10))
        }
        $extraReport.Add("")
    }
    Write-Utf8NoBomLf `
        -Path (Join-Path $resolvedOutputDirectory "product-extra-tables.txt") `
        -Content (($extraReport -join "`n") + "`n")

    Write-Host "Local exports written to: $resolvedOutputDirectory"
    Write-Host "Do not commit or share these files."
}
