using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Prototype.ServiceDefaults;

/// <summary>
/// Plumbing shared by all four services: strict JSON, ProblemDetails errors,
/// a fixed test bearer token, and Kubernetes-style /liveness and /readiness probes.
/// </summary>
public static class ServiceDefaultsExtensions
{
    public static WebApplicationBuilder AddPrototypeDefaults(this WebApplicationBuilder builder)
    {
        builder.Services.AddProblemDetails();
        builder.Services.AddSingleton(TimeProvider.System);
        builder.Services.ConfigureHttpJsonOptions(o => Json.Configure(o.SerializerOptions));
        return builder;
    }

    public static WebApplication UsePrototypeDefaults(this WebApplication app)
    {
        // Unhandled exceptions -> 500 ProblemDetails.
        app.UseExceptionHandler();
        // Empty-body 4xx/5xx (e.g. unknown route, malformed JSON body) -> ProblemDetails.
        app.UseStatusCodePages();
        app.UseMiddleware<TestBearerTokenMiddleware>();
        // Probes for the orchestrator, not part of the API contract (no auth, not under /v2).
        app.MapGet("/liveness", () => Results.Ok(new { status = "UP" }));
        app.MapGet("/readiness", () => Results.Ok(new { status = "READY" }));
        return app;
    }

    /// <summary>
    /// Registers a typed HttpClient for a downstream provider, sending the test token.
    /// The base URL includes the provider's base path (e.g. http://localhost:5101/v2/) and clients
    /// use relative paths ("wells/W-001"), so pointing at a stub is a config change only.
    /// </summary>
    public static IHttpClientBuilder AddDownstreamClient<TClient, TImplementation>(
        this WebApplicationBuilder builder, string baseUrlKey)
        where TClient : class
        where TImplementation : class, TClient
    {
        var baseUrl = builder.Configuration[baseUrlKey]
            ?? throw new InvalidOperationException($"Missing configuration '{baseUrlKey}'.");
        var token = builder.Configuration["Downstream:Token"];
        return builder.Services.AddHttpClient<TClient, TImplementation>(client =>
        {
            client.BaseAddress = new Uri(baseUrl.EndsWith('/') ? baseUrl : baseUrl + "/");
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
            // Default 5 s; contract tests against cold Specmatic mocks raise it (Phase 7 flake finding).
            client.Timeout = TimeSpan.FromSeconds(builder.Configuration.GetValue("Downstream:TimeoutSeconds", 5));
        });
    }
}

public static class Json
{
    /// <summary>Strict settings so that wrong types or unknown enum values are rejected, not coerced.</summary>
    public static void Configure(JsonSerializerOptions options)
    {
        options.NumberHandling = JsonNumberHandling.Strict;              // "123" is not a number
        options.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;
        options.RespectNullableAnnotations = true;                       // null not allowed for non-nullable members
        options.RespectRequiredConstructorParameters = true;             // missing ctor params fail (consumer DTOs)
        options.Converters.Add(new JsonStringEnumConverter(namingPolicy: null, allowIntegerValues: false));
    }

    public static readonly JsonSerializerOptions Options = Create();

    private static JsonSerializerOptions Create()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        Configure(options);
        return options;
    }
}

/// <summary>
/// Stand-in for OAuth2: every endpoint except the probes needs "Authorization: Bearer &lt;Auth:Token&gt;".
/// </summary>
public sealed class TestBearerTokenMiddleware(RequestDelegate next, IConfiguration configuration)
{
    private readonly string _expected = "Bearer " + (configuration["Auth:Token"]
        ?? throw new InvalidOperationException("Missing configuration 'Auth:Token'."));

    public async Task InvokeAsync(HttpContext context)
    {
        if (context.Request.Path.StartsWithSegments("/liveness")
            || context.Request.Path.StartsWithSegments("/readiness")
            || context.Request.Headers.Authorization.ToString() == _expected)
        {
            await next(context);
            return;
        }

        context.Response.Headers.WWWAuthenticate = "Bearer";
        await Results.Problem(
                statusCode: StatusCodes.Status401Unauthorized,
                title: "Unauthorized",
                detail: "Missing or invalid bearer token.")
            .ExecuteAsync(context);
    }
}

/// <summary>A downstream provider was unreachable or answered with an unexpected status/body.</summary>
public sealed class DownstreamException(string provider, string message, Exception? inner = null)
    : Exception($"{provider}: {message}", inner);

public static class Downstream
{
    /// <summary>Sends a request and turns transport failures into <see cref="DownstreamException"/>.</summary>
    public static async Task<HttpResponseMessage> SendAsync(
        string provider, Func<Task<HttpResponseMessage>> send)
    {
        try
        {
            return await send();
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
        {
            throw new DownstreamException(provider, "unreachable or timed out", ex);
        }
    }

    public static async Task<T> ReadAsync<T>(string provider, HttpResponseMessage response, CancellationToken ct)
    {
        try
        {
            return await response.Content.ReadFromJsonAsync<T>(Json.Options, ct)
                ?? throw new DownstreamException(provider, "empty response body");
        }
        catch (JsonException ex)
        {
            // A provider response that does not match what this consumer relies on.
            throw new DownstreamException(provider, $"response did not match the expected shape ({ex.Message})", ex);
        }
    }

    public static IResult Problem(DownstreamException ex) =>
        Results.Problem(statusCode: StatusCodes.Status502BadGateway, title: "Upstream service error", detail: ex.Message);
}
