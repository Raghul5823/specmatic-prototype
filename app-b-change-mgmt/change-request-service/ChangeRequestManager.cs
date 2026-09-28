using System.Text.RegularExpressions;

namespace ChangeRequestService;

public sealed record CreateChangeRequestResult(ChangeRequest? ChangeRequest, Dictionary<string, string[]>? Errors);

public sealed partial class ChangeRequestManager(
    IChangeRequestRepository repository,
    IApprovalClient approvals,
    IProductionForecastClient forecasts,
    TimeProvider clock)
{
    [GeneratedRegex(@"^W-\d{3}$")]
    public static partial Regex WellIdPattern();

    [GeneratedRegex(@"^F-\d{4}$")]
    private static partial Regex ForecastIdPattern();

    [GeneratedRegex(@"^CR-\d{4}$")]
    public static partial Regex ChangeRequestIdPattern();

    public IReadOnlyList<ChangeRequest> List(string? wellId, ChangeStatus? status) => repository.List(wellId, status);

    public ChangeRequest? Get(string id) => repository.Get(id);

    public async Task<CreateChangeRequestResult> CreateAsync(CreateChangeRequestRequest request, CancellationToken ct)
    {
        var errors = new Dictionary<string, string[]>();
        if (string.IsNullOrWhiteSpace(request.Title) || request.Title.Length > 200)
            errors["title"] = ["title is required (1-200 characters)."];
        if (request.WellId is null || !WellIdPattern().IsMatch(request.WellId))
            errors["wellId"] = ["wellId is required and must match W-000."];
        if (request.ForecastId is not null && !ForecastIdPattern().IsMatch(request.ForecastId))
            errors["forecastId"] = ["forecastId must match F-0000."];
        if (request.Type is null)
            errors["type"] = ["type is required."];
        if (request.CapacityDeltaBbl is null)
            errors["capacityDeltaBbl"] = ["capacityDeltaBbl is required."];
        if (string.IsNullOrWhiteSpace(request.RequestedBy))
            errors["requestedBy"] = ["requestedBy is required."];
        if (errors.Count > 0)
            return new(null, errors);

        // Cross-app call: App B change-request -> App A production-forecast (optional link).
        if (request.ForecastId is not null)
        {
            var forecast = await forecasts.GetForecastAsync(request.ForecastId, ct);
            if (forecast is null)
                return new(null, new() { ["forecastId"] = [$"Forecast {request.ForecastId} does not exist."] });
            if (forecast.WellId != request.WellId)
                return new(null, new() { ["forecastId"] = [$"Forecast {forecast.Id} belongs to well {forecast.WellId}, not {request.WellId}."] });
        }

        var id = repository.NextId();

        // Intra-app call: App B change-request -> App B approval.
        var decision = await approvals.RequestApprovalAsync(
            new ApprovalRequest(id, request.Type!.Value.ToString(), request.CapacityDeltaBbl!.Value), ct);
        if (!Enum.TryParse<ChangeStatus>(decision.Decision, ignoreCase: false, out var status))
            throw new Prototype.ServiceDefaults.DownstreamException("approval-service", $"unknown decision '{decision.Decision}'");

        var changeRequest = new ChangeRequest(
            id,
            request.Title!.Trim(),
            request.WellId!,
            request.ForecastId,
            request.Type.Value,
            request.CapacityDeltaBbl.Value,
            request.RequestedBy!.Trim(),
            status,
            decision.Id,
            decision.Reason,
            clock.GetUtcNow());
        repository.Add(changeRequest);
        return new(changeRequest, null);
    }
}
