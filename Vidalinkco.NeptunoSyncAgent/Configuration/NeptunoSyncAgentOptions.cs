namespace Vidalinkco.NeptunoSyncAgent.Configuration;

public sealed class NeptunoSyncAgentOptions
{
    public const string SectionName = "NeptunoSyncAgent";

    public string VidalinkcoBaseUrl { get; set; } = "https://vidalinkco.example.com";

    public string ApiKey { get; set; } = string.Empty;

    public string Source { get; set; } = "neptuno";

    public string AgentId { get; set; } = "neptuno-agent-example";

    public string MachineName { get; set; } = string.Empty;

    public string Version { get; set; } = "0.1.0";

    public bool DryRun { get; set; } = true;

    public int HeartbeatIntervalSeconds { get; set; } = 300;

    public string SyncSummaryPath { get; set; } = "exports/neptuno-sync/latest/sync-summary.json";

    public int StockSyncIntervalSeconds { get; set; } = 900;

    public int BatchSize { get; set; } = 100;

    public string StockPriceCsvPath { get; set; } = "samples/stock-price.csv";

    public int MaxRows { get; set; } = 1000;

    public int SendBatchSize { get; set; } = 100;

    public int StockPriceDryRunLimit { get; set; } = 10;

    public string CatalogCsvPath { get; set; } = "samples/catalog.csv";

    public int CatalogMaxRows { get; set; } = 1000;

    public int CatalogSendBatchSize { get; set; } = 100;

    public int CatalogDryRunLimit { get; set; } = 5;

    public string LogDirectory { get; set; } = "logs";

    public string EffectiveMachineName =>
        string.IsNullOrWhiteSpace(MachineName) ? Environment.MachineName : MachineName.Trim();

    public void ValidateForHeartbeat()
    {
        ValidateCommon();

        if (BatchSize is < 1 or > 500)
        {
            throw new InvalidOperationException("NeptunoSyncAgent:BatchSize must be between 1 and 500.");
        }

        if (HeartbeatIntervalSeconds < 10)
        {
            throw new InvalidOperationException("NeptunoSyncAgent:HeartbeatIntervalSeconds must be at least 10.");
        }

        if (string.IsNullOrWhiteSpace(SyncSummaryPath))
        {
            throw new InvalidOperationException("NeptunoSyncAgent:SyncSummaryPath is required.");
        }

        if (StockSyncIntervalSeconds < 60)
        {
            throw new InvalidOperationException("NeptunoSyncAgent:StockSyncIntervalSeconds must be at least 60.");
        }
    }

    public void ValidateForStockPriceCsv()
    {
        ValidateCommon();

        if (string.IsNullOrWhiteSpace(StockPriceCsvPath))
        {
            throw new InvalidOperationException("NeptunoSyncAgent:StockPriceCsvPath is required.");
        }

        if (MaxRows is < 1 or > 100000)
        {
            throw new InvalidOperationException("NeptunoSyncAgent:MaxRows must be between 1 and 100000.");
        }

        if (SendBatchSize is < 1 or > 500)
        {
            throw new InvalidOperationException("NeptunoSyncAgent:SendBatchSize must be between 1 and 500.");
        }

        if (StockPriceDryRunLimit is < 1 or > 100)
        {
            throw new InvalidOperationException("NeptunoSyncAgent:StockPriceDryRunLimit must be between 1 and 100.");
        }
    }

    public void ValidateForCatalogCsv()
    {
        ValidateCommon();

        if (string.IsNullOrWhiteSpace(CatalogCsvPath))
        {
            throw new InvalidOperationException("NeptunoSyncAgent:CatalogCsvPath is required.");
        }

        if (CatalogMaxRows is < 1 or > 100000)
        {
            throw new InvalidOperationException("NeptunoSyncAgent:CatalogMaxRows must be between 1 and 100000.");
        }

        if (CatalogSendBatchSize is < 1 or > 500)
        {
            throw new InvalidOperationException("NeptunoSyncAgent:CatalogSendBatchSize must be between 1 and 500.");
        }

        if (CatalogDryRunLimit is < 1 or > 100)
        {
            throw new InvalidOperationException("NeptunoSyncAgent:CatalogDryRunLimit must be between 1 and 100.");
        }
    }

    private void ValidateCommon()
    {
        if (string.IsNullOrWhiteSpace(Source))
        {
            throw new InvalidOperationException("NeptunoSyncAgent:Source is required.");
        }

        if (!string.Equals(Source, "neptuno", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("NeptunoSyncAgent:Source must be 'neptuno' for this agent.");
        }

        if (string.IsNullOrWhiteSpace(AgentId))
        {
            throw new InvalidOperationException("NeptunoSyncAgent:AgentId is required.");
        }

        if (!DryRun && string.IsNullOrWhiteSpace(ApiKey))
        {
            throw new InvalidOperationException("NeptunoSyncAgent:ApiKey is required when DryRun is false.");
        }

        if (!Uri.TryCreate(VidalinkcoBaseUrl, UriKind.Absolute, out var baseUri) ||
            baseUri.Scheme != Uri.UriSchemeHttps)
        {
            throw new InvalidOperationException("NeptunoSyncAgent:VidalinkcoBaseUrl must be an absolute HTTPS URL.");
        }
    }
}
