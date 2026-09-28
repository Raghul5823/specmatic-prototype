namespace ChangeRequestService;

public interface IChangeRequestRepository
{
    IReadOnlyList<ChangeRequest> List(string? wellId, ChangeStatus? status);
    ChangeRequest? Get(string id);
    string NextId();
    void Add(ChangeRequest changeRequest);
}

public sealed class InMemoryChangeRequestRepository : IChangeRequestRepository
{
    private readonly Lock _lock = new();
    private readonly List<ChangeRequest> _items =
    [
        new("CR-1001", "Open choke on Eagle-1", "W-001", null, ChangeType.CHOKE_CHANGE, 150, "j.doe",
            ChangeStatus.APPROVED, "A-7001", "Within delegated authority (<= 500 bbl/d).",
            new DateTimeOffset(2026, 9, 1, 8, 0, 0, TimeSpan.Zero)),
        new("CR-1002", "Workover Eagle-1", "W-001", "F-5001", ChangeType.WORKOVER, 900, "a.khan",
            ChangeStatus.REJECTED, "A-7002", "Exceeds delegated authority (> 500 bbl/d); needs manual review.",
            new DateTimeOffset(2026, 9, 3, 10, 30, 0, TimeSpan.Zero)),
    ];
    private int _next = 1003;

    public IReadOnlyList<ChangeRequest> List(string? wellId, ChangeStatus? status)
    {
        lock (_lock)
            return _items
                .Where(c => wellId is null || c.WellId == wellId)
                .Where(c => status is null || c.Status == status)
                .ToList();
    }

    public ChangeRequest? Get(string id)
    {
        lock (_lock) return _items.FirstOrDefault(c => c.Id == id);
    }

    public string NextId()
    {
        lock (_lock) return $"CR-{_next++}";
    }

    public void Add(ChangeRequest changeRequest)
    {
        lock (_lock) _items.Add(changeRequest);
    }
}
