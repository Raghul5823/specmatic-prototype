namespace WellRegistryService;

public interface IWellRepository
{
    IReadOnlyList<Well> List(WellStatus? status);
    Well? Get(string id);
    string NextId();
    void Add(Well well);
}

public sealed class InMemoryWellRepository : IWellRepository
{
    private readonly Lock _lock = new();
    private readonly List<Well> _wells =
    [
        new("W-001", "Eagle-1", "Eagle Ford", WellStatus.ACTIVE, 28.5, -98.3, new DateOnly(2019, 4, 12), 1200),
        new("W-002", "Eagle-2", "Eagle Ford", WellStatus.ACTIVE, 28.6, -98.2, new DateOnly(2020, 8, 1), 800),
        new("W-003", "Permian-7", "Permian Basin", WellStatus.SHUT_IN, 31.9, -102.1, new DateOnly(2015, 2, 20), 0),
    ];
    private int _next = 4;

    public IReadOnlyList<Well> List(WellStatus? status)
    {
        lock (_lock) return _wells.Where(w => status is null || w.Status == status).ToList();
    }

    public Well? Get(string id)
    {
        lock (_lock) return _wells.FirstOrDefault(w => w.Id == id);
    }

    public string NextId()
    {
        lock (_lock) return $"W-{_next++:000}";
    }

    public void Add(Well well)
    {
        lock (_lock) _wells.Add(well);
    }
}
