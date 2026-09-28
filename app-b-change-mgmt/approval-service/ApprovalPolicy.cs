using System.Text.RegularExpressions;

namespace ApprovalService;

public sealed partial class ApprovalPolicy(IApprovalRepository repository, TimeProvider clock)
{
    public const double DelegatedAuthorityBbl = 500;

    [GeneratedRegex(@"^CR-\d{4}$")]
    private static partial Regex ChangeRequestIdPattern();

    [GeneratedRegex(@"^A-\d{4}$")]
    public static partial Regex ApprovalIdPattern();

    public Approval? Get(string id) => repository.Get(id);

    public Dictionary<string, string[]> Validate(CreateApprovalRequest request)
    {
        var errors = new Dictionary<string, string[]>();
        if (request.ChangeRequestId is null || !ChangeRequestIdPattern().IsMatch(request.ChangeRequestId))
            errors["changeRequestId"] = ["changeRequestId is required and must match CR-0000."];
        if (request.Type is null)
            errors["type"] = ["type is required."];
        if (request.CapacityDeltaBbl is null)
            errors["capacityDeltaBbl"] = ["capacityDeltaBbl is required."];
        return errors;
    }

    /// <summary>Auto-decision: changes within +/- 500 bbl/d are approved, larger ones rejected.</summary>
    public Approval Decide(CreateApprovalRequest request)
    {
        var withinAuthority = Math.Abs(request.CapacityDeltaBbl!.Value) <= DelegatedAuthorityBbl;
        var approval = new Approval(
            repository.NextId(),
            request.ChangeRequestId!,
            withinAuthority ? Decision.APPROVED : Decision.REJECTED,
            withinAuthority
                ? "Within delegated authority (<= 500 bbl/d)."
                : "Exceeds delegated authority (> 500 bbl/d); needs manual review.",
            clock.GetUtcNow());
        repository.Add(approval);
        return approval;
    }
}
