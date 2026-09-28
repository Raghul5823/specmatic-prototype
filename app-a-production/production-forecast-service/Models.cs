namespace ProductionForecastService;

public sealed record Forecast(
    string Id,
    string WellId,
    string WellName,
    int HorizonMonths,
    double DeclineRatePct,
    double BaseDailyCapacityBbl,
    double EffectiveDailyCapacityBbl,
    IReadOnlyList<string> AppliedChangeRequestIds,
    IReadOnlyList<double> MonthlyVolumesBbl,
    double TotalVolumeBbl,
    DateTimeOffset CreatedAt);

public sealed record CreateForecastRequest(
    string? WellId = null,
    int? HorizonMonths = null,
    double? DeclineRatePct = null);

// Consumer views of provider responses: only the fields this service relies on.
// Extra provider fields are ignored; a missing field fails deserialization (-> 502).

/// <summary>From well-registry-service GET /wells/{wellId}.</summary>
public sealed record WellSummary(string Id, string Name, string Status, double DailyCapacityBbl);

/// <summary>From change-request-service GET /change-requests?wellId=&amp;status=APPROVED.</summary>
public sealed record ApprovedChange(string Id, string WellId, string Status, double CapacityDeltaBbl);
