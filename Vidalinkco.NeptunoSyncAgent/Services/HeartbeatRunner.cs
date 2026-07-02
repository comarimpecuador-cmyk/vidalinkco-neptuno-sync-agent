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

        var summary = await ReadLatestSummaryAsync(currentOptions.SyncSummaryPath, cancellationToken);
        var payload = BuildPayload(currentOptions, summary);

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

    private async Task<NeptunoSyncSummarySnapshot?> ReadLatestSummaryAsync(
        string configuredPath,
        CancellationToken cancellationToken)
    {
        var summaryPath = Path.GetFullPath(configuredPath.Trim());
        if (!File.Exists(summaryPath))
        {
            logger.LogWarning("NEPTUNO sync summary was not found at {SummaryPath}. Heartbeat will be sent without sync counters.", summaryPath);
            return null;
        }

        try
        {
            await using var stream = File.OpenRead(summaryPath);
            return await JsonSerializer.DeserializeAsync<NeptunoSyncSummarySnapshot>(stream, JsonOptions, cancellationToken);
        }
        catch (JsonException exception)
        {
            logger.LogWarning(exception, "NEPTUNO sync summary was invalid at {SummaryPath}. Heartbeat will be sent without sync counters.", summaryPath);
            return null;
        }
    }

    private static HeartbeatPayload BuildPayload(
        NeptunoSyncAgentOptions options,
        NeptunoSyncSummarySnapshot? summary)
    {
        return new HeartbeatPayload(
            AgentId: options.AgentId.Trim(),
            Source: options.Source.Trim().ToLowerInvariant(),
            SourceKey: string.IsNullOrWhiteSpace(summary?.SourceKey) ? options.Source.Trim().ToLowerInvariant() : summary.SourceKey.Trim(),
            MachineName: options.EffectiveMachineName,
            Version: options.Version.Trim(),
            LocalTime: DateTimeOffset.Now,
            OccurredAtUtc: DateTimeOffset.UtcNow,
            TaskMode: "heartbeat",
            LastSyncRunId: summary?.SyncRunId,
            LastSyncCompletedAt: summary?.CompletedAt,
            LastSendStatus: NormalizeSendStatus(summary?.SendStatus),
            CatalogItems: summary?.CatalogItems,
            LiveItems: summary?.LiveItems,
            ChangedCatalogItems: summary?.ChangedCatalogItems,
            ChangedLiveItems: summary?.ChangedLiveItems,
            QuarantinedItems: summary?.QuarantinedItems,
            Warnings: summary?.Warnings,
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

    private static string? NormalizeSendStatus(string? sendStatus)
    {
        return sendStatus?.Trim().ToLowerInvariant() switch
        {
            "sent" or "sent-chunked" => "sent",
            "failed" => "error",
            "no-changes" => "no-changes",
            null or "" => null,
            var value => value
        };
    }
}
