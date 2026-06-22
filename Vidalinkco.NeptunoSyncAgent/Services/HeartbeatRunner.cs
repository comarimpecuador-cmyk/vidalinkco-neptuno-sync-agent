using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Extensions.Options;
using Vidalinkco.NeptunoSyncAgent.Configuration;
using Vidalinkco.NeptunoSyncAgent.Contracts;
using Vidalinkco.NeptunoSyncAgent.Infrastructure;

namespace Vidalinkco.NeptunoSyncAgent.Services;

public sealed class HeartbeatRunner(
    ILogger<HeartbeatRunner> logger,
    IOptionsMonitor<NeptunoSyncAgentOptions> options,
    VidalinkcoApiClient apiClient,
    LocalFileLogWriter localFileLogWriter)
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };

    public async Task RunOnceAsync(CancellationToken cancellationToken)
    {
        var currentOptions = options.CurrentValue;
        currentOptions.ValidateForHeartbeat();

        var payload = BuildPayload(currentOptions);

        if (currentOptions.DryRun)
        {
            var payloadJson = JsonSerializer.Serialize(payload, JsonOptions);
            logger.LogInformation("Dry-run heartbeat payload. Nothing was sent to Vidalinkco:{NewLine}{Payload}", Environment.NewLine, payloadJson);
            await localFileLogWriter.AppendAsync("heartbeat.dry_run", payload, cancellationToken);
            return;
        }

        var response = await apiClient.SendHeartbeatAsync(payload, cancellationToken);
        logger.LogInformation("Heartbeat accepted by Vidalinkco. Message: {Message}", response.Message ?? "ok");
        await localFileLogWriter.AppendAsync("heartbeat.sent", new
        {
            payload.AgentId,
            payload.Source,
            payload.MachineName,
            acceptedAtUtc = response.AcceptedAtUtc,
            response.Message
        }, cancellationToken);
    }

    private static HeartbeatPayload BuildPayload(NeptunoSyncAgentOptions options)
    {
        return new HeartbeatPayload(
            AgentId: options.AgentId.Trim(),
            Source: options.Source.Trim().ToLowerInvariant(),
            MachineName: options.EffectiveMachineName,
            Version: options.Version.Trim(),
            OccurredAtUtc: DateTimeOffset.UtcNow,
            Status: "online",
            Mode: options.DryRun ? "dry-run" : "live",
            DryRun: options.DryRun,
            BatchSize: options.BatchSize,
            Intervals: new HeartbeatIntervals(
                HeartbeatSeconds: options.HeartbeatIntervalSeconds,
                StockSyncSeconds: options.StockSyncIntervalSeconds),
            Capabilities: new AgentCapabilities(
                Heartbeat: true,
                StockPriceFuture: true,
                CatalogFuture: true,
                CsvImportFuture: true,
                SqlServerEnabled: false),
            Runtime: new AgentRuntime(
                OsDescription: RuntimeInformation.OSDescription,
                ProcessArchitecture: RuntimeInformation.ProcessArchitecture.ToString(),
                DotnetVersion: Environment.Version.ToString()));
    }
}
