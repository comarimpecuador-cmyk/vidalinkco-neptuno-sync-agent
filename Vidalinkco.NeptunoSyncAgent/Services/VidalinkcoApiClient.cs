using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Extensions.Options;
using Vidalinkco.NeptunoSyncAgent.Configuration;
using Vidalinkco.NeptunoSyncAgent.Contracts;

namespace Vidalinkco.NeptunoSyncAgent.Services;

public sealed class VidalinkcoApiClient(
    ILogger<VidalinkcoApiClient> logger,
    IOptionsMonitor<NeptunoSyncAgentOptions> options)
{
    private const string IntegrationKeyHeaderName = "x-vidalinkco-integration-key";
    private static readonly Uri HeartbeatEndpoint = new("/api/integrations/neptuno/heartbeat", UriKind.Relative);
    private static readonly Uri StockPriceEndpoint = new("/api/integrations/neptuno/stock-price", UriKind.Relative);
    private static readonly Uri CatalogEndpoint = new("/api/integrations/neptuno/catalog", UriKind.Relative);

    public async Task<HeartbeatResponse> SendHeartbeatAsync(
        HeartbeatPayload payload,
        CancellationToken cancellationToken)
    {
        var currentOptions = options.CurrentValue;
        currentOptions.ValidateForHeartbeat();

        using var httpClient = CreateClient(currentOptions);
        using var response = await httpClient.PostAsJsonAsync(HeartbeatEndpoint, payload, cancellationToken);
        var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);

        VidalinkcoEnvelope<HeartbeatResponse>? envelope = null;
        try
        {
            envelope = JsonSerializer.Deserialize<VidalinkcoEnvelope<HeartbeatResponse>>(responseBody, JsonOptions);
        }
        catch (Exception exception)
        {
            logger.LogWarning(exception, "Vidalinkco heartbeat response was not a valid envelope.");
        }

        if (!response.IsSuccessStatusCode)
        {
            throw new VidalinkcoApiException(
                $"Heartbeat failed with HTTP {(int)response.StatusCode}. Vidalinkco error: {envelope?.Error ?? "unavailable"}",
                (int)response.StatusCode,
                SummarizeBody(responseBody));
        }

        if (envelope is null)
        {
            throw new InvalidOperationException("Heartbeat failed because Vidalinkco returned an empty or invalid envelope.");
        }

        if (!envelope.Ok)
        {
            throw new InvalidOperationException($"Heartbeat rejected by Vidalinkco: {envelope.Error ?? "unknown error"}");
        }

        return envelope.Data ?? new HeartbeatResponse(DateTimeOffset.UtcNow, "ok");
    }

    public async Task<StockPriceResponse> SendStockPriceAsync(
        StockPricePayload payload,
        CancellationToken cancellationToken)
    {
        var currentOptions = options.CurrentValue;
        currentOptions.ValidateForStockPriceCsv();

        using var httpClient = CreateClient(currentOptions);
        using var response = await httpClient.PostAsJsonAsync(StockPriceEndpoint, payload, cancellationToken);
        var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);

        VidalinkcoEnvelope<StockPriceResponse>? envelope = null;
        try
        {
            envelope = JsonSerializer.Deserialize<VidalinkcoEnvelope<StockPriceResponse>>(responseBody, JsonOptions);
        }
        catch (Exception exception)
        {
            logger.LogWarning(exception, "Vidalinkco stock-price response was not a valid envelope.");
        }

        if (!response.IsSuccessStatusCode)
        {
            throw new VidalinkcoApiException(
                $"Stock-price batch failed with HTTP {(int)response.StatusCode}. Vidalinkco error: {envelope?.Error ?? "unavailable"}",
                (int)response.StatusCode,
                SummarizeBody(responseBody));
        }

        if (envelope is null)
        {
            throw new InvalidOperationException("Stock-price batch failed because Vidalinkco returned an empty or invalid envelope.");
        }

        if (!envelope.Ok)
        {
            throw new InvalidOperationException($"Stock-price batch rejected by Vidalinkco: {envelope.Error ?? "unknown error"}");
        }

        return envelope.Data ?? new StockPriceResponse(DateTimeOffset.UtcNow, "ok", payload.Items.Count);
    }

    public async Task<CatalogResponse> SendCatalogAsync(
        CatalogPayload payload,
        CancellationToken cancellationToken)
    {
        var currentOptions = options.CurrentValue;
        currentOptions.ValidateForCatalogCsv();

        using var httpClient = CreateClient(currentOptions);
        using var response = await httpClient.PostAsJsonAsync(CatalogEndpoint, payload, cancellationToken);
        var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);

        VidalinkcoEnvelope<CatalogResponse>? envelope = null;
        try
        {
            envelope = JsonSerializer.Deserialize<VidalinkcoEnvelope<CatalogResponse>>(responseBody, JsonOptions);
        }
        catch (Exception exception)
        {
            logger.LogWarning(exception, "Vidalinkco catalog response was not a valid envelope.");
        }

        if (!response.IsSuccessStatusCode)
        {
            throw new VidalinkcoApiException(
                $"Catalog batch failed with HTTP {(int)response.StatusCode}. Vidalinkco error: {envelope?.Error ?? "unavailable"}",
                (int)response.StatusCode,
                SummarizeBody(responseBody));
        }

        if (envelope is null)
        {
            throw new InvalidOperationException("Catalog batch failed because Vidalinkco returned an empty or invalid envelope.");
        }

        if (!envelope.Ok)
        {
            throw new InvalidOperationException($"Catalog batch rejected by Vidalinkco: {envelope.Error ?? "unknown error"}");
        }

        return envelope.Data ?? new CatalogResponse(DateTimeOffset.UtcNow, "ok", payload.Items.Count, payload.Items.Count);
    }

    private static HttpClient CreateClient(NeptunoSyncAgentOptions options)
    {
        var httpClient = new HttpClient
        {
            BaseAddress = new Uri(options.VidalinkcoBaseUrl.Trim().TrimEnd('/')),
            Timeout = TimeSpan.FromSeconds(30)
        };

        httpClient.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        httpClient.DefaultRequestHeaders.Add(IntegrationKeyHeaderName, options.ApiKey.Trim());
        return httpClient;
    }

    private static string SummarizeBody(string responseBody)
    {
        if (string.IsNullOrWhiteSpace(responseBody))
        {
            return string.Empty;
        }

        var trimmed = responseBody.Trim();
        return trimmed.Length <= 1000 ? trimmed : trimmed[..1000];
    }

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
}
