using System.Text.Json;
using Microsoft.Extensions.Options;
using Vidalinkco.NeptunoSyncAgent.Configuration;
using Vidalinkco.NeptunoSyncAgent.Contracts;
using Vidalinkco.NeptunoSyncAgent.Infrastructure;

namespace Vidalinkco.NeptunoSyncAgent.Services;

public sealed class CatalogCsvRunner(
    ILogger<CatalogCsvRunner> logger,
    IOptionsMonitor<NeptunoSyncAgentOptions> options,
    CatalogCsvReader csvReader,
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
        currentOptions.ValidateForCatalogCsv();

        var csvPath = ResolvePath(currentOptions.CatalogCsvPath);
        var result = await csvReader.ReadAsync(csvPath, currentOptions.CatalogMaxRows, cancellationToken);

        logger.LogInformation(
            "Catalog CSV read completed. TotalRead={TotalRead}, TotalValid={TotalValid}, TotalInvalid={TotalInvalid}, Path={Path}",
            result.TotalRead,
            result.TotalValid,
            result.TotalInvalid,
            csvPath);

        if (currentOptions.DryRun)
        {
            var dryRunItems = result.Items
                .Take(Math.Min(currentOptions.CatalogSendBatchSize, currentOptions.CatalogDryRunLimit))
                .ToArray();
            var dryRunPayload = BuildPayload(currentOptions, dryRunItems);
            var dryRunPayloadJson = JsonSerializer.Serialize(dryRunPayload, JsonOptions);
            var invalidPreview = result.InvalidRows.Take(10).ToArray();

            logger.LogInformation(
                "Dry-run catalog CSV summary. TotalRead={TotalRead}, TotalValid={TotalValid}, TotalInvalid={TotalInvalid}. Nothing was sent to Vidalinkco.",
                result.TotalRead,
                result.TotalValid,
                result.TotalInvalid);
            logger.LogInformation("Dry-run first catalog payload:{NewLine}{Payload}", Environment.NewLine, dryRunPayloadJson);

            if (invalidPreview.Length > 0)
            {
                logger.LogWarning(
                    "Dry-run catalog invalid rows preview:{NewLine}{InvalidRows}",
                    Environment.NewLine,
                    JsonSerializer.Serialize(invalidPreview, JsonOptions));
            }

            await localFileLogWriter.AppendAsync("catalog_csv.dry_run", new
            {
                result.TotalRead,
                result.TotalValid,
                result.TotalInvalid,
                csvPath,
                previewItems = dryRunItems.Length,
                invalidPreview
            }, cancellationToken);
            return;
        }

        var batchNumber = 0;
        foreach (var batch in result.Items.Chunk(currentOptions.CatalogSendBatchSize))
        {
            cancellationToken.ThrowIfCancellationRequested();
            batchNumber++;

            var payload = BuildPayload(currentOptions, batch);

            try
            {
                var response = await apiClient.SendCatalogAsync(payload, cancellationToken);
                logger.LogInformation(
                    "Catalog batch {BatchNumber} sent. Items={ItemCount}, AcceptedItems={AcceptedItems}, ProcessedItems={ProcessedItems}, Message={Message}",
                    batchNumber,
                    batch.Length,
                    response.AcceptedItems ?? batch.Length,
                    response.ProcessedItems,
                    response.Message ?? "ok");
                await localFileLogWriter.AppendAsync("catalog_csv.batch_sent", new
                {
                    batchNumber,
                    itemCount = batch.Length,
                    acceptedItems = response.AcceptedItems,
                    processedItems = response.ProcessedItems,
                    acceptedAtUtc = response.AcceptedAtUtc,
                    response.Message
                }, cancellationToken);
            }
            catch (VidalinkcoApiException exception)
            {
                logger.LogError(
                    exception,
                    "Catalog batch {BatchNumber} failed with HTTP {StatusCode}. Response body: {ResponseBody}",
                    batchNumber,
                    exception.StatusCode,
                    exception.ResponseBody);
                await localFileLogWriter.AppendAsync("catalog_csv.batch_http_error", new
                {
                    batchNumber,
                    exception.StatusCode,
                    exception.ResponseBody
                }, cancellationToken);
                throw;
            }
        }
    }

    private static CatalogPayload BuildPayload(
        NeptunoSyncAgentOptions options,
        IReadOnlyList<CatalogItem> items)
    {
        return new CatalogPayload(
            Source: options.Source.Trim().ToLowerInvariant(),
            AgentId: options.AgentId.Trim(),
            SyncRunId: null,
            Items: items);
    }

    private static string ResolvePath(string path)
    {
        return Path.GetFullPath(Environment.ExpandEnvironmentVariables(path.Trim()));
    }
}
