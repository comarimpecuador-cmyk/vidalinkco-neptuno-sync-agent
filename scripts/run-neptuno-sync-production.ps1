[CmdletBinding()]
param(
    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [AllowNull()]
    [AllowEmptyCollection()]
    [string[]]$ExternalIds,

    [Parameter()]
    [ValidateRange(1, 1000)]
    [int]$MaxSendItems = 1000,

    [Parameter()]
    [switch]$InitialBaseline,

    [Parameter()]
    [ValidateRange(1, 1000)]
    [int]$ChunkSize = 500,

    [Parameter()]
    [switch]$Resume
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $repoRoot "Vidalinkco.NeptunoSyncAgent/appsettings.local.json"
$syncScriptPath = Join-Path $PSScriptRoot "sync-neptuno-catalog.ps1"

if ($InitialBaseline -and $DryRun) {
    throw "Use InitialBaseline for chunked send or DryRun for validation, not both."
}
if ($InitialBaseline -and $null -ne $ExternalIds -and @($ExternalIds).Count -gt 0) {
    throw "InitialBaseline requires the complete dataset and does not accept ExternalIds."
}
if ($Resume -and -not $InitialBaseline) {
    throw "Resume is exposed by the production wrapper only for InitialBaseline."
}

if (-not [System.IO.File]::Exists($configPath)) {
    throw "Required local configuration was not found: $configPath"
}
if (-not [System.IO.File]::Exists($syncScriptPath)) {
    throw "NEPTUNO sync script was not found: $syncScriptPath"
}

try {
    $configuration = Get-Content -Raw -LiteralPath $configPath -Encoding UTF8 | ConvertFrom-Json
}
catch {
    throw "Could not read a valid JSON configuration from '$configPath'."
}

$agentConfiguration = $configuration.PSObject.Properties["NeptunoSyncAgent"]
if ($null -eq $agentConfiguration -or $null -eq $agentConfiguration.Value) {
    throw "Configuration section 'NeptunoSyncAgent' is required in '$configPath'."
}

$baseUrlProperty = $agentConfiguration.Value.PSObject.Properties["VidalinkcoBaseUrl"]
$apiKeyProperty = $agentConfiguration.Value.PSObject.Properties["ApiKey"]
$baseUrl = if ($null -eq $baseUrlProperty) { "" } else { [string]$baseUrlProperty.Value }
$apiToken = if ($null -eq $apiKeyProperty) { "" } else { [string]$apiKeyProperty.Value }
$baseUrl = $baseUrl.Trim()
$apiToken = $apiToken.Trim()

$baseUri = $null
if ([string]::IsNullOrWhiteSpace($baseUrl) -or
    -not [uri]::TryCreate($baseUrl, [System.UriKind]::Absolute, [ref]$baseUri) -or
    $baseUri.Scheme -ne "https") {
    throw "NeptunoSyncAgent.VidalinkcoBaseUrl must be an absolute HTTPS URL."
}
if ([string]::Equals($baseUri.Host, "vidalinkco.example.com", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "NeptunoSyncAgent.VidalinkcoBaseUrl must not use vidalinkco.example.com."
}
if ([string]::IsNullOrWhiteSpace($apiToken)) {
    throw "NeptunoSyncAgent.ApiKey is required."
}
if ([string]::Equals($apiToken, "replace-with-local-api-key-only", [System.StringComparison]::Ordinal)) {
    throw "NeptunoSyncAgent.ApiKey still contains the local placeholder."
}

$apiUrl = $baseUri.AbsoluteUri.TrimEnd('/') + "/api/integrations/neptuno/sync"
$syncArguments = @{
    OutputDirectory = ".\exports\neptuno-sync"
    BodegaId = 1
    Mode = "All"
    Eligibility = "ActiveSellableWithStock"
    RunType = "Incremental"
    BatchSize = 500
    CommandTimeoutSeconds = 120
    ApiUrl = $apiUrl
    ApiToken = $apiToken
    MaxSendItems = $MaxSendItems
}

if ($null -ne $ExternalIds -and @($ExternalIds).Count -gt 0) {
    $syncArguments["ExternalIds"] = $ExternalIds
}
if ($DryRun) {
    $syncArguments["DryRun"] = $true
}
else {
    $syncArguments["Send"] = $true
}
if ($InitialBaseline) {
    $syncArguments["InitialBaseline"] = $true
    $syncArguments["ChunkSize"] = $ChunkSize
}
if ($Resume) {
    $syncArguments["Resume"] = $true
}

Push-Location -LiteralPath $repoRoot
try {
    & $syncScriptPath @syncArguments
}
finally {
    Pop-Location
}
