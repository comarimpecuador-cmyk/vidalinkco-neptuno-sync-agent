using System.Text.Json.Serialization;

namespace Vidalinkco.NeptunoSyncAgent.Contracts;

public sealed record StockPricePayload(
    [property: JsonPropertyName("source")] string Source,
    [property: JsonPropertyName("agentId")] string AgentId,
    [property: JsonPropertyName("syncRunId")]
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? SyncRunId,
    [property: JsonPropertyName("items")] IReadOnlyList<StockPriceItem> Items);

public sealed record StockPriceItem(
    [property: JsonPropertyName("externalId")] string ExternalId,
    [property: JsonPropertyName("nombreOriginal")] string NombreOriginal,
    [property: JsonPropertyName("precioActual")] decimal PrecioActual,
    [property: JsonPropertyName("stockUnidad")] decimal StockUnidad,
    [property: JsonPropertyName("stockFraccion")] decimal StockFraccion,
    [property: JsonPropertyName("bodegaExternalId")] string? BodegaExternalId,
    [property: JsonPropertyName("estadoExternalId")] string? EstadoExternalId,
    [property: JsonPropertyName("estadoNombre")] string EstadoNombre,
    [property: JsonPropertyName("puedeVender")] bool PuedeVender,
    [property: JsonPropertyName("aplicaIvaOrigen")] string? AplicaIvaOrigen,
    [property: JsonPropertyName("ivaOrigenId")] string? IvaOrigenId,
    [property: JsonPropertyName("barcode")] string? Barcode,
    [property: JsonPropertyName("barcodeAlt")] string? BarcodeAlt,
    [property: JsonPropertyName("rawPayload")] IReadOnlyDictionary<string, string?> RawPayload,
    [property: JsonPropertyName("syncedAt")] DateTimeOffset SyncedAt);

public sealed record StockPriceResponse(
    [property: JsonPropertyName("acceptedAtUtc")] DateTimeOffset? AcceptedAtUtc,
    [property: JsonPropertyName("message")] string? Message,
    [property: JsonPropertyName("acceptedItems")] int? AcceptedItems);
