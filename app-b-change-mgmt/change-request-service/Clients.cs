using System.Net;
using System.Net.Http.Json;
using Prototype.ServiceDefaults;

namespace ChangeRequestService;

public interface IApprovalClient
{
    Task<ApprovalDecision> RequestApprovalAsync(ApprovalRequest request, CancellationToken ct);
}

public sealed class ApprovalClient(HttpClient http) : IApprovalClient
{
    private const string Provider = "approval-service";

    public async Task<ApprovalDecision> RequestApprovalAsync(ApprovalRequest request, CancellationToken ct)
    {
        using var response = await Downstream.SendAsync(Provider,
            () => http.PostAsJsonAsync("approvals", request, Json.Options, ct));
        if (response.StatusCode != HttpStatusCode.Created)
            throw new DownstreamException(Provider, $"unexpected status {(int)response.StatusCode}");
        return await Downstream.ReadAsync<ApprovalDecision>(Provider, response, ct);
    }
}

public interface IProductionForecastClient
{
    /// <summary>Returns null when the forecast does not exist (404).</summary>
    Task<ForecastSummary?> GetForecastAsync(string forecastId, CancellationToken ct);
}

/// <summary>Cross-app call: App B -> App A.</summary>
public sealed class ProductionForecastClient(HttpClient http) : IProductionForecastClient
{
    private const string Provider = "production-forecast-service";

    public async Task<ForecastSummary?> GetForecastAsync(string forecastId, CancellationToken ct)
    {
        using var response = await Downstream.SendAsync(Provider,
            () => http.GetAsync($"forecasts/{Uri.EscapeDataString(forecastId)}", ct));
        if (response.StatusCode == HttpStatusCode.NotFound)
            return null;
        if (!response.IsSuccessStatusCode)
            throw new DownstreamException(Provider, $"unexpected status {(int)response.StatusCode}");
        return await Downstream.ReadAsync<ForecastSummary>(Provider, response, ct);
    }
}
