namespace ApprovalService;

public static class ApprovalEndpoints
{
    public static void MapApprovalEndpoints(this IEndpointRouteBuilder app)
    {
        var approvals = app.MapGroup("/v2/approvals");

        approvals.MapPost("/", (CreateApprovalRequest request, ApprovalPolicy policy) =>
        {
            var errors = policy.Validate(request);
            if (errors.Count > 0)
                return Results.ValidationProblem(errors);
            var approval = policy.Decide(request);
            return Results.Created($"/v2/approvals/{approval.Id}", approval);
        });

        approvals.MapGet("/{approvalId}", (string approvalId, ApprovalPolicy policy) =>
        {
            if (!ApprovalPolicy.ApprovalIdPattern().IsMatch(approvalId))
                return Results.ValidationProblem(
                    new Dictionary<string, string[]> { ["approvalId"] = ["approvalId must match A-0000."] });
            return policy.Get(approvalId) is { } approval
                ? Results.Ok(approval)
                : Results.Problem(statusCode: 404, title: "Not Found", detail: $"Approval {approvalId} does not exist.");
        });
    }
}
