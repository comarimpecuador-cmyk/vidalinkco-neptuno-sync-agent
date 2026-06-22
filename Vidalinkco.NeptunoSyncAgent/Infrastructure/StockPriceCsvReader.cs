using System.Globalization;
using System.Text;
using Vidalinkco.NeptunoSyncAgent.Contracts;

namespace Vidalinkco.NeptunoSyncAgent.Infrastructure;

public sealed class StockPriceCsvReader(
    ILogger<StockPriceCsvReader> logger,
    LocalFileLogWriter localFileLogWriter)
{
    public async Task<StockPriceCsvReadResult> ReadAsync(
        string csvPath,
        int maxRows,
        CancellationToken cancellationToken)
    {
        if (!File.Exists(csvPath))
        {
            throw new FileNotFoundException("Stock-price CSV file was not found.", csvPath);
        }

        var items = new List<StockPriceItem>();
        var invalidRows = new List<InvalidStockPriceCsvRow>();

        await using var fileStream = File.OpenRead(csvPath);
        using var reader = new StreamReader(
            fileStream,
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true),
            detectEncodingFromByteOrderMarks: true);

        var headerLine = await reader.ReadLineAsync(cancellationToken);
        if (headerLine is null)
        {
            return new StockPriceCsvReadResult(0, 0, 0, items, invalidRows);
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
            logger.LogWarning("Invalid stock-price CSV row {LineNumber}: {Reason}", invalidRow.LineNumber, invalidRow.Reason);
            await localFileLogWriter.AppendAsync("stock_price_csv.invalid_row", invalidRow, cancellationToken);
        }

        return new StockPriceCsvReadResult(totalRead, items.Count, invalidRows.Count, items, invalidRows);
    }

    private static bool TryMapRow(
        IReadOnlyList<string> values,
        IReadOnlyDictionary<string, int> index,
        int lineNumber,
        out StockPriceItem item,
        out InvalidStockPriceCsvRow invalidRow)
    {
        item = default!;
        invalidRow = default!;

        var externalId = GetFirstValue(values, index, "externalid");
        var nombreOriginal = GetFirstValue(values, index, "nombreoriginal", "name");

        if (string.IsNullOrWhiteSpace(externalId))
        {
            invalidRow = new InvalidStockPriceCsvRow(lineNumber, "externalId is required", null);
            return false;
        }

        if (string.IsNullOrWhiteSpace(nombreOriginal))
        {
            invalidRow = new InvalidStockPriceCsvRow(lineNumber, "nombreOriginal/name is required", externalId);
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
                "price") ||
            precioActual < 0)
        {
            invalidRow = new InvalidStockPriceCsvRow(lineNumber, precioActualError ?? "precioActual must be greater than or equal to zero", externalId);
            return false;
        }

        if (!TryReadDecimal(
                values,
                index,
                "stockUnidad",
                required: true,
                out var stockUnidad,
                out var stockUnidadError,
                "stockunidad") ||
            stockUnidad < 0)
        {
            invalidRow = new InvalidStockPriceCsvRow(lineNumber, stockUnidadError ?? "stockUnidad must be greater than or equal to zero", externalId);
            return false;
        }

        if (!TryReadDecimal(
                values,
                index,
                "stockFraccion",
                required: true,
                out var stockFraccion,
                out var stockFraccionError,
                "stockfraccion") ||
            stockFraccion < 0)
        {
            invalidRow = new InvalidStockPriceCsvRow(lineNumber, stockFraccionError ?? "stockFraccion must be greater than or equal to zero", externalId);
            return false;
        }

        if (!TryReadBoolean(
                values,
                index,
                "puedeVender/canSell",
                defaultValue: true,
                out var puedeVender,
                out var puedeVenderError,
                "puedevender",
                "cansell"))
        {
            invalidRow = new InvalidStockPriceCsvRow(lineNumber, puedeVenderError, externalId);
            return false;
        }

        var aplicaIvaOrigen = NormalizeOptional(GetFirstValue(values, index, "aplicaivaorigen", "appliesiva"));

        if (!TryReadDateTimeOffset(values, index, "syncedAt", out var syncedAt, out var syncedAtError, "syncedat"))
        {
            invalidRow = new InvalidStockPriceCsvRow(lineNumber, syncedAtError, externalId);
            return false;
        }

        item = new StockPriceItem(
            ExternalId: externalId.Trim(),
            NombreOriginal: nombreOriginal.Trim(),
            PrecioActual: precioActual,
            StockUnidad: stockUnidad,
            StockFraccion: stockFraccion,
            BodegaExternalId: NormalizeOptional(GetFirstValue(values, index, "bodegaexternalid", "warehouseexternalid")),
            EstadoExternalId: NormalizeOptional(GetFirstValue(values, index, "estadoexternalid")),
            EstadoNombre: NormalizeOptional(GetFirstValue(values, index, "estadonombre", "status")) ?? "ACTIVO",
            PuedeVender: puedeVender,
            AplicaIvaOrigen: aplicaIvaOrigen,
            IvaOrigenId: NormalizeOptional(GetFirstValue(values, index, "ivaorigenid", "ivaid")),
            Barcode: NormalizeOptional(GetFirstValue(values, index, "barcode")),
            BarcodeAlt: NormalizeOptional(GetFirstValue(values, index, "barcodealt", "alternatebarcode")),
            RawPayload: BuildRawPayload(values, index),
            SyncedAt: syncedAt);

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

        var normalized = rawValue.Trim().Replace(" ", string.Empty);

        if (decimal.TryParse(normalized, NumberStyles.Number, CultureInfo.InvariantCulture, out value))
        {
            return true;
        }

        normalized = normalized.Replace(',', '.');
        if (decimal.TryParse(normalized, NumberStyles.Number, CultureInfo.InvariantCulture, out value))
        {
            return true;
        }

        error = $"{displayName} is not a valid decimal";
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

        var normalized = rawValue.Trim().ToLowerInvariant();
        switch (normalized)
        {
            case "true":
            case "1":
            case "yes":
            case "si":
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
                error = $"{displayName} is not a valid boolean";
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
        AddRawValue(rawPayload, "externalId", values, index, "externalid");
        AddRawValue(rawPayload, "nombreOriginal", values, index, "nombreoriginal", "name");
        AddRawValue(rawPayload, "precioActual", values, index, "precioactual", "price");
        AddRawValue(rawPayload, "stockUnidad", values, index, "stockunidad");
        AddRawValue(rawPayload, "stockFraccion", values, index, "stockfraccion");
        AddRawValue(rawPayload, "bodegaExternalId", values, index, "bodegaexternalid", "warehouseexternalid");
        AddRawValue(rawPayload, "estadoExternalId", values, index, "estadoexternalid");
        AddRawValue(rawPayload, "estadoNombre", values, index, "estadonombre", "status");
        AddRawValue(rawPayload, "puedeVender", values, index, "puedevender", "cansell");
        AddRawValue(rawPayload, "aplicaIvaOrigen", values, index, "aplicaivaorigen", "appliesiva");
        AddRawValue(rawPayload, "ivaOrigenId", values, index, "ivaorigenid", "ivaid");
        AddRawValue(rawPayload, "precioOrigenTipo", values, index, "precioorigentipo", "pricetype");
        AddRawValue(rawPayload, "precioFinalCalculado", values, index, "preciofinalcalculado", "preciofinal", "finalprice");
        AddRawValue(rawPayload, "barcode", values, index, "barcode");
        AddRawValue(rawPayload, "barcodeAlt", values, index, "barcodealt", "alternatebarcode");
        AddRawValue(rawPayload, "syncedAt", values, index, "syncedat");

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

public sealed record StockPriceCsvReadResult(
    int TotalRead,
    int TotalValid,
    int TotalInvalid,
    IReadOnlyList<StockPriceItem> Items,
    IReadOnlyList<InvalidStockPriceCsvRow> InvalidRows);

public sealed record InvalidStockPriceCsvRow(
    int LineNumber,
    string Reason,
    string? ExternalId);
