using System.Text.Json.Serialization;

namespace Vidalinkco.NeptunoSyncAgent.Contracts;

public sealed record HeartbeatPayload(
    [property: JsonPropertyName("agentId")] string AgentId,
    [property: JsonPropertyName("source")] string Source,
    [property: JsonPropertyName("machineName")] string MachineName,
    [property: JsonPropertyName("version")] string Version,
    [property: JsonPropertyName("occurredAtUtc")] DateTimeOffset OccurredAtUtc,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("mode")] string Mode,
    [property: JsonPropertyName("dryRun")] bool DryRun,
    [property: JsonPropertyName("batchSize")] int BatchSize,
    [property: JsonPropertyName("intervals")] HeartbeatIntervals Intervals,
    [property: JsonPropertyName("capabilities")] AgentCapabilities Capabilities,
    [property: JsonPropertyName("runtime")] AgentRuntime Runtime);

public sealed record HeartbeatIntervals(
    [property: JsonPropertyName("heartbeatSeconds")] int HeartbeatSeconds,
    [property: JsonPropertyName("stockSyncSeconds")] int StockSyncSeconds);

public sealed record AgentCapabilities(
    [property: JsonPropertyName("heartbeat")] bool Heartbeat,
    [property: JsonPropertyName("stockPriceFuture")] bool StockPriceFuture,
    [property: JsonPropertyName("catalogFuture")] bool CatalogFuture,
    [property: JsonPropertyName("csvImportFuture")] bool CsvImportFuture,
    [property: JsonPropertyName("sqlServerEnabled")] bool SqlServerEnabled);

public sealed record AgentRuntime(
    [property: JsonPropertyName("osDescription")] string OsDescription,
    [property: JsonPropertyName("processArchitecture")] string ProcessArchitecture,
    [property: JsonPropertyName("dotnetVersion")] string DotnetVersion);

public sealed record HeartbeatResponse(
    [property: JsonPropertyName("acceptedAtUtc")] DateTimeOffset? AcceptedAtUtc,
    [property: JsonPropertyName("message")] string? Message);

public sealed record VidalinkcoEnvelope<T>(
    [property: JsonPropertyName("ok")] bool Ok,
    [property: JsonPropertyName("data")] T? Data,
    [property: JsonPropertyName("error")] string? Error);
