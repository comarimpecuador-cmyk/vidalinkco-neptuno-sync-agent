[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$InstallPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$candidateExtensions = @(
    ".config", ".ini", ".xml", ".json", ".txt", ".rpt", ".frx", ".rdlc",
    ".mdb", ".accdb", ".dat", ".dbf", ".exe", ".dll"
)
$textExtensions = @(".config", ".ini", ".xml", ".json", ".txt", ".rpt", ".frx", ".rdlc")
$searchKeywords = @(
    "vademecum", "vademécum", "fa_vademecum", "fa_seccion_vademecum", "cabecera",
    "contenido", "indicaciones", "dosis", "contraindicaciones", "advertencias",
    "reacciones", "crystal", "report", "rpt", "compress", "decompress", "gzip",
    "zlib", "deflate", "image", "varbinary", "textcopy", "ole", "adodb", "sql",
    "stored procedure"
)
$binaryKeywords = @(
    "vademecum", "gzip", "zlib", "crystal", "fa_vademecum",
    "fa_seccion_vademecum", "cabecera", "contenido"
)

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Content.Replace("`r`n", "`n").Replace("`r", "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function ConvertTo-AuditCsv {
    param(
        [Parameter(Mandatory)]
        [string[]]$Headers,

        [Parameter()]
        [object[]]$Rows = @()
    )

    if ($Rows.Count -gt 0) {
        return (($Rows | ConvertTo-Csv -NoTypeInformation) -join "`n") + "`n"
    }

    $escapedHeaders = $Headers | ForEach-Object { '"' + $_.Replace('"', '""') + '"' }
    return ($escapedHeaders -join ",") + "`n"
}

function Get-RelativeAuditPath {
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,

        [Parameter(Mandatory)]
        [string]$FullName
    )

    $rootWithSeparator = $RootPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    return $FullName.Substring($rootWithSeparator.Length).Replace([System.IO.Path]::AltDirectorySeparatorChar, [System.IO.Path]::DirectorySeparatorChar)
}

function Get-NormalizedDirectoryPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::Equals($fullPath, $pathRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath
    }

    return $fullPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

function Get-InstallEntries {
    param(
        [Parameter(Mandatory)]
        [System.IO.DirectoryInfo]$Root
    )

    $results = [System.Collections.Generic.List[System.IO.FileSystemInfo]]::new()
    $pending = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
    $pending.Push($Root)

    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($entry in $directory.GetFileSystemInfos()) {
            $results.Add($entry)
            if ($entry -is [System.IO.DirectoryInfo] -and
                (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)) {
                $pending.Push([System.IO.DirectoryInfo]$entry)
            }
        }
    }

    return @($results.ToArray() | Sort-Object FullName)
}

function Protect-SecretText {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $secretNames = 'password|pwd|user\s*id|uid|server|licen[cs]e|serial|key|token'
    $sanitized = [regex]::Replace(
        $Text,
        "(?is)(<\s*(?:$secretNames)\b[^>]*>).*?(<\s*/\s*(?:$secretNames)\s*>)",
        '$1[REDACTED]$2'
    )
    $assignmentPattern = '(?i)((?:"|'')?(?:{0})(?:"|'')?\s*[:=]\s*)(?:"[^"]*"|''[^'']*''|[^;,\r\n]+)' -f $secretNames
    $sanitized = [regex]::Replace($sanitized, $assignmentPattern, '$1[REDACTED]')
    return $sanitized
}

function Get-ReadableTextEncoding {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $length = [Math]::Min(4096, [int]$stream.Length)
        $sample = [byte[]]::new($length)
        $read = $stream.Read($sample, 0, $length)
        if ($read -eq 0) {
            return [System.Text.UTF8Encoding]::new($false, $false)
        }

        if ($read -ge 3 -and $sample[0] -eq 0xEF -and $sample[1] -eq 0xBB -and $sample[2] -eq 0xBF) {
            return [System.Text.UTF8Encoding]::new($true, $false)
        }
        if ($read -ge 2 -and $sample[0] -eq 0xFF -and $sample[1] -eq 0xFE) {
            return [System.Text.Encoding]::Unicode
        }
        if ($read -ge 2 -and $sample[0] -eq 0xFE -and $sample[1] -eq 0xFF) {
            return [System.Text.Encoding]::BigEndianUnicode
        }

        $nullEven = 0
        $nullOdd = 0
        $controlBytes = 0
        for ($index = 0; $index -lt $read; $index++) {
            $value = $sample[$index]
            if ($value -eq 0) {
                if (($index % 2) -eq 0) { $nullEven++ } else { $nullOdd++ }
            }
            elseif ($value -lt 0x09 -or ($value -gt 0x0D -and $value -lt 0x20)) {
                $controlBytes++
            }
        }

        if ($nullOdd -gt ($read / 8) -and $nullEven -lt ($read / 32)) {
            return [System.Text.Encoding]::Unicode
        }
        if ($nullEven -gt ($read / 8) -and $nullOdd -lt ($read / 32)) {
            return [System.Text.Encoding]::BigEndianUnicode
        }
        if (($nullEven + $nullOdd) -gt 0 -or $controlBytes -gt ($read / 20)) {
            return $null
        }

        try {
            [void]([System.Text.UTF8Encoding]::new($false, $true).GetString($sample, 0, $read))
            return [System.Text.UTF8Encoding]::new($false, $false)
        }
        catch [System.Text.DecoderFallbackException] {
            return [System.Text.Encoding]::Default
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-KeywordMatchesFromTextFile {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory)]
        [string]$RelativePath,

        [Parameter(Mandatory)]
        [string[]]$Keywords
    )

    $encoding = Get-ReadableTextEncoding -Path $File.FullName
    if ($null -eq $encoding) {
        return @()
    }

    $matches = [System.Collections.Generic.List[string]]::new()
    $reader = [System.IO.StreamReader]::new($File.FullName, $encoding, $true)
    try {
        $lineNumber = 0
        while (-not $reader.EndOfStream) {
            $lineNumber++
            $line = Protect-SecretText -Text $reader.ReadLine()
            foreach ($keyword in $Keywords) {
                $match = [regex]::Match($line, [regex]::Escape($keyword), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if (-not $match.Success) {
                    continue
                }

                $start = [Math]::Max(0, $match.Index - 60)
                $available = [Math]::Min(220, $line.Length - $start)
                $fragment = [regex]::Replace($line.Substring($start, $available), '\s+', ' ').Trim()
                if ($fragment.Length -gt 160) {
                    $fragment = $fragment.Substring(0, 160)
                }
                $matches.Add("$RelativePath | $lineNumber | $keyword | $fragment")
            }
        }
    }
    finally {
        $reader.Dispose()
    }

    return $matches.ToArray()
}

function Test-BytePattern {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Buffer,

        [Parameter(Mandatory)]
        [int]$Count,

        [Parameter(Mandatory)]
        [byte[]]$Pattern
    )

    if ($Pattern.Length -eq 0 -or $Count -lt $Pattern.Length) {
        return $false
    }

    for ($start = 0; $start -le ($Count - $Pattern.Length); $start++) {
        $matched = $true
        for ($offset = 0; $offset -lt $Pattern.Length; $offset++) {
            $value = $Buffer[$start + $offset]
            if ($value -ge 0x41 -and $value -le 0x5A) {
                $value = $value + 0x20
            }
            if ($value -ne $Pattern[$offset]) {
                $matched = $false
                break
            }
        }
        if ($matched) {
            return $true
        }
    }

    return $false
}

function Get-BinaryKeywordHints {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string[]]$Keywords
    )

    $patterns = @{}
    $maximumPatternLength = 1
    foreach ($keyword in $Keywords) {
        $lower = $keyword.ToLowerInvariant()
        $patterns[$keyword] = @(
            [System.Text.Encoding]::ASCII.GetBytes($lower),
            [System.Text.Encoding]::Unicode.GetBytes($lower),
            [System.Text.Encoding]::BigEndianUnicode.GetBytes($lower)
        )
        foreach ($pattern in $patterns[$keyword]) {
            $maximumPatternLength = [Math]::Max($maximumPatternLength, $pattern.Length)
        }
    }

    $found = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $chunkSize = 65536
    $overlapLength = $maximumPatternLength - 1
    $buffer = [byte[]]::new($chunkSize + $overlapLength)
    $carry = 0
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        while (($read = $stream.Read($buffer, $carry, $chunkSize)) -gt 0) {
            $count = $carry + $read
            foreach ($keyword in $Keywords) {
                foreach ($pattern in $patterns[$keyword]) {
                    if (Test-BytePattern -Buffer $buffer -Count $count -Pattern $pattern) {
                        [void]$found.Add($keyword)
                        break
                    }
                }
            }

            $carry = [Math]::Min($overlapLength, $count)
            if ($carry -gt 0) {
                [System.Array]::Copy($buffer, $count - $carry, $buffer, 0, $carry)
            }
        }
    }
    finally {
        $stream.Dispose()
    }

    return @($Keywords | Where-Object { $found.Contains($_) })
}

$resolvedInstallPath = Get-NormalizedDirectoryPath -Path $InstallPath
$resolvedOutputDirectory = Get-NormalizedDirectoryPath -Path $OutputDirectory
if (-not [System.IO.Directory]::Exists($resolvedInstallPath)) {
    throw "InstallPath does not exist or is not a directory."
}

$installPrefix = $resolvedInstallPath + [System.IO.Path]::DirectorySeparatorChar
$outputIsInstall = [string]::Equals($resolvedOutputDirectory, $resolvedInstallPath, [System.StringComparison]::OrdinalIgnoreCase)
$outputIsInsideInstall = $resolvedOutputDirectory.StartsWith($installPrefix, [System.StringComparison]::OrdinalIgnoreCase)
if ($outputIsInstall -or $outputIsInsideInstall) {
    throw "OutputDirectory must be outside InstallPath to keep the installation read-only."
}

$root = [System.IO.DirectoryInfo]::new($resolvedInstallPath)
$entries = Get-InstallEntries -Root $root
$treeRows = [System.Collections.Generic.List[object]]::new()
$candidateRows = [System.Collections.Generic.List[object]]::new()
$binaryHintRows = [System.Collections.Generic.List[object]]::new()
$keywordMatches = [System.Collections.Generic.List[string]]::new()

foreach ($entry in $entries) {
    $isDirectory = $entry -is [System.IO.DirectoryInfo]
    $relativePath = Get-RelativeAuditPath -RootPath $resolvedInstallPath -FullName $entry.FullName
    $extension = if ($isDirectory) { "" } else { $entry.Extension.ToLowerInvariant() }
    $length = if ($isDirectory) { "" } else { ([System.IO.FileInfo]$entry).Length }
    $treeRows.Add([pscustomobject][ordered]@{
        RelativePath = $relativePath
        Extension = $extension
        Length = $length
        LastWriteTime = $entry.LastWriteTime.ToString("o")
        IsDirectory = $isDirectory
    })

    if ($isDirectory -or $candidateExtensions -notcontains $extension) {
        continue
    }

    $file = [System.IO.FileInfo]$entry
    $sha256 = ""
    if ($extension -in @(".exe", ".dll")) {
        $sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $candidateRows.Add([pscustomobject][ordered]@{
        RelativePath = $relativePath
        Extension = $extension
        Length = $file.Length
        LastWriteTime = $file.LastWriteTime.ToString("o")
        SHA256 = $sha256
    })

    if ($textExtensions -contains $extension) {
        foreach ($match in (Get-KeywordMatchesFromTextFile -File $file -RelativePath $relativePath -Keywords $searchKeywords)) {
            $keywordMatches.Add($match)
        }
    }

    if ($extension -in @(".exe", ".dll")) {
        $hints = @(Get-BinaryKeywordHints -Path $file.FullName -Keywords $binaryKeywords)
        if ($hints.Count -gt 0) {
            $binaryHintRows.Add([pscustomobject][ordered]@{
                RelativePath = $relativePath
                SHA256 = $sha256
                MatchedKeywords = $hints -join ";"
            })
        }
    }
}

$sqlAudit = @'
/* NEPTUNO SQL module and schema keyword audit. READ ONLY: SELECT statements only. */

SELECT
    SCHEMA_NAME(o.schema_id) AS SchemaName,
    o.name AS ObjectName,
    o.type_desc AS ObjectType,
    keyword.Keyword
FROM sys.objects AS o
INNER JOIN sys.sql_modules AS m ON m.object_id = o.object_id
CROSS APPLY (VALUES
    ('vademecum'), ('seccion'), ('cabecera'), ('contenido'), ('compress'),
    ('decompress'), ('convert'), ('cast'), ('image'), ('varbinary'),
    ('textptr'), ('readtext')
) AS keyword(Keyword)
WHERE LOWER(COALESCE(m.definition, '')) LIKE '%' + keyword.Keyword + '%'
ORDER BY SchemaName, ObjectName, keyword.Keyword;

SELECT
    'TABLE' AS ObjectCategory,
    SCHEMA_NAME(t.schema_id) AS SchemaName,
    t.name AS ObjectName,
    c.name AS ColumnName,
    TYPE_NAME(c.user_type_id) AS DataType,
    keyword.Keyword
FROM sys.tables AS t
INNER JOIN sys.columns AS c ON c.object_id = t.object_id
CROSS APPLY (VALUES
    ('vademecum'), ('seccion'), ('cabecera'), ('contenido'), ('compress'),
    ('decompress'), ('convert'), ('cast'), ('image'), ('varbinary'),
    ('textptr'), ('readtext')
) AS keyword(Keyword)
WHERE LOWER(t.name) LIKE '%' + keyword.Keyword + '%'
   OR LOWER(c.name) LIKE '%' + keyword.Keyword + '%'
   OR LOWER(TYPE_NAME(c.user_type_id)) LIKE '%' + keyword.Keyword + '%'
UNION ALL
SELECT
    'VIEW' AS ObjectCategory,
    SCHEMA_NAME(v.schema_id) AS SchemaName,
    v.name AS ObjectName,
    c.name AS ColumnName,
    TYPE_NAME(c.user_type_id) AS DataType,
    keyword.Keyword
FROM sys.views AS v
INNER JOIN sys.columns AS c ON c.object_id = v.object_id
CROSS APPLY (VALUES
    ('vademecum'), ('seccion'), ('cabecera'), ('contenido'), ('compress'),
    ('decompress'), ('convert'), ('cast'), ('image'), ('varbinary'),
    ('textptr'), ('readtext')
) AS keyword(Keyword)
WHERE LOWER(v.name) LIKE '%' + keyword.Keyword + '%'
   OR LOWER(c.name) LIKE '%' + keyword.Keyword + '%'
   OR LOWER(TYPE_NAME(c.user_type_id)) LIKE '%' + keyword.Keyword + '%'
ORDER BY ObjectCategory, SchemaName, ObjectName, ColumnName, Keyword;
'@

[System.IO.Directory]::CreateDirectory($resolvedOutputDirectory) | Out-Null
Write-Utf8NoBom -Path (Join-Path $resolvedOutputDirectory "install-tree.csv") -Content (ConvertTo-AuditCsv -Headers @("RelativePath", "Extension", "Length", "LastWriteTime", "IsDirectory") -Rows $treeRows.ToArray())
Write-Utf8NoBom -Path (Join-Path $resolvedOutputDirectory "candidate-files.csv") -Content (ConvertTo-AuditCsv -Headers @("RelativePath", "Extension", "Length", "LastWriteTime", "SHA256") -Rows $candidateRows.ToArray())

$keywordHeader = "RelativePath | Line | Keyword | Fragment`n"
$keywordContent = if ($keywordMatches.Count -eq 0) { $keywordHeader } else { $keywordHeader + (($keywordMatches.ToArray() -join "`n") + "`n") }
Write-Utf8NoBom -Path (Join-Path $resolvedOutputDirectory "keyword-search.txt") -Content $keywordContent
Write-Utf8NoBom -Path (Join-Path $resolvedOutputDirectory "binary-keyword-hints.csv") -Content (ConvertTo-AuditCsv -Headers @("RelativePath", "SHA256", "MatchedKeywords") -Rows $binaryHintRows.ToArray())
Write-Utf8NoBom -Path (Join-Path $resolvedOutputDirectory "sql-modules-vademecum-audit.sql") -Content ($sqlAudit + "`n")

Write-Host "NEPTUNO installation audit completed (read-only source scan)."
Write-Host "Entries inventoried: $($treeRows.Count)"
Write-Host "Candidate files: $($candidateRows.Count)"
Write-Host "Sanitized text matches: $($keywordMatches.Count)"
Write-Host "Binaries with keyword hints: $($binaryHintRows.Count)"
Write-Host "Audit output: $resolvedOutputDirectory"
Write-Host "Do not commit, upload or share generated evidence without authorized review."
