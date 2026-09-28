namespace ApprovalService;

public interface IApprovalRepository
{
    Approval? Get(string id);
    string NextId();
    void Add(Approval approval);
}

public sealed class InMemoryApprovalRepository : IApprovalRepository
{
    private readonly Lock _lock = new();
    private readonly List<Approval> _approvals =
    [
        new("A-7001", "CR-1001", Decision.APPROVED, "Within delegated authority (<= 500 bbl/d).",
            new DateTimeOffset(2026, 9, 1, 8, 0, 1, TimeSpan.Zero)),
        new("A-7002", "CR-1002", Decision.REJECTED, "Exceeds delegated authority (> 500 bbl/d); needs manual review.",
            new DateTimeOffset(2026, 9, 3, 10, 30, 1, TimeSpan.Zero)),
    ];
    private int _next = 7003;

    public Approval? Get(string id)
    {
        lock (_lock) return _approvals.FirstOrDefault(a => a.Id == id);
    }

    public string NextId()
    {
        lock (_lock) return $"A-{_next++}";
    }

    public void Add(Approval approval)
    {
        lock (_lock) _approvals.Add(approval);
    }
}
