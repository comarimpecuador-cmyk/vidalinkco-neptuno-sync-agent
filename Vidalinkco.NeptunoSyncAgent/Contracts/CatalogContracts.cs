using System.Text.Json.Serialization;

namespace Vidalinkco.NeptunoSyncAgent.Contracts;

public sealed record CatalogPayload(
    [property: JsonPropertyName("source")] string Source,
    [property: JsonPropertyName("agentId")] string AgentId,
    [property: JsonPropertyName("syncRunId")]
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? SyncRunId,
    [property: JsonPropertyName("items")] IReadOnlyList<CatalogItem> Items);

public sealed record CatalogItem(
    [property: JsonPropertyName("externalId")] string ExternalId,
    [property: JsonPropertyName("nombreOriginal")] string NombreOriginal,
    [property: JsonPropertyName("nombreLargo")] string? NombreLargo,
    [property: JsonPropertyName("precioActual")] decimal PrecioActual,
    [property: JsonPropertyName("stockUnidad")] decimal StockUnidad,
    [property: JsonPropertyName("stockFraccion")] decimal StockFraccion,
    [property: JsonPropertyName("bodegaExternalId")] string? BodegaExternalId,
    [property: JsonPropertyName("estadoExternalId")] string? EstadoExternalId,
    [property: JsonPropertyName("estadoNombre")] string EstadoNombre,
    [property: JsonPropertyName("puedeVender")] bool? PuedeVender,
    [property: JsonPropertyName("aplicaIvaOrigen")] string? AplicaIvaOrigen,
    [property: JsonPropertyName("ivaOrigenId")] string? IvaOrigenId,
    [property: JsonPropertyName("barcode")] string? Barcode,
    [property: JsonPropertyName("barcodeAlt")] string? BarcodeAlt,
    [property: JsonPropertyName("categoriaExternalId")] string? CategoriaExternalId,
    [property: JsonPropertyName("categoriaNombre")] string? CategoriaNombre,
    [property: JsonPropertyName("subcategoriaExternalId")] string? SubcategoriaExternalId,
    [property: JsonPropertyName("subcategoriaNombre")] string? SubcategoriaNombre,
    [property: JsonPropertyName("presentacion")] string? Presentacion,
    [property: JsonPropertyName("medida")] string? Medida,
    [property: JsonPropertyName("concentracion")] string? Concentracion,
    [property: JsonPropertyName("unidadesPorCaja")] decimal? UnidadesPorCaja,
    [property: JsonPropertyName("generico")] string? Generico,
    [property: JsonPropertyName("restriccionMedica")] string? RestriccionMedica,
    [property: JsonPropertyName("requiereMedico")] bool? RequiereMedico,
    [property: JsonPropertyName("ventaSinStock")] string? VentaSinStock,
    [property: JsonPropertyName("cronico")] string? Cronico,
    [property: JsonPropertyName("fabricanteExternalId")] string? FabricanteExternalId,
    [property: JsonPropertyName("fabricanteCodigo")] string? FabricanteCodigo,
    [property: JsonPropertyName("fabricanteNombre")] string? FabricanteNombre,
    [property: JsonPropertyName("vademecumExternalId")] string? VademecumExternalId,
    [property: JsonPropertyName("vademecumNombre")] string? VademecumNombre,
    [property: JsonPropertyName("syncedAt")] DateTimeOffset SyncedAt,
    [property: JsonPropertyName("rawPayload")] IReadOnlyDictionary<string, string?> RawPayload);

public sealed record CatalogResponse(
    [property: JsonPropertyName("acceptedAtUtc")] DateTimeOffset? AcceptedAtUtc,
    [property: JsonPropertyName("message")] string? Message,
    [property: JsonPropertyName("acceptedItems")] int? AcceptedItems,
    [property: JsonPropertyName("processedItems")] int? ProcessedItems);
