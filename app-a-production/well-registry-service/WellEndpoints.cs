namespace WellRegistryService;

public static class WellEndpoints
{
    public static void MapWellEndpoints(this IEndpointRouteBuilder app)
    {
        var wells = app.MapGroup("/wells");

        // status is bound as a string and parsed strictly (Enum.TryParse would accept "1" or "active").
        wells.MapGet("/", (string? status, WellService service) =>
        {
            WellStatus? filter = null;
            if (status is not null)
            {
                if (!Enum.GetNames<WellStatus>().Contains(status))
                    return Results.ValidationProblem(
                        new Dictionary<string, string[]> { ["status"] = [$"status must be one of {string.Join(", ", Enum.GetNames<WellStatus>())}."] });
                filter = Enum.Parse<WellStatus>(status);
            }
            return Results.Ok(service.List(filter));
        });

        wells.MapGet("/{wellId}", (string wellId, WellService service) =>
        {
            if (!WellService.WellIdPattern().IsMatch(wellId))
                return Results.ValidationProblem(
                    new Dictionary<string, string[]> { ["wellId"] = ["wellId must match W-000."] });
            return service.Get(wellId) is { } well
                ? Results.Ok(well)
                : Results.Problem(statusCode: 404, title: "Not Found", detail: $"Well {wellId} does not exist.");
        });

        wells.MapPost("/", (CreateWellRequest request, WellService service) =>
        {
            var errors = service.Validate(request);
            if (errors.Count > 0)
                return Results.ValidationProblem(errors);
            var well = service.Create(request);
            return Results.Created($"/wells/{well.Id}", well);
        });
    }
}
