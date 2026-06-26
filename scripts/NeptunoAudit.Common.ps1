Set-StrictMode -Version 2.0

Add-Type -AssemblyName System.Data

function New-NeptunoReadOnlyConnection {
    param(
        [Parameter(Mandatory)]
        [string]$Server,

        [Parameter(Mandatory)]
        [string]$Database,

        [Parameter(Mandatory)]
        [string]$ApplicationName
    )

    $connectionString = "Data Source=$Server;Initial Catalog=$Database;Integrated Security=True;Encrypt=False;ApplicationIntent=ReadOnly;Connect Timeout=15;Application Name=$ApplicationName"
    return New-Object System.Data.SqlClient.SqlConnection($connectionString)
}

function Invoke-NeptunoQuery {
    param(
        [Parameter(Mandatory)]
        [System.Data.SqlClient.SqlConnection]$Connection,

        [Parameter(Mandatory)]
        [string]$Query,

        [Parameter()]
        [hashtable]$Parameters = @{},

        [Parameter()]
        [int]$CommandTimeout = 60
    )

    $command = $Connection.CreateCommand()
    $command.CommandText = $Query
    $command.CommandTimeout = $CommandTimeout

    foreach ($entry in $Parameters.GetEnumerator()) {
        $parameter = $command.Parameters.AddWithValue("@$($entry.Key)", $entry.Value)
        if ($null -eq $entry.Value) {
            $parameter.Value = [DBNull]::Value
        }
    }

    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command
    $table = New-Object System.Data.DataTable
    try {
        [void]$adapter.Fill($table)
        return ,$table
    }
    finally {
        $adapter.Dispose()
        $command.Dispose()
    }
}

function Test-NeptunoTable {
    param(
        [Parameter(Mandatory)]
        [System.Data.SqlClient.SqlConnection]$Connection,

        [Parameter(Mandatory)]
        [string]$TableName
    )

    $result = Invoke-NeptunoQuery -Connection $Connection -Query @"
SELECT CASE WHEN OBJECT_ID(@TableName, 'U') IS NULL THEN 0 ELSE 1 END AS tableExists;
"@ -Parameters @{ TableName = $TableName }

    return [int]$result.Rows[0]["tableExists"] -eq 1
}

function Get-NeptunoTableColumns {
    param(
        [Parameter(Mandatory)]
        [System.Data.SqlClient.SqlConnection]$Connection,

        [Parameter(Mandatory)]
        [string]$TableName
    )

    return Invoke-NeptunoQuery -Connection $Connection -Query @"
SELECT
    c.column_id AS columnId,
    c.name AS columnName,
    ty.name AS dataType,
    c.max_length AS maxLength,
    c.is_nullable AS isNullable
FROM sys.columns c
JOIN sys.types ty
    ON ty.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID(@TableName, 'U')
ORDER BY c.column_id;
"@ -Parameters @{ TableName = $TableName }
}

function ConvertFrom-NeptunoDataTable {
    param(
        [Parameter(Mandatory)]
        [System.Data.DataTable]$Table
    )

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $Table.Rows) {
        $value = [ordered]@{}
        foreach ($column in $Table.Columns) {
            $rawValue = $row[$column.ColumnName]
            if ($rawValue -is [DBNull]) {
                $value[$column.ColumnName] = $null
            }
            elseif ($rawValue -is [byte[]]) {
                $value[$column.ColumnName] = [ordered]@{
                    binary = $true
                    bytes = $rawValue.Length
                }
            }
            else {
                $value[$column.ColumnName] = $rawValue
            }
        }
        $items.Add([pscustomobject]$value)
    }

    return $items.ToArray()
}

function Get-NeptunoRowsByReference {
    param(
        [Parameter(Mandatory)]
        [System.Data.SqlClient.SqlConnection]$Connection,

        [Parameter(Mandatory)]
        [string]$TableName,

        [Parameter(Mandatory)]
        [long]$ReferenceId,

        [Parameter()]
        [string[]]$CandidateColumns = @("id_producto", "id_item"),

        [Parameter()]
        [int]$Top = 200
    )

    if (-not (Test-NeptunoTable -Connection $Connection -TableName $TableName)) {
        return [pscustomobject]@{
            table = $TableName
            status = "missing"
            filterColumn = $null
            rows = @()
        }
    }

    $columns = Get-NeptunoTableColumns -Connection $Connection -TableName $TableName
    $columnNames = @($columns.Rows | ForEach-Object { [string]$_["columnName"] })
    $filterColumn = $CandidateColumns | Where-Object { $columnNames -contains $_ } | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($filterColumn)) {
        return [pscustomobject]@{
            table = $TableName
            status = "no-direct-reference"
            filterColumn = $null
            rows = @()
        }
    }

    $safeTable = "[" + $TableName.Replace("]", "]]") + "]"
    $safeColumn = "[" + $filterColumn.Replace("]", "]]") + "]"
    $selectColumns = @(
        $columns.Rows | ForEach-Object {
            $columnName = [string]$_["columnName"]
            $dataType = [string]$_["dataType"]
            $quotedColumn = "[" + $columnName.Replace("]", "]]") + "]"
            if ($dataType -in @("binary", "varbinary", "image")) {
                "DATALENGTH($quotedColumn) AS [" + $columnName.Replace("]", "]]") + "_bytes]"
            }
            elseif ($dataType -in @("text", "ntext")) {
                "LEFT(CONVERT(nvarchar(max), $quotedColumn), 4000) AS $quotedColumn"
            }
            else {
                $quotedColumn
            }
        }
    )
    $query = "SELECT TOP ($Top) " + ($selectColumns -join ", ") + " FROM $safeTable WHERE $safeColumn = @ReferenceId ORDER BY $safeColumn;"
    $data = Invoke-NeptunoQuery -Connection $Connection -Query $query -Parameters @{ ReferenceId = $ReferenceId }

    return [pscustomobject]@{
        table = $TableName
        status = "ok"
        filterColumn = $filterColumn
        rows = @(ConvertFrom-NeptunoDataTable -Table $data)
    }
}

function Write-Utf8NoBomLf {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }

    $normalized = $Content.Replace("`r`n", "`n").Replace("`r", "`n")
    [System.IO.File]::WriteAllText(
        [System.IO.Path]::GetFullPath($Path),
        $normalized,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Export-Utf8NoBomCsv {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [object[]]$InputObject = @()
    )

    if ($InputObject.Count -eq 0) {
        Write-Utf8NoBomLf -Path $Path -Content ""
        return
    }

    $csv = $InputObject | ConvertTo-Csv -NoTypeInformation
    Write-Utf8NoBomLf -Path $Path -Content (($csv -join "`n") + "`n")
}

function ConvertTo-DisplayValue {
    param(
        [Parameter()]
        $Value
    )

    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [DateTime]) {
        return $Value.ToString("o")
    }

    if ($Value -is [System.Collections.IDictionary]) {
        return ($Value | ConvertTo-Json -Compress -Depth 8)
    }

    return [string]$Value
}
