namespace ApprovalService;

public enum ChangeType { CHOKE_CHANGE, WORKOVER, SHUT_IN }

public enum Decision { APPROVED, REJECTED }

public sealed record Approval(
    string Id,
    string ChangeRequestId,
    Decision Decision,
    string Reason,
    DateTimeOffset DecidedAt);

public sealed record CreateApprovalRequest(
    string? ChangeRequestId = null,
    ChangeType? Type = null,
    double? CapacityDeltaBbl = null);
