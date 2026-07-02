[CmdletBinding()]
param(
    [Parameter()]
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $repoRoot "Vidalinkco.NeptunoSyncAgent/appsettings.local.json"
$projectPath = Join-Path $repoRoot "Vidalinkco.NeptunoSyncAgent/Vidalinkco.NeptunoSyncAgent.csproj"
$summaryPath = Join-Path $repoRoot "exports/neptuno-sync/latest/sync-summary.json"

if (-not [System.IO.File]::Exists($configPath)) {
    throw "Required local configuration was not found: $configPath"
}
if (-not [System.IO.File]::Exists($projectPath)) {
    throw "NEPTUNO sync agent project was not found: $projectPath"
}
if (-not [System.IO.File]::Exists($summaryPath)) {
    throw "Latest NEPTUNO sync summary was not found: $summaryPath"
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

$environmentNames = @(
    "NeptunoSyncAgent__VidalinkcoBaseUrl",
    "NeptunoSyncAgent__ApiKey",
    "NeptunoSyncAgent__SyncSummaryPath",
    "NeptunoSyncAgent__DryRun"
)
$previousEnvironment = @{}
foreach ($name in $environmentNames) {
    $previousEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name, "Process")
}

try {
    $env:NeptunoSyncAgent__VidalinkcoBaseUrl = $baseUrl
    $env:NeptunoSyncAgent__ApiKey = $apiToken
    $env:NeptunoSyncAgent__SyncSummaryPath = [System.IO.Path]::GetFullPath($summaryPath)
    $env:NeptunoSyncAgent__DryRun = if ($DryRun) { "true" } else { "false" }

    $dotnetArguments = @("run", "--project", $projectPath, "--", "--heartbeat-once")
    if ($DryRun) {
        $dotnetArguments += "--dry-run"
    }

    Push-Location -LiteralPath $repoRoot
    try {
        & dotnet @dotnetArguments
        if ($LASTEXITCODE -ne 0) {
            throw "NEPTUNO heartbeat process failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    foreach ($name in $environmentNames) {
        [System.Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], "Process")
    }
}
