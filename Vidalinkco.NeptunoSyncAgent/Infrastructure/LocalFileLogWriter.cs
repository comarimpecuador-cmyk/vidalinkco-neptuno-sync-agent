using System.Text.Json;
using Microsoft.Extensions.Options;
using Vidalinkco.NeptunoSyncAgent.Configuration;

namespace Vidalinkco.NeptunoSyncAgent.Infrastructure;

public sealed class LocalFileLogWriter(IOptionsMonitor<NeptunoSyncAgentOptions> options)
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = false
    };

    public async Task AppendAsync(string eventName, object payload, CancellationToken cancellationToken)
    {
        var logDirectory = options.CurrentValue.LogDirectory;
        if (string.IsNullOrWhiteSpace(logDirectory))
        {
            logDirectory = "logs";
        }

        Directory.CreateDirectory(logDirectory);

        var entry = new
        {
            occurredAtUtc = DateTimeOffset.UtcNow,
            eventName,
            payload
        };

        var line = JsonSerializer.Serialize(entry, JsonOptions) + Environment.NewLine;
        var path = Path.Combine(logDirectory, "agent.log");
        await File.AppendAllTextAsync(path, line, cancellationToken);
    }
}
