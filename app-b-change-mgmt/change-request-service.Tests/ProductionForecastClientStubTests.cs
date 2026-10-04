using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.DependencyInjection;
using Prototype.ServiceDefaults;

namespace ChangeRequestService.Tests;

/// <summary>
/// CONSUMER contract tests for the CROSS-APP interaction C3 (App B change-request -> App A production-forecast).
/// The stub is built from the production-forecast spec pulled from the central contract repo (git source).
/// Start the stub first:  .\scripts\stub.ps1 start production-forecast-service 9102 -Strict -Config specmatic\production-forecast.mock.yaml
/// </summary>
[Trait("Category", "ConsumerContract")]
public class ProductionForecastClientStubTests
{
    private static readonly string StubUrl =
        Environment.GetEnvironmentVariable("PRODUCTION_FORECAST_STUB_URL") ?? "http://localhost:9102/v2/";

    private static (IProductionForecastClient Client, RecordingHandler Recorder) CreateClient()
    {
        var builder = WebApplication.CreateBuilder();
        builder.Configuration["Downstream:ProductionForecastBaseUrl"] = StubUrl;
        builder.Configuration["Downstream:Token"] = "test-token-123";
        var recorder = new RecordingHandler();
        builder.AddDownstreamClient<IProductionForecastClient, ProductionForecastClient>("Downstream:ProductionForecastBaseUrl")
               .AddHttpMessageHandler(() => recorder);
        return (builder.Services.BuildServiceProvider().GetRequiredService<IProductionForecastClient>(), recorder);
    }

    [Fact]
    public async Task Forecast_F5001_is_mapped()
    {
        var (client, _) = CreateClient();
        var forecast = await client.GetForecastAsync("F-5001", CancellationToken.None);
        Assert.Equal(("F-5001", "W-001"), (forecast!.Id, forecast.WellId));
    }

    [Fact]
    public async Task Unknown_forecast_404_becomes_null()
    {
        var (client, _) = CreateClient();
        Assert.Null(await client.GetForecastAsync("F-9999", CancellationToken.None));
    }

    [Fact]
    public async Task Request_that_breaks_the_contract_is_rejected_by_the_stub()
    {
        // "FC-1" violates the spec's pattern ^F-\d{4}$.
        var (client, _) = CreateClient();
        await Assert.ThrowsAsync<DownstreamException>(() => client.GetForecastAsync("FC-1", CancellationToken.None));
    }

    [Fact]
    public async Task Consumer_sends_token_to_the_v2_path()
    {
        var (client, recorder) = CreateClient();
        await client.GetForecastAsync("F-5001", CancellationToken.None);

        var request = Assert.Single(recorder.Requests);
        Assert.Equal("Bearer test-token-123", request.Authorization);
        Assert.EndsWith("/v2/forecasts/F-5001", request.Url);
    }
}
