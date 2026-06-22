using Vidalinkco.NeptunoSyncAgent;
using Vidalinkco.NeptunoSyncAgent.Configuration;
using Vidalinkco.NeptunoSyncAgent.Infrastructure;
using Vidalinkco.NeptunoSyncAgent.Services;

var builder = Host.CreateApplicationBuilder(args);

builder.Configuration.AddJsonFile("appsettings.local.json", optional: true, reloadOnChange: true);

if (args.Any(arg => string.Equals(arg, "--dry-run", StringComparison.OrdinalIgnoreCase)))
{
    builder.Configuration[$"{NeptunoSyncAgentOptions.SectionName}:DryRun"] = "true";
}

var runHeartbeatOnce = args.Any(arg => string.Equals(arg, "--heartbeat-once", StringComparison.OrdinalIgnoreCase));
var runStockPriceCsvOnce = args.Any(arg => string.Equals(arg, "--stock-price-csv-once", StringComparison.OrdinalIgnoreCase));
var runCatalogCsvOnce = args.Any(arg => string.Equals(arg, "--catalog-csv-once", StringComparison.OrdinalIgnoreCase));

builder.Services.Configure<NeptunoSyncAgentOptions>(
    builder.Configuration.GetSection(NeptunoSyncAgentOptions.SectionName));
builder.Services.AddSingleton<LocalFileLogWriter>();
builder.Services.AddSingleton<StockPriceCsvReader>();
builder.Services.AddSingleton<CatalogCsvReader>();
builder.Services.AddSingleton<VidalinkcoApiClient>();
builder.Services.AddSingleton<HeartbeatRunner>();
builder.Services.AddSingleton<StockPriceCsvRunner>();
builder.Services.AddSingleton<CatalogCsvRunner>();

if (!runHeartbeatOnce && !runStockPriceCsvOnce && !runCatalogCsvOnce)
{
    builder.Services.AddHostedService<Worker>();
}

using var host = builder.Build();

if (runHeartbeatOnce)
{
    await host.Services.GetRequiredService<HeartbeatRunner>().RunOnceAsync(CancellationToken.None);
    return;
}

if (runStockPriceCsvOnce)
{
    await host.Services.GetRequiredService<StockPriceCsvRunner>().RunOnceAsync(CancellationToken.None);
    return;
}

if (runCatalogCsvOnce)
{
    await host.Services.GetRequiredService<CatalogCsvRunner>().RunOnceAsync(CancellationToken.None);
    return;
}

await host.RunAsync();
