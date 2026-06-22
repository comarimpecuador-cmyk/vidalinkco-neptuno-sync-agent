namespace Vidalinkco.NeptunoSyncAgent;

using Microsoft.Extensions.Options;
using Vidalinkco.NeptunoSyncAgent.Configuration;
using Vidalinkco.NeptunoSyncAgent.Services;

public class Worker(
    ILogger<Worker> logger,
    IOptionsMonitor<NeptunoSyncAgentOptions> options,
    HeartbeatRunner heartbeatRunner) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            var currentOptions = options.CurrentValue;
            var interval = TimeSpan.FromSeconds(Math.Max(10, currentOptions.HeartbeatIntervalSeconds));

            try
            {
                await heartbeatRunner.RunOnceAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception exception)
            {
                logger.LogError(exception, "Heartbeat execution failed. The agent will retry in {IntervalSeconds} seconds.", interval.TotalSeconds);
            }

            await Task.Delay(interval, stoppingToken);
        }
    }
}
