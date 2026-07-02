[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) "exports/neptuno-production-wrapper-smoke")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent $PSScriptRoot
$wrapperSourcePath = Join-Path $PSScriptRoot "run-neptuno-sync-production.ps1"
$resolvedOutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$sandboxRoot = Join-Path $resolvedOutputDirectory "sandbox"
$sandboxScripts = Join-Path $sandboxRoot "scripts"
$sandboxConfigDirectory = Join-Path $sandboxRoot "Vidalinkco.NeptunoSyncAgent"
$wrapperPath = Join-Path $sandboxScripts "run-neptuno-sync-production.ps1"
$stubPath = Join-Path $sandboxScripts "sync-neptuno-catalog.ps1"
$configPath = Join-Path $sandboxConfigDirectory "appsettings.local.json"
$capturePath = Join-Path $sandboxRoot "capture.json"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Write-TestConfiguration {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$ApiKey
    )

    $value = [ordered]@{
        NeptunoSyncAgent = [ordered]@{
            VidalinkcoBaseUrl = $BaseUrl
            ApiKey = $ApiKey
        }
    } | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($configPath, $value + "`n", $utf8NoBom)
}

if ([System.IO.Directory]::Exists($sandboxRoot)) {
    Remove-Item -LiteralPath $sandboxRoot -Recurse -Force
}
[System.IO.Directory]::CreateDirectory($sandboxScripts) | Out-Null
[System.IO.Directory]::CreateDirectory($sandboxConfigDirectory) | Out-Null
Copy-Item -LiteralPath $wrapperSourcePath -Destination $wrapperPath

$stubScript = @'
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [long]$BodegaId,
    [string]$Mode,
    [string]$Eligibility,
    [string]$RunType,
    [int]$BatchSize,
    [int]$CommandTimeoutSeconds,
    [string]$ApiUrl,
    [string]$ApiToken,
    [int]$MaxSendItems,
    [string[]]$ExternalIds,
    [switch]$DryRun,
    [switch]$Send
)

$capture = [ordered]@{
    outputDirectory = $OutputDirectory
    bodegaId = $BodegaId
    mode = $Mode
    eligibility = $Eligibility
    runType = $RunType
    batchSize = $BatchSize
    commandTimeoutSeconds = $CommandTimeoutSeconds
    apiUrl = $ApiUrl
    apiTokenAccepted = $ApiToken -eq "smoke-secret-not-production"
    maxSendItems = $MaxSendItems
    externalIds = @($ExternalIds)
    dryRun = [bool]$DryRun
    send = [bool]$Send
}
$capture | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) "capture.json") -Encoding UTF8
Write-Host "Synthetic sync stub completed."
'@
[System.IO.File]::WriteAllText($stubPath, $stubScript + "`n", $utf8NoBom)

Write-TestConfiguration -BaseUrl "https://sync-smoke.invalid" -ApiKey "smoke-secret-not-production"
$sendOutput = & $wrapperPath 6>&1 | Out-String
$sendCapture = Get-Content -Raw -LiteralPath $capturePath -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition ($sendCapture.send -eq $true -and $sendCapture.dryRun -eq $false) -Message "Wrapper did not use Send by default."
Assert-True -Condition ($sendCapture.maxSendItems -eq 1000) -Message "Wrapper MaxSendItems default changed."
Assert-True -Condition ($sendOutput -notmatch "smoke-secret-not-production") -Message "Wrapper exposed the token during send dispatch."

$validOutput = & $wrapperPath -DryRun -ExternalIds 9102 -MaxSendItems 321 6>&1 | Out-String
$capture = Get-Content -Raw -LiteralPath $capturePath -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition ($capture.outputDirectory -eq ".\exports\neptuno-sync") -Message "Wrapper output directory contract changed."
Assert-True -Condition ($capture.bodegaId -eq 1 -and $capture.mode -eq "All") -Message "Wrapper mode or bodega contract changed."
Assert-True -Condition ($capture.eligibility -eq "ActiveSellableWithStock" -and $capture.runType -eq "Incremental") -Message "Wrapper eligibility or run type contract changed."
Assert-True -Condition ($capture.batchSize -eq 500 -and $capture.commandTimeoutSeconds -eq 120) -Message "Wrapper batch or timeout contract changed."
Assert-True -Condition ($capture.apiUrl -eq "https://sync-smoke.invalid/api/integrations/neptuno/sync") -Message "Wrapper API URL composition failed."
Assert-True -Condition ($capture.apiTokenAccepted -eq $true -and $validOutput -notmatch "smoke-secret-not-production") -Message "Wrapper token handling is unsafe."
Assert-True -Condition ($capture.maxSendItems -eq 321) -Message "Wrapper MaxSendItems forwarding failed."
Assert-True -Condition ($capture.dryRun -eq $true -and $capture.send -eq $false) -Message "Wrapper dry-run attempted send."
Assert-True -Condition (@($capture.externalIds).Count -eq 1 -and $capture.externalIds[0] -eq "9102") -Message "Wrapper ExternalIds 9102 forwarding failed."

Write-TestConfiguration -BaseUrl "https://vidalinkco.example.com" -ApiKey "smoke-secret-not-production"
$exampleDomainRejected = $false
try {
    & $wrapperPath -DryRun 6>&1 | Out-Null
}
catch {
    $exampleDomainRejected = $_.Exception.Message -match "vidalinkco\.example\.com"
}
Assert-True -Condition $exampleDomainRejected -Message "Wrapper accepted vidalinkco.example.com."

Write-TestConfiguration -BaseUrl "https://sync-smoke.invalid" -ApiKey "replace-with-local-api-key-only"
$placeholderRejected = $false
try {
    & $wrapperPath -DryRun 6>&1 | Out-Null
}
catch {
    $placeholderRejected = $_.Exception.Message -match "placeholder"
}
Assert-True -Condition $placeholderRejected -Message "Wrapper accepted the ApiKey placeholder."

Write-Host "NEPTUNO production wrapper smoke passed."
Write-Host "Valid local configuration: OK"
Write-Host "Example domain rejection: OK"
Write-Host "ApiKey placeholder rejection: OK"
Write-Host "ExternalIds 9102 dry-run: OK"
Write-Host "Token output isolation: OK"
Write-Host "Smoke evidence root: $resolvedOutputDirectory"
