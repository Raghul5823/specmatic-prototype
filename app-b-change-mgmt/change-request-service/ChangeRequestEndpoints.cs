using Prototype.ServiceDefaults;

namespace ChangeRequestService;

public static class ChangeRequestEndpoints
{
    public static void MapChangeRequestEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/change-requests");

        // Makes downstream calls (production-forecast, approval).
        group.MapPost("/", async (CreateChangeRequestRequest request, ChangeRequestManager manager, CancellationToken ct) =>
        {
            try
            {
                var result = await manager.CreateAsync(request, ct);
                return result.Errors is not null
                    ? Results.ValidationProblem(result.Errors)
                    : Results.Created($"/change-requests/{result.ChangeRequest!.Id}", result.ChangeRequest);
            }
            catch (DownstreamException ex)
            {
                return Downstream.Problem(ex);
            }
        });

        // Called by production-forecast-service (App A). Makes NO downstream calls, so no call loop is possible.
        group.MapGet("/", (string? wellId, string? status, ChangeRequestManager manager) =>
        {
            var errors = new Dictionary<string, string[]>();
            if (wellId is not null && !ChangeRequestManager.WellIdPattern().IsMatch(wellId))
                errors["wellId"] = ["wellId must match W-000."];
            ChangeStatus? filter = null;
            if (status is not null)
            {
                if (Enum.GetNames<ChangeStatus>().Contains(status))
                    filter = Enum.Parse<ChangeStatus>(status);
                else
                    errors["status"] = [$"status must be one of {string.Join(", ", Enum.GetNames<ChangeStatus>())}."];
            }
            return errors.Count > 0 ? Results.ValidationProblem(errors) : Results.Ok(manager.List(wellId, filter));
        });

        group.MapGet("/{changeRequestId}", (string changeRequestId, ChangeRequestManager manager) =>
        {
            if (!ChangeRequestManager.ChangeRequestIdPattern().IsMatch(changeRequestId))
                return Results.ValidationProblem(
                    new Dictionary<string, string[]> { ["changeRequestId"] = ["changeRequestId must match CR-0000."] });
            return manager.Get(changeRequestId) is { } changeRequest
                ? Results.Ok(changeRequest)
                : Results.Problem(statusCode: 404, title: "Not Found", detail: $"Change request {changeRequestId} does not exist.");
        });
    }
}
