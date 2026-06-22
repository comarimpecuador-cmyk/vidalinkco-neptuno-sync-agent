using System.Globalization;
using System.Text;
using Vidalinkco.NeptunoSyncAgent.Contracts;

namespace Vidalinkco.NeptunoSyncAgent.Infrastructure;

public sealed class CatalogCsvReader(
    ILogger<CatalogCsvReader> logger,
    LocalFileLogWriter localFileLogWriter)
{
    public async Task<CatalogCsvReadResult> ReadAsync(
        string csvPath,
        int maxRows,
        CancellationToken cancellationToken)
    {
        if (!File.Exists(csvPath))
        {
            throw new FileNotFoundException("Catalog CSV file was not found.", csvPath);
        }

        var items = new List<CatalogItem>();
        var invalidRows = new List<InvalidCatalogCsvRow>();

        await using var fileStream = File.OpenRead(csvPath);
        using var reader = new StreamReader(
            fileStream,
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true),
            detectEncodingFromByteOrderMarks: true);

        var headerLine = await reader.ReadLineAsync(cancellationToken);
        if (headerLine is null)
        {
            return new CatalogCsvReadResult(0, 0, 0, items, invalidRows);
        }

        var delimiter = DetectDelimiter(headerLine);
        var headers = SplitCsvLine(headerLine, delimiter);
        var index = BuildHeaderIndex(headers);

        var totalRead = 0;
        var lineNumber = 1;

        while (totalRead < maxRows)
        {
            cancellationToken.ThrowIfCancellationRequested();
            lineNumber++;

            var line = await reader.ReadLineAsync(cancellationToken);
            if (line is null)
            {
                break;
            }

            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            totalRead++;
            var values = SplitCsvLine(line, delimiter);

            if (TryMapRow(values, index, lineNumber, out var item, out var invalidRow))
            {
                items.Add(item);
                continue;
            }

            invalidRows.Add(invalidRow);
            logger.LogWarning("Invalid catalog CSV row {LineNumber}: {Reason}", invalidRow.LineNumber, invalidRow.Reason);
            await localFileLogWriter.AppendAsync("catalog_csv.invalid_row", invalidRow, cancellationToken);
        }

        return new CatalogCsvReadResult(totalRead, items.Count, invalidRows.Count, items, invalidRows);
    }

    private static bool TryMapRow(
        IReadOnlyList<string> values,
        IReadOnlyDictionary<string, int> index,
        int lineNumber,
        out CatalogItem item,
        out InvalidCatalogCsvRow invalidRow)
    {
        item = default!;
        invalidRow = default!;

        var externalId = GetFirstValue(values, index, "externalid", "iditem", "initemiditem");
        var nombreOriginal = GetFirstValue(values, index, "nombreoriginal", "name", "descripcion", "initemdescripcion");

        if (string.IsNullOrWhiteSpace(externalId))
        {
            invalidRow = new InvalidCatalogCsvRow(lineNumber, "externalId is required", null);
            return false;
        }

        if (string.IsNullOrWhiteSpace(nombreOriginal))
        {
            invalidRow = new InvalidCatalogCsvRow(lineNumber, "nombreOriginal/name is required", externalId);
            return false;
        }

        if (!TryReadDecimal(
                values,
                index,
                "precioActual/price",
                required: true,
                out var precioActual,
                out var precioActualError,
                "precioactual",
                "price",
                "precio",
                "initemprecio") ||
            precioActual < 0)
        {
            invalidRow = new InvalidCatalogCsvRow(lineNumber, precioActualError ?? "precioActual must be greater than or equal to zero", externalId);
            return false;
        }

        if (!TryReadDecimal(
                values,
                index,
                "stockUnidad",
                required: true,
                out var stockUnidad,
                out var stockUnidadError,
                "stockunidad",
                "stockunidadorigen",
                "initembodegastockunidad") ||
            stockUnidad < 0)
        {
            invalidRow = new InvalidCatalogCsvRow(lineNumber, stockUnidadError ?? "stockUnidad must be greater than or equal to zero", externalId);
            return false;
        }

        if (!TryReadDecimal(
                values,
                index,
                "stockFraccion",
                required: true,
                out var stockFraccion,
                out var stockFraccionError,
                "stockfraccion",
                "initembodegastockfraccion") ||
            stockFraccion < 0)
        {
            invalidRow = new InvalidCatalogCsvRow(lineNumber, stockFraccionError ?? "stockFraccion must be greater than or equal to zero", externalId);
            return false;
        }

        if (!TryReadOptionalBoolean(
                values,
                index,
                "puedeVender/canSell",
                out var puedeVender,
                out var puedeVenderError,
                "puedevender",
                "cansell",
                "inestadoitempuedevender"))
        {
            invalidRow = new InvalidCatalogCsvRow(lineNumber, puedeVenderError ?? "puedeVender is not a valid boolean", externalId);
            return false;
        }

        if (!TryReadOptionalBoolean(values, index, "requiereMedico", out var requiereMedico, out var requiereMedicoError, "requieremedico", "inproductorequieremedico"))
        {
            invalidRow = new InvalidCatalogCsvRow(
                lineNumber,
                requiereMedicoError ?? "requiereMedico is not a valid boolean",
                externalId);
            return false;
        }

        if (!TryReadOptionalDecimal(
                values,
                index,
                "unidadesPorCaja",
                out var unidadesPorCaja,
                out var unidadesPorCajaError,
                "unidadesporcaja",
                "numfraccion",
                "inproductonumfraccion"))
        {
            invalidRow = new InvalidCatalogCsvRow(lineNumber, unidadesPorCajaError ?? "unidadesPorCaja is not a valid decimal", externalId);
            return false;
        }

        if (!TryReadDateTimeOffset(values, index, "syncedAt", out var syncedAt, out var syncedAtError, "syncedat"))
        {
            invalidRow = new InvalidCatalogCsvRow(lineNumber, syncedAtError, externalId);
            return false;
        }

        item = new CatalogItem(
            ExternalId: externalId.Trim(),
            NombreOriginal: nombreOriginal.Trim(),
            NombreLargo: NormalizeOptional(GetFirstValue(values, index, "nombrelargo", "longname", "descripcionlarga", "initemdescripcionlarga")),
            PrecioActual: precioActual,
            StockUnidad: stockUnidad,
            StockFraccion: stockFraccion,
            BodegaExternalId: NormalizeOptional(GetFirstValue(values, index, "bodegaexternalid", "warehouseexternalid", "idbodega", "initembodegaidbodega")),
            EstadoExternalId: NormalizeOptional(GetFirstValue(values, index, "estadoexternalid", "idestadoitem", "initemidestadoitem")),
            EstadoNombre: NormalizeOptional(GetFirstValue(values, index, "estadonombre", "status", "inestadoitemdescripcion")) ?? "ACTIVO",
            PuedeVender: puedeVender,
            AplicaIvaOrigen: NormalizeOptional(GetFirstValue(values, index, "aplicaivaorigen", "appliesiva", "aplicaiva", "initemaplicaiva")),
            IvaOrigenId: NormalizeOptional(GetFirstValue(values, index, "ivaorigenid", "ivaid", "idiva", "initemidiva")),
            Barcode: NormalizeOptional(GetFirstValue(values, index, "barcode", "codbarra", "initemcodbarra")),
            BarcodeAlt: NormalizeOptional(GetFirstValue(values, index, "barcodealt", "alternatebarcode", "codbarraalterno", "initemcodbarraalterno")),
            CategoriaExternalId: NormalizeOptional(GetFirstValue(values, index, "categoriaexternalid", "idclasif1", "initemidclasif1")),
            CategoriaNombre: NormalizeOptional(GetFirstValue(values, index, "categorianombre", "innodoclasif1descripcion")),
            SubcategoriaExternalId: NormalizeOptional(GetFirstValue(values, index, "subcategoriaexternalid", "idclasif2", "initemidclasif2")),
            SubcategoriaNombre: NormalizeOptional(GetFirstValue(values, index, "subcategorianombre", "innodoclasif2descripcion")),
            Presentacion: NormalizeOptional(GetFirstValue(values, index, "presentacion", "inproductopresentacion")),
            Medida: NormalizeOptional(GetFirstValue(values, index, "medida", "inproductomedida")),
            Concentracion: NormalizeOptional(GetFirstValue(values, index, "concentracion", "inproductoconcentracion")),
            UnidadesPorCaja: unidadesPorCaja,
            Generico: NormalizeOptional(GetFirstValue(values, index, "generico", "inproductogenerico")),
            RestriccionMedica: NormalizeOptional(GetFirstValue(values, index, "restriccionmedica", "restricmedica", "inproductorestricmedica")),
            RequiereMedico: requiereMedico,
            VentaSinStock: NormalizeOptional(GetFirstValue(values, index, "ventasinstock", "inproductoventasinstock")),
            Cronico: NormalizeOptional(GetFirstValue(values, index, "cronico", "inproductocronico")),
            FabricanteExternalId: NormalizeOptional(GetFirstValue(values, index, "fabricanteexternalid", "idfabricante", "inproductoidfabricante")),
            FabricanteCodigo: NormalizeOptional(GetFirstValue(values, index, "fabricantecodigo", "infabricantemnemonico")),
            FabricanteNombre: NormalizeOptional(GetFirstValue(values, index, "fabricantenombre", "coentenombrecompleto")),
            VademecumExternalId: NormalizeOptional(GetFirstValue(values, index, "vademecumexternalid", "idvademecum", "inproductoidvademecum")),
            VademecumNombre: NormalizeOptional(GetFirstValue(values, index, "vademecumnombre", "favademecumdescripcion")),
            SyncedAt: syncedAt,
            RawPayload: BuildRawPayload(values, index));

        return true;
    }

    private static char DetectDelimiter(string headerLine)
    {
        var commaCount = CountDelimiter(headerLine, ',');
        var semicolonCount = CountDelimiter(headerLine, ';');
        return semicolonCount > commaCount ? ';' : ',';
    }

    private static int CountDelimiter(string line, char delimiter)
    {
        var count = 0;
        var inQuotes = false;

        for (var index = 0; index < line.Length; index++)
        {
            if (line[index] == '"')
            {
                inQuotes = !inQuotes;
                continue;
            }

            if (!inQuotes && line[index] == delimiter)
            {
                count++;
            }
        }

        return count;
    }

    private static IReadOnlyList<string> SplitCsvLine(string line, char delimiter)
    {
        var values = new List<string>();
        var current = new StringBuilder();
        var inQuotes = false;

        for (var index = 0; index < line.Length; index++)
        {
            var currentChar = line[index];

            if (currentChar == '"')
            {
                if (inQuotes && index + 1 < line.Length && line[index + 1] == '"')
                {
                    current.Append('"');
                    index++;
                    continue;
                }

                inQuotes = !inQuotes;
                continue;
            }

            if (!inQuotes && currentChar == delimiter)
            {
                values.Add(current.ToString().Trim());
                current.Clear();
                continue;
            }

            current.Append(currentChar);
        }

        values.Add(current.ToString().Trim());
        return values;
    }

    private static IReadOnlyDictionary<string, int> BuildHeaderIndex(IReadOnlyList<string> headers)
    {
        var index = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);

        for (var position = 0; position < headers.Count; position++)
        {
            var normalized = NormalizeHeader(headers[position]);
            if (!string.IsNullOrWhiteSpace(normalized) && !index.ContainsKey(normalized))
            {
                index[normalized] = position;
            }
        }

        return index;
    }

    private static string? GetValue(IReadOnlyList<string> values, IReadOnlyDictionary<string, int> index, string headerName)
    {
        if (!index.TryGetValue(headerName, out var position) || position >= values.Count)
        {
            return null;
        }

        return values[position];
    }

    private static string? GetFirstValue(
        IReadOnlyList<string> values,
        IReadOnlyDictionary<string, int> index,
        params string[] headerNames)
    {
        foreach (var headerName in headerNames)
        {
            var value = GetValue(values, index, headerName);
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value;
            }
        }

        return null;
    }

    private static bool TryReadDecimal(
        IReadOnlyList<string> values,
        IReadOnlyDictionary<string, int> index,
        string displayName,
        bool required,
        out decimal value,
        out string? error,
        params string[] headerNames)
    {
        value = 0;
        error = null;

        var rawValue = GetFirstValue(values, index, headerNames);
        if (string.IsNullOrWhiteSpace(rawValue))
        {
            if (required)
            {
                error = $"{displayName} is required";
                return false;
            }

            return true;
        }

        var normalized = NormalizeDecimalText(rawValue);
        if (decimal.TryParse(normalized, NumberStyles.Number, CultureInfo.InvariantCulture, out value))
        {
            return true;
        }

        error = $"{displayName} is not a valid decimal";
        return false;
    }

    private static string NormalizeDecimalText(string rawValue)
    {
        var normalized = rawValue.Trim().Replace(" ", string.Empty);
        var lastComma = normalized.LastIndexOf(',');
        var lastDot = normalized.LastIndexOf('.');

        if (lastComma >= 0 && lastDot >= 0)
        {
            if (lastComma > lastDot)
            {
                return normalized.Replace(".", string.Empty).Replace(',', '.');
            }

            return normalized.Replace(",", string.Empty);
        }

        if (lastComma >= 0)
        {
            return normalized.Replace(',', '.');
        }

        return normalized;
    }

    private static bool TryReadOptionalDecimal(
        IReadOnlyList<string> values,
        IReadOnlyDictionary<string, int> index,
        string displayName,
        out decimal? value,
        out string? error,
        params string[] headerNames)
    {
        value = null;
        error = null;

        var rawValue = GetFirstValue(values, index, headerNames);
        if (string.IsNullOrWhiteSpace(rawValue))
        {
            return true;
        }

        if (TryReadDecimal(values, index, displayName, required: false, out var parsedValue, out error, headerNames))
        {
            value = parsedValue;
            return true;
        }

        return false;
    }

    private static bool TryReadBoolean(
        IReadOnlyList<string> values,
        IReadOnlyDictionary<string, int> index,
        string displayName,
        bool defaultValue,
        out bool value,
        out string error,
        params string[] headerNames)
    {
        value = defaultValue;
        error = string.Empty;

        var rawValue = GetFirstValue(values, index, headerNames);
        if (string.IsNullOrWhiteSpace(rawValue))
        {
            return true;
        }

        if (TryParseFlexibleBoolean(rawValue, out value))
        {
            return true;
        }

        error = $"{displayName} is not a valid boolean";
        return false;
    }

    private static bool TryReadOptionalBoolean(
        IReadOnlyList<string> values,
        IReadOnlyDictionary<string, int> index,
        string displayName,
        out bool? value,
        out string? error,
        params string[] headerNames)
    {
        value = null;
        error = null;

        var rawValue = GetFirstValue(values, index, headerNames);
        if (string.IsNullOrWhiteSpace(rawValue))
        {
            return true;
        }

        if (TryParseFlexibleBoolean(rawValue, out var parsedValue))
        {
            value = parsedValue;
            return true;
        }

        error = $"{displayName} is not a valid boolean";
        return false;
    }

    private static bool TryParseFlexibleBoolean(string rawValue, out bool value)
    {
        var normalized = rawValue.Trim().ToLowerInvariant();
        switch (normalized)
        {
            case "true":
            case "1":
            case "yes":
            case "si":
            case "s":
            case "y":
                value = true;
                return true;
            case "false":
            case "0":
            case "no":
            case "n":
                value = false;
                return true;
            default:
                value = false;
                return false;
        }
    }

    private static bool TryReadDateTimeOffset(
        IReadOnlyList<string> values,
        IReadOnlyDictionary<string, int> index,
        string displayName,
        out DateTimeOffset value,
        out string error,
        params string[] headerNames)
    {
        error = string.Empty;
        var rawValue = GetFirstValue(values, index, headerNames);
        if (string.IsNullOrWhiteSpace(rawValue))
        {
            value = DateTimeOffset.UtcNow;
            return true;
        }

        if (DateTimeOffset.TryParse(
                rawValue,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeLocal,
                out value))
        {
            return true;
        }

        error = $"{displayName} is not a valid date/time";
        return false;
    }

    private static IReadOnlyDictionary<string, string?> BuildRawPayload(
        IReadOnlyList<string> values,
        IReadOnlyDictionary<string, int> index)
    {
        var rawPayload = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
        AddRawValue(rawPayload, "precioOriginal", values, index, "precioactual", "price", "precio", "initemprecio");
        AddRawValue(rawPayload, "aplicaIvaOrigen", values, index, "aplicaivaorigen", "appliesiva", "aplicaiva", "initemaplicaiva");
        AddRawValue(rawPayload, "ivaOrigenId", values, index, "ivaorigenid", "ivaid", "idiva", "initemidiva");
        AddRawValue(rawPayload, "precioOrigenTipo", values, index, "precioorigentipo", "pricetype");
        AddRawValue(rawPayload, "precioFinalCalculado", values, index, "preciofinalcalculado", "preciofinal", "finalprice");
        AddRawValue(rawPayload, "fechaIngreso", values, index, "fechaingreso", "initemfechaingreso");
        AddRawValue(rawPayload, "tipoItem", values, index, "tipoitem", "initemtipoitem");
        AddRawValue(rawPayload, "marcaItemExternalId", values, index, "marcaitemexternalid", "idmarcaitem", "initemidmarcaitem");
        AddRawValue(rawPayload, "bodegaHabilitado", values, index, "bodegahabilitado", "habilitado", "initembodegahabilitado");
        AddRawValue(rawPayload, "ubicacion", values, index, "ubicacion", "idubicacion", "initembodegaidubicacion");
        AddRawValue(rawPayload, "fechaUltVenta", values, index, "fechaultventa", "initembodegafechaultventa");
        AddRawValue(rawPayload, "fechaUltCompra", values, index, "fechaultcompra", "initembodegafechaultcompra");
        AddRawValue(rawPayload, "fechaUltTrans", values, index, "fechaulttrans", "initembodegafechaulttrans");
        AddRawValue(rawPayload, "fechaUltAjuste", values, index, "fechaultajuste", "initembodegafechaultajuste");
        AddRawValue(rawPayload, "estadoCodigo", values, index, "estadocodigo", "inestadoitemcodigo");
        AddRawValue(rawPayload, "estadoActivo", values, index, "estadoactivo", "inestadoitemactivo");
        AddRawValue(rawPayload, "vademecumActivo", values, index, "vademecumactivo", "favademecumactivo");
        AddRawValue(rawPayload, "vademecumFabricanteId", values, index, "vademecumfabricanteid", "favademecumidfabricante");
        AddRawValue(rawPayload, "ivaRateOrigen", values, index, "ivarateorigen", "porcentajeiva", "imimpuestoivaporcentaje");

        return rawPayload;
    }

    private static void AddRawValue(
        IDictionary<string, string?> rawPayload,
        string canonicalName,
        IReadOnlyList<string> values,
        IReadOnlyDictionary<string, int> index,
        params string[] headerNames)
    {
        rawPayload[canonicalName] = NormalizeOptional(GetFirstValue(values, index, headerNames));
    }

    private static string NormalizeHeader(string header)
    {
        var builder = new StringBuilder();

        foreach (var currentChar in header.Trim().ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(currentChar))
            {
                builder.Append(currentChar);
            }
        }

        return builder.ToString();
    }

    private static string? NormalizeOptional(string? value)
    {
        return string.IsNullOrWhiteSpace(value) ? null : value.Trim();
    }
}

public sealed record CatalogCsvReadResult(
    int TotalRead,
    int TotalValid,
    int TotalInvalid,
    IReadOnlyList<CatalogItem> Items,
    IReadOnlyList<InvalidCatalogCsvRow> InvalidRows);

public sealed record InvalidCatalogCsvRow(
    int LineNumber,
    string Reason,
    string? ExternalId);
