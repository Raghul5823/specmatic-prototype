using Prototype.ServiceDefaults;

namespace ProductionForecastService;

public static class ForecastEndpoints
{
    public static void MapForecastEndpoints(this IEndpointRouteBuilder app)
    {
        var forecasts = app.MapGroup("/forecasts");

        // Makes downstream calls (well-registry, change-request).
        forecasts.MapPost("/", async (CreateForecastRequest request, ForecastService service, CancellationToken ct) =>
        {
            try
            {
                var result = await service.CreateAsync(request, ct);
                return result.Errors is not null
                    ? Results.ValidationProblem(result.Errors)
                    : Results.Created($"/forecasts/{result.Forecast!.Id}", result.Forecast);
            }
            catch (DownstreamException ex)
            {
                return Downstream.Problem(ex);
            }
        });

        // Called by change-request-service (App B). Makes NO downstream calls, so no call loop is possible.
        forecasts.MapGet("/{forecastId}", (string forecastId, ForecastService service) =>
        {
            if (!ForecastService.ForecastIdPattern().IsMatch(forecastId))
                return Results.ValidationProblem(
                    new Dictionary<string, string[]> { ["forecastId"] = ["forecastId must match F-0000."] });
            return service.Get(forecastId) is { } forecast
                ? Results.Ok(forecast)
                : Results.Problem(statusCode: 404, title: "Not Found", detail: $"Forecast {forecastId} does not exist.");
        });
    }
}
