namespace ChangeRequestService;

public enum ChangeType { CHOKE_CHANGE, WORKOVER, SHUT_IN }

// Approval is synchronous, so a stored change request is always decided.
public enum ChangeStatus { APPROVED, REJECTED }

public sealed record ChangeRequest(
    string Id,
    string Title,
    string WellId,
    string? ForecastId,
    ChangeType Type,
    double CapacityDeltaBbl,
    string RequestedBy,
    ChangeStatus Status,
    string ApprovalId,
    string DecisionReason,
    DateTimeOffset CreatedAt);

public sealed record CreateChangeRequestRequest(
    string? Title = null,
    string? WellId = null,
    string? ForecastId = null,
    ChangeType? Type = null,
    double? CapacityDeltaBbl = null,
    string? RequestedBy = null);

// Consumer views of provider data: only the fields this service relies on.

/// <summary>From production-forecast-service GET /forecasts/{forecastId}.</summary>
public sealed record ForecastSummary(string Id, string WellId);

/// <summary>Sent to approval-service POST /approvals.</summary>
public sealed record ApprovalRequest(string ChangeRequestId, string Type, double CapacityDeltaBbl);

/// <summary>From approval-service POST /approvals.</summary>
public sealed record ApprovalDecision(string Id, string Decision, string Reason);
