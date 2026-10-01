using System.Net;
using System.Net.Http.Json;

namespace WellRegistryService.Tests;

/// <summary>
/// Endpoint layer, hosted in-process: checks WHICH internal calls an HTTP request causes.
/// Specmatic sees the same HTTP request and response, but not the repository calls asserted here.
/// </summary>
public class WellEndpointTests
{
    [Fact]
    public async Task Get_by_id_reads_the_repository_exactly_once()
    {
        await using var host = await WellApiHost.StartAsync();

        var response = await host.Client.GetAsync("v2/wells/W-001");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(["Get(W-001)"], host.Repository.Calls);
    }

    [Fact]
    public async Task Invalid_id_is_rejected_before_reaching_the_repository()
    {
        await using var host = await WellApiHost.StartAsync();

        var response = await host.Client.GetAsync("v2/wells/WELL-1");

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Empty(host.Repository.Calls);
    }

    [Fact]
    public async Task Invalid_body_never_writes_to_the_repository()
    {
        await using var host = await WellApiHost.StartAsync();

        var response = await host.Client.PostAsJsonAsync("v2/wells", new { field = "Eagle Ford" });

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.DoesNotContain(host.Repository.Calls, c => c.StartsWith("Add("));
    }

    [Fact]
    public async Task Request_without_token_is_rejected_and_touches_nothing()
    {
        await using var host = await WellApiHost.StartAsync();
        host.Client.DefaultRequestHeaders.Authorization = null;

        var response = await host.Client.GetAsync("v2/wells/W-001");

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        Assert.Empty(host.Repository.Calls);
    }

    [Fact]
    public async Task Status_filter_reaches_the_repository_and_only_matching_wells_are_returned()
    {
        await using var host = await WellApiHost.StartAsync();

        var wells = await host.Client.GetFromJsonAsync<List<Dictionary<string, object>>>("v2/wells?status=SHUT_IN");

        Assert.Equal(["List(SHUT_IN)"], host.Repository.Calls);
        Assert.Equal("W-003", Assert.Single(wells!)["id"].ToString());
    }
}
