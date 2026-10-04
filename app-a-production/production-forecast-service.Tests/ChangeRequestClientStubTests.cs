using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.DependencyInjection;
using Prototype.ServiceDefaults;

namespace ProductionForecastService.Tests;

/// <summary>
/// CONSUMER contract tests for the CROSS-APP interaction C4 (App A production-forecast -> App B change-request).
/// The stub is built from the change-request spec pulled from the central contract repo (git source).
/// Start the stub first:  .\scripts\stub.ps1 start change-request-service 9201 -Strict -Config specmatic\change-request.mock.yaml
/// </summary>
[Trait("Category", "ConsumerContract")]
public class ChangeRequestClientStubTests
{
    private static readonly string StubUrl =
        Environment.GetEnvironmentVariable("CHANGE_REQUEST_STUB_URL") ?? "http://localhost:9201/v2/";

    private static (IChangeRequestClient Client, RecordingHandler Recorder) CreateClient()
    {
        var builder = WebApplication.CreateBuilder();
        builder.Configuration["Downstream:ChangeRequestBaseUrl"] = StubUrl;
        builder.Configuration["Downstream:Token"] = "test-token-123";
        var recorder = new RecordingHandler();
        builder.AddDownstreamClient<IChangeRequestClient, ChangeRequestClient>("Downstream:ChangeRequestBaseUrl")
               .AddHttpMessageHandler(() => recorder);
        return (builder.Services.BuildServiceProvider().GetRequiredService<IChangeRequestClient>(), recorder);
    }

    [Fact]
    public async Task Approved_changes_for_W001_are_mapped()
    {
        var (client, _) = CreateClient();
        var changes = await client.ListApprovedAsync("W-001", CancellationToken.None);

        var change = Assert.Single(changes);
        Assert.Equal(("CR-1001", "APPROVED", 150d), (change.Id, change.Status, change.CapacityDeltaBbl));
    }

    [Fact]
    public async Task Empty_list_from_consumer_example_is_handled()
    {
        var (client, _) = CreateClient();
        Assert.Empty(await client.ListApprovedAsync("W-002", CancellationToken.None));
    }

    [Fact]
    public async Task Query_without_an_example_is_refused_in_strict_mode()
    {
        var (client, _) = CreateClient();
        await Assert.ThrowsAsync<DownstreamException>(() => client.ListApprovedAsync("W-555", CancellationToken.None));
    }

    [Fact]
    public async Task Consumer_sends_token_and_the_exact_query_it_relies_on()
    {
        var (client, recorder) = CreateClient();
        await client.ListApprovedAsync("W-001", CancellationToken.None);

        var request = Assert.Single(recorder.Requests);
        Assert.Equal("Bearer test-token-123", request.Authorization);
        Assert.EndsWith("/v2/change-requests?wellId=W-001&status=APPROVED", request.Url);
    }
}
