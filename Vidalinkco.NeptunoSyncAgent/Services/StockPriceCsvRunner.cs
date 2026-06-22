using System.Text.Json;
using Microsoft.Extensions.Options;
using Vidalinkco.NeptunoSyncAgent.Configuration;
using Vidalinkco.NeptunoSyncAgent.Contracts;
using Vidalinkco.NeptunoSyncAgent.Infrastructure;

namespace Vidalinkco.NeptunoSyncAgent.Services;

public sealed class StockPriceCsvRunner(
    ILogger<StockPriceCsvRunner> logger,
    IOptionsMonitor<NeptunoSyncAgentOptions> options,
    StockPriceCsvReader csvReader,
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
        currentOptions.ValidateForStockPriceCsv();

        var csvPath = ResolvePath(currentOptions.StockPriceCsvPath);
        var result = await csvReader.ReadAsync(csvPath, currentOptions.MaxRows, cancellationToken);

        logger.LogInformation(
            "Stock-price CSV read completed. TotalRead={TotalRead}, TotalValid={TotalValid}, TotalInvalid={TotalInvalid}, Path={Path}",
            result.TotalRead,
            result.TotalValid,
            result.TotalInvalid,
            csvPath);

        if (currentOptions.DryRun)
        {
            var dryRunItems = result.Items
                .Take(Math.Min(currentOptions.SendBatchSize, currentOptions.StockPriceDryRunLimit))
                .ToArray();
            var dryRunPayload = BuildPayload(currentOptions, dryRunItems);
            var dryRunPayloadJson = JsonSerializer.Serialize(dryRunPayload, JsonOptions);

            logger.LogInformation(
                "Dry-run stock-price CSV summary. TotalRead={TotalRead}, TotalValid={TotalValid}, TotalInvalid={TotalInvalid}. Nothing was sent to Vidalinkco.",
                result.TotalRead,
                result.TotalValid,
                result.TotalInvalid);
            logger.LogInformation("Dry-run first stock-price payload:{NewLine}{Payload}", Environment.NewLine, dryRunPayloadJson);

            await localFileLogWriter.AppendAsync("stock_price_csv.dry_run", new
            {
                result.TotalRead,
                result.TotalValid,
                result.TotalInvalid,
                csvPath,
                previewItems = dryRunItems.Length
            }, cancellationToken);
            return;
        }

        var batchNumber = 0;
        foreach (var batch in result.Items.Chunk(currentOptions.SendBatchSize))
        {
            cancellationToken.ThrowIfCancellationRequested();
            batchNumber++;

            var payload = BuildPayload(currentOptions, batch);

            try
            {
                var response = await apiClient.SendStockPriceAsync(payload, cancellationToken);
                logger.LogInformation(
                    "Stock-price batch {BatchNumber} sent. Items={ItemCount}, AcceptedItems={AcceptedItems}, Message={Message}",
                    batchNumber,
                    batch.Length,
                    response.AcceptedItems ?? batch.Length,
                    response.Message ?? "ok");
                await localFileLogWriter.AppendAsync("stock_price_csv.batch_sent", new
                {
                    batchNumber,
                    itemCount = batch.Length,
                    acceptedItems = response.AcceptedItems,
                    acceptedAtUtc = response.AcceptedAtUtc,
                    response.Message
                }, cancellationToken);
            }
            catch (VidalinkcoApiException exception)
            {
                logger.LogError(
                    exception,
                    "Stock-price batch {BatchNumber} failed with HTTP {StatusCode}. Response body: {ResponseBody}",
                    batchNumber,
                    exception.StatusCode,
                    exception.ResponseBody);
                await localFileLogWriter.AppendAsync("stock_price_csv.batch_http_error", new
                {
                    batchNumber,
                    exception.StatusCode,
                    exception.ResponseBody
                }, cancellationToken);
                throw;
            }
        }
    }

    private static StockPricePayload BuildPayload(
        NeptunoSyncAgentOptions options,
        IReadOnlyList<StockPriceItem> items)
    {
        return new StockPricePayload(
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
