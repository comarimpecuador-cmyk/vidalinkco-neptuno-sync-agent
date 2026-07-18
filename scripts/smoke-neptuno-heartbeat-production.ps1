[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot "exports/neptuno-heartbeat-wrapper-smoke"
}
$sandboxRoot = Join-Path ([System.IO.Path]::GetFullPath($OutputDirectory)) "sandbox"
$sandboxScripts = Join-Path $sandboxRoot "scripts"
$sandboxProject = Join-Path $sandboxRoot "Vidalinkco.NeptunoSyncAgent"
$sandboxLatest = Join-Path $sandboxRoot "exports/neptuno-sync/latest"
$capturePath = Join-Path $sandboxRoot "capture.json"
$wrapperPath = Join-Path $sandboxScripts "run-neptuno-heartbeat-production.ps1"
$launcherSourcePath = Join-Path $PSScriptRoot "run-neptuno-heartbeat-production.vbs"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

if ([System.IO.Directory]::Exists($sandboxRoot)) {
    Remove-Item -LiteralPath $sandboxRoot -Recurse -Force
}
[System.IO.Directory]::CreateDirectory($sandboxScripts) | Out-Null
[System.IO.Directory]::CreateDirectory($sandboxProject) | Out-Null
[System.IO.Directory]::CreateDirectory($sandboxLatest) | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "run-neptuno-heartbeat-production.ps1") -Destination $wrapperPath
[System.IO.File]::WriteAllText((Join-Path $sandboxProject "Vidalinkco.NeptunoSyncAgent.csproj"), "<Project />`n", $utf8NoBom)

Assert-True ([System.IO.File]::Exists($launcherSourcePath)) "Heartbeat VBS launcher source is missing."
$launcherSource = Get-Content -Raw -LiteralPath $launcherSourcePath
Assert-True ($launcherSource -match "run-neptuno-heartbeat-production\.ps1" -and $launcherSource -match "-WindowStyle Hidden" -and $launcherSource -match "WScript\.Quit exitCode") "Heartbeat VBS launcher does not hide PowerShell and return exit code."

$configuration = [ordered]@{
    NeptunoSyncAgent = [ordered]@{
        VidalinkcoBaseUrl = "https://heartbeat-smoke.invalid"
        ApiKey = "smoke-heartbeat-secret-not-production"
    }
} | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText((Join-Path $sandboxProject "appsettings.local.json"), $configuration + "`n", $utf8NoBom)

$summary = [ordered]@{
    sourceKey = "neptuno-farmacia-universal"
    syncRunId = "smoke-run-1"
    completedAt = "2026-07-02T15:00:00Z"
    sendStatus = "no-changes"
    catalogItems = 50000
    liveItems = 1200
    changedCatalogItems = 0
    changedLiveItems = 0
    quarantinedItems = 0
    warnings = 0
} | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText((Join-Path $sandboxLatest "sync-summary.json"), $summary + "`n", $utf8NoBom)

function global:dotnet {
    $capture = [ordered]@{
        arguments = @($args)
        baseUrl = $env:NeptunoSyncAgent__VidalinkcoBaseUrl
        tokenConfigured = $env:NeptunoSyncAgent__ApiKey -eq "smoke-heartbeat-secret-not-production"
        summaryPath = $env:NeptunoSyncAgent__SyncSummaryPath
        dryRun = $env:NeptunoSyncAgent__DryRun
    }
    $capture | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $capturePath -Encoding UTF8
    $global:LASTEXITCODE = 0
    Write-Output "Synthetic heartbeat runner completed."
}

try {
    $output = & $wrapperPath -DryRun 6>&1 | Out-String
}
finally {
    Remove-Item Function:\global:dotnet -ErrorAction SilentlyContinue
}

$capture = Get-Content -Raw -LiteralPath $capturePath -Encoding UTF8 | ConvertFrom-Json
Assert-True ($capture.tokenConfigured -eq $true) "Wrapper did not pass the token through process environment."
Assert-True ($capture.dryRun -eq "true") "Wrapper did not enable dry-run."
Assert-True ($capture.summaryPath -eq [System.IO.Path]::GetFullPath((Join-Path $sandboxLatest "sync-summary.json"))) "Wrapper did not use latest sync-summary.json."
Assert-True (@($capture.arguments) -contains "--heartbeat-once") "Wrapper did not invoke lightweight heartbeat mode."
Assert-True ($output -notmatch "smoke-heartbeat-secret-not-production") "Wrapper exposed the token in output."

Write-Host "NEPTUNO heartbeat production wrapper smoke passed."
Write-Host "Latest summary forwarding: OK"
Write-Host "No SQL/full sync invocation: OK"
Write-Host "Hidden VBS launcher contract: OK"
Write-Host "Token output isolation: OK"
