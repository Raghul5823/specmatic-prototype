namespace ProductionForecastService.Tests;

/// <summary>
/// Test helper: records every outgoing request (method, URL, Authorization header) before
/// passing it on. Consumer contract tests add it to the real typed HttpClient to prove which
/// token the consumer sends, because a Specmatic stub only checks that a "Bearer ..." header is present.
/// </summary>
public sealed class RecordingHandler : DelegatingHandler
{
    public List<(string Method, string Url, string? Authorization)> Requests { get; } = [];

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        Requests.Add((request.Method.Method, request.RequestUri!.ToString(), request.Headers.Authorization?.ToString()));
        return base.SendAsync(request, ct);
    }
}
