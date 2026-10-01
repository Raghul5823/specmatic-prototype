using System.Net.Http.Headers;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.DependencyInjection;
using Prototype.ServiceDefaults;
using WellRegistryService;

namespace WellRegistryService.Tests;

/// <summary>
/// Real in-memory repository wrapped so every call is recorded. This is the internal
/// "endpoint -> service -> repository" traffic that Specmatic, sitting outside on HTTP, never sees.
/// </summary>
public sealed class RecordingWellRepository : IWellRepository
{
    private readonly InMemoryWellRepository _inner = new();
    public List<string> Calls { get; } = [];

    public IReadOnlyList<Well> List(WellStatus? status) { Calls.Add($"List({status?.ToString() ?? "null"})"); return _inner.List(status); }
    public Well? Get(string id) { Calls.Add($"Get({id})"); return _inner.Get(id); }
    public string NextId() { var id = _inner.NextId(); Calls.Add($"NextId()={id}"); return id; }
    public void Add(Well well) { Calls.Add($"Add({well.Id})"); _inner.Add(well); }
}

/// <summary>
/// Hosts the real well-registry endpoints in-process on a random port, with the recording
/// repository injected. No extra NuGet packages: uses the ASP.NET Core shared framework.
/// </summary>
public sealed class WellApiHost : IAsyncDisposable
{
    public const string Token = "test-token-123";
    private readonly WebApplication _app;
    public RecordingWellRepository Repository { get; }
    public HttpClient Client { get; }

    private WellApiHost(WebApplication app, HttpClient client, RecordingWellRepository repository)
    {
        _app = app;
        Client = client;
        Repository = repository;
    }

    public static async Task<WellApiHost> StartAsync()
    {
        var builder = WebApplication.CreateBuilder(new WebApplicationOptions { EnvironmentName = "Testing" });
        builder.Configuration["Urls"] = "http://127.0.0.1:0";   // random free port, never 5101
        builder.Configuration["Auth:Token"] = Token;
        builder.AddPrototypeDefaults();

        var repository = new RecordingWellRepository();
        builder.Services.AddSingleton<IWellRepository>(repository);
        builder.Services.AddSingleton<WellService>();

        var app = builder.Build();
        app.UsePrototypeDefaults();
        app.MapWellEndpoints();
        await app.StartAsync();

        var address = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.First();
        var client = new HttpClient { BaseAddress = new Uri(address) };
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", Token);
        return new WellApiHost(app, client, repository);
    }

    public async ValueTask DisposeAsync()
    {
        Client.Dispose();
        await _app.StopAsync();
        await _app.DisposeAsync();
    }
}
