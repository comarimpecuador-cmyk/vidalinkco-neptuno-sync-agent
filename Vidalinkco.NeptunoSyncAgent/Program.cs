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

builder.Services.Configure<NeptunoSyncAgentOptions>(
    builder.Configuration.GetSection(NeptunoSyncAgentOptions.SectionName));
builder.Services.AddSingleton<LocalFileLogWriter>();
builder.Services.AddSingleton<VidalinkcoApiClient>();
builder.Services.AddSingleton<HeartbeatRunner>();

if (!runHeartbeatOnce)
{
    builder.Services.AddHostedService<Worker>();
}

using var host = builder.Build();

if (runHeartbeatOnce)
{
    await host.Services.GetRequiredService<HeartbeatRunner>().RunOnceAsync(CancellationToken.None);
    return;
}

await host.RunAsync();
