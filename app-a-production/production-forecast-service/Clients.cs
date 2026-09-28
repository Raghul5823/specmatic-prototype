using System.Net;
using Prototype.ServiceDefaults;

namespace ProductionForecastService;

public interface IWellRegistryClient
{
    /// <summary>Returns null when the well does not exist (404).</summary>
    Task<WellSummary?> GetWellAsync(string wellId, CancellationToken ct);
}

public sealed class WellRegistryClient(HttpClient http) : IWellRegistryClient
{
    private const string Provider = "well-registry-service";

    public async Task<WellSummary?> GetWellAsync(string wellId, CancellationToken ct)
    {
        using var response = await Downstream.SendAsync(Provider,
            () => http.GetAsync($"/wells/{Uri.EscapeDataString(wellId)}", ct));
        if (response.StatusCode == HttpStatusCode.NotFound)
            return null;
        if (!response.IsSuccessStatusCode)
            throw new DownstreamException(Provider, $"unexpected status {(int)response.StatusCode}");
        return await Downstream.ReadAsync<WellSummary>(Provider, response, ct);
    }
}

public interface IChangeRequestClient
{
    Task<IReadOnlyList<ApprovedChange>> ListApprovedAsync(string wellId, CancellationToken ct);
}

/// <summary>Cross-app call: App A -> App B.</summary>
public sealed class ChangeRequestClient(HttpClient http) : IChangeRequestClient
{
    private const string Provider = "change-request-service";

    public async Task<IReadOnlyList<ApprovedChange>> ListApprovedAsync(string wellId, CancellationToken ct)
    {
        using var response = await Downstream.SendAsync(Provider,
            () => http.GetAsync($"/change-requests?wellId={Uri.EscapeDataString(wellId)}&status=APPROVED", ct));
        if (!response.IsSuccessStatusCode)
            throw new DownstreamException(Provider, $"unexpected status {(int)response.StatusCode}");
        return await Downstream.ReadAsync<List<ApprovedChange>>(Provider, response, ct);
    }
}
