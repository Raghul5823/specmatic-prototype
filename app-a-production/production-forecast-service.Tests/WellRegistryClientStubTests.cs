using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.DependencyInjection;
using Prototype.ServiceDefaults;

namespace ProductionForecastService.Tests;

/// <summary>
/// CONSUMER contract tests for interaction C1 (production-forecast -> well-registry).
/// The consumer's real WellRegistryClient, registered exactly as in Program.cs, is pointed at a
/// Specmatic STUB generated from the well-registry spec in contracts/.
/// Start the stub first:  .\scripts\stub.ps1 start well-registry-service 9101 -Strict -Config specmatic\well-registry.mock.yaml
/// </summary>
[Trait("Category", "ConsumerContract")]
public class WellRegistryClientStubTests
{
    private static readonly string StubUrl =
        Environment.GetEnvironmentVariable("WELL_REGISTRY_STUB_URL") ?? "http://localhost:9101/v2/";

    private static (IWellRegistryClient Client, RecordingHandler Recorder) CreateClient(string token = "test-token-123")
    {
        var builder = WebApplication.CreateBuilder();
        builder.Configuration["Downstream:WellRegistryBaseUrl"] = StubUrl;
        builder.Configuration["Downstream:Token"] = token;
        var recorder = new RecordingHandler();
        builder.AddDownstreamClient<IWellRegistryClient, WellRegistryClient>("Downstream:WellRegistryBaseUrl")
               .AddHttpMessageHandler(() => recorder);
        var provider = builder.Services.BuildServiceProvider();
        return (provider.GetRequiredService<IWellRegistryClient>(), recorder);
    }

    [Fact]
    public async Task Active_well_from_consumer_example_is_mapped()
    {
        var (client, _) = CreateClient();
        var well = await client.GetWellAsync("W-001", CancellationToken.None);

        Assert.NotNull(well);
        Assert.Equal(("W-001", "Eagle-1", "ACTIVE", 1200d), (well.Id, well.Name, well.Status, well.DailyCapacityBbl));
    }

    [Fact]
    public async Task Shut_in_well_from_consumer_example_is_mapped()
    {
        var (client, _) = CreateClient();
        var well = await client.GetWellAsync("W-003", CancellationToken.None);
        Assert.Equal("SHUT_IN", well!.Status);
    }

    [Fact]
    public async Task Unknown_well_404_from_consumer_example_becomes_null()
    {
        var (client, _) = CreateClient();
        Assert.Null(await client.GetWellAsync("W-999", CancellationToken.None));
    }

    [Fact]
    public async Task Request_that_breaks_the_contract_is_rejected_by_the_stub()
    {
        // "WELL-1" violates the spec's pattern ^W-\d{3}$: the stub answers 400, the client raises.
        var (client, _) = CreateClient();
        var ex = await Assert.ThrowsAsync<DownstreamException>(() => client.GetWellAsync("WELL-1", CancellationToken.None));
        Assert.Contains("400", ex.Message);
    }

    [Fact]
    public async Task Interaction_without_an_example_is_refused_in_strict_mode()
    {
        // W-555 is valid per the spec but no consumer example covers it. A lenient stub would return
        // random data; the strict stub refuses (400), forcing the consumer to add an example.
        var (client, _) = CreateClient();
        await Assert.ThrowsAsync<DownstreamException>(() => client.GetWellAsync("W-555", CancellationToken.None));
    }

    [Fact]
    public async Task Consumer_sends_the_configured_bearer_token_and_v2_path()
    {
        // T5: the stub only checks "Bearer <something>", so the exact token is asserted here.
        var (client, recorder) = CreateClient();
        await client.GetWellAsync("W-001", CancellationToken.None);

        var request = Assert.Single(recorder.Requests);
        Assert.Equal("Bearer test-token-123", request.Authorization);
        Assert.EndsWith("/v2/wells/W-001", request.Url);
    }
}
