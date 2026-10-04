using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.DependencyInjection;
using Prototype.ServiceDefaults;

namespace ChangeRequestService.Tests;

/// <summary>
/// CONSUMER contract tests for interaction C2 (change-request -> approval).
/// The consumer's real ApprovalClient, registered exactly as in Program.cs, is pointed at a
/// Specmatic STUB generated from the approval spec in contracts/.
/// Start the stub first:  .\scripts\stub.ps1 start approval-service 9202 -Strict -Config specmatic\approval.mock.yaml
/// </summary>
[Trait("Category", "ConsumerContract")]
public class ApprovalClientStubTests
{
    private static readonly string StubUrl =
        Environment.GetEnvironmentVariable("APPROVAL_STUB_URL") ?? "http://localhost:9202/v2/";

    private static (IApprovalClient Client, RecordingHandler Recorder) CreateClient()
    {
        var builder = WebApplication.CreateBuilder();
        builder.Configuration["Downstream:ApprovalBaseUrl"] = StubUrl;
        builder.Configuration["Downstream:Token"] = "test-token-123";
        var recorder = new RecordingHandler();
        builder.AddDownstreamClient<IApprovalClient, ApprovalClient>("Downstream:ApprovalBaseUrl")
               .AddHttpMessageHandler(() => recorder);
        return (builder.Services.BuildServiceProvider().GetRequiredService<IApprovalClient>(), recorder);
    }

    [Fact]
    public async Task Small_change_is_approved_per_consumer_example()
    {
        var (client, _) = CreateClient();
        var decision = await client.RequestApprovalAsync(new ApprovalRequest("CR-1003", "CHOKE_CHANGE", 50), CancellationToken.None);
        Assert.Equal(("A-7003", "APPROVED"), (decision.Id, decision.Decision));
    }

    [Fact]
    public async Task Large_change_is_rejected_per_consumer_example()
    {
        var (client, _) = CreateClient();
        var decision = await client.RequestApprovalAsync(new ApprovalRequest("CR-1004", "WORKOVER", 900), CancellationToken.None);
        Assert.Equal("REJECTED", decision.Decision);
        Assert.False(string.IsNullOrWhiteSpace(decision.Reason));
    }

    [Fact]
    public async Task Request_that_breaks_the_contract_is_rejected_by_the_stub()
    {
        // "BOGUS" is not in the ChangeType enum: the stub answers 400 and the client raises.
        var (client, _) = CreateClient();
        await Assert.ThrowsAsync<DownstreamException>(() =>
            client.RequestApprovalAsync(new ApprovalRequest("CR-1003", "BOGUS", 50), CancellationToken.None));
    }

    [Fact]
    public async Task Interaction_without_an_example_is_refused_in_strict_mode()
    {
        var (client, _) = CreateClient();
        await Assert.ThrowsAsync<DownstreamException>(() =>
            client.RequestApprovalAsync(new ApprovalRequest("CR-1999", "SHUT_IN", 10), CancellationToken.None));
    }

    [Fact]
    public async Task Consumer_posts_json_with_the_configured_token_to_the_v2_path()
    {
        var (client, recorder) = CreateClient();
        await client.RequestApprovalAsync(new ApprovalRequest("CR-1003", "CHOKE_CHANGE", 50), CancellationToken.None);

        var request = Assert.Single(recorder.Requests);
        Assert.Equal(("POST", "Bearer test-token-123"), (request.Method, request.Authorization));
        Assert.EndsWith("/v2/approvals", request.Url);
    }
}
