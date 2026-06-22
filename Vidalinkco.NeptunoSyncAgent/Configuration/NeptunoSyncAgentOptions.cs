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

    public int StockSyncIntervalSeconds { get; set; } = 900;

    public int BatchSize { get; set; } = 100;

    public string LogDirectory { get; set; } = "logs";

    public string EffectiveMachineName =>
        string.IsNullOrWhiteSpace(MachineName) ? Environment.MachineName : MachineName.Trim();

    public void ValidateForHeartbeat()
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

        if (BatchSize is < 1 or > 500)
        {
            throw new InvalidOperationException("NeptunoSyncAgent:BatchSize must be between 1 and 500.");
        }

        if (HeartbeatIntervalSeconds < 10)
        {
            throw new InvalidOperationException("NeptunoSyncAgent:HeartbeatIntervalSeconds must be at least 10.");
        }

        if (StockSyncIntervalSeconds < 60)
        {
            throw new InvalidOperationException("NeptunoSyncAgent:StockSyncIntervalSeconds must be at least 60.");
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
