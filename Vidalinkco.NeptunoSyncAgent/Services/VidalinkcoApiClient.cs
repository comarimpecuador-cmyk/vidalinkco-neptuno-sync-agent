using System.Net.Http.Headers;
using System.Net.Http.Json;
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

    public async Task<HeartbeatResponse> SendHeartbeatAsync(
        HeartbeatPayload payload,
        CancellationToken cancellationToken)
    {
        var currentOptions = options.CurrentValue;
        currentOptions.ValidateForHeartbeat();

        using var httpClient = CreateClient(currentOptions);
        using var response = await httpClient.PostAsJsonAsync(HeartbeatEndpoint, payload, cancellationToken);

        VidalinkcoEnvelope<HeartbeatResponse>? envelope = null;
        try
        {
            envelope = await response.Content.ReadFromJsonAsync<VidalinkcoEnvelope<HeartbeatResponse>>(cancellationToken);
        }
        catch (Exception exception)
        {
            logger.LogWarning(exception, "Vidalinkco heartbeat response was not a valid envelope.");
        }

        if (!response.IsSuccessStatusCode)
        {
            throw new HttpRequestException(
                $"Heartbeat failed with HTTP {(int)response.StatusCode}. Vidalinkco error: {envelope?.Error ?? "unavailable"}");
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
}
