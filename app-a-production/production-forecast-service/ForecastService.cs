using System.Text.RegularExpressions;

namespace ProductionForecastService;

public sealed record CreateForecastResult(Forecast? Forecast, Dictionary<string, string[]>? Errors);

public static class ForecastCalculator
{
    /// <summary>Exponential decline: month m = daily * 30 * (1 - decline%)^m, rounded to 0.1 bbl.</summary>
    public static double[] MonthlyVolumes(double dailyCapacityBbl, double declineRatePct, int months) =>
        Enumerable.Range(0, months)
            .Select(m => Math.Round(dailyCapacityBbl * 30 * Math.Pow(1 - declineRatePct / 100, m), 1,
                MidpointRounding.AwayFromZero))
            .ToArray();
}

public sealed partial class ForecastService(
    IForecastRepository repository,
    IWellRegistryClient wells,
    IChangeRequestClient changeRequests,
    TimeProvider clock)
{
    [GeneratedRegex(@"^W-\d{3}$")]
    private static partial Regex WellIdPattern();

    [GeneratedRegex(@"^F-\d{4}$")]
    public static partial Regex ForecastIdPattern();

    public Forecast? Get(string id) => repository.Get(id);

    public async Task<CreateForecastResult> CreateAsync(CreateForecastRequest request, CancellationToken ct)
    {
        var errors = new Dictionary<string, string[]>();
        if (request.WellId is null || !WellIdPattern().IsMatch(request.WellId))
            errors["wellId"] = ["wellId is required and must match W-000."];
        if (request.HorizonMonths is null or < 1 or > 24)
            errors["horizonMonths"] = ["horizonMonths is required (1-24)."];
        if (request.DeclineRatePct is null or < 0 or > 100)
            errors["declineRatePct"] = ["declineRatePct is required (0-100)."];
        if (errors.Count > 0)
            return new(null, errors);

        // Intra-app call: App A production-forecast -> App A well-registry.
        var well = await wells.GetWellAsync(request.WellId!, ct);
        if (well is null)
            return new(null, new() { ["wellId"] = [$"Well {request.WellId} does not exist."] });
        if (well.Status != "ACTIVE")
            return new(null, new() { ["wellId"] = [$"Well {well.Id} is {well.Status}; only ACTIVE wells can be forecast."] });

        // Cross-app call: App A production-forecast -> App B change-request.
        var approved = await changeRequests.ListApprovedAsync(well.Id, ct);
        var effective = Math.Max(0, well.DailyCapacityBbl + approved.Sum(c => c.CapacityDeltaBbl));
        var volumes = ForecastCalculator.MonthlyVolumes(effective, request.DeclineRatePct!.Value, request.HorizonMonths!.Value);

        var forecast = new Forecast(
            repository.NextId(),
            well.Id,
            well.Name,
            request.HorizonMonths.Value,
            request.DeclineRatePct.Value,
            well.DailyCapacityBbl,
            effective,
            approved.Select(c => c.Id).ToList(),
            volumes,
            Math.Round(volumes.Sum(), 1, MidpointRounding.AwayFromZero),
            clock.GetUtcNow());
        repository.Add(forecast);
        return new(forecast, null);
    }
}
