namespace ProductionForecastService;

public interface IForecastRepository
{
    Forecast? Get(string id);
    string NextId();
    void Add(Forecast forecast);
}

public sealed class InMemoryForecastRepository : IForecastRepository
{
    private readonly Lock _lock = new();
    private readonly List<Forecast> _forecasts =
    [
        // W-001: base 1200 + approved CR-1001 (+150) = 1350 bbl/d, 5 %/month decline, 3 months.
        new("F-5001", "W-001", "Eagle-1", 3, 5, 1200, 1350, ["CR-1001"],
            [40500, 38475, 36551.3], 115526.3, new DateTimeOffset(2026, 9, 2, 9, 0, 0, TimeSpan.Zero)),
    ];
    private int _next = 5002;

    public Forecast? Get(string id)
    {
        lock (_lock) return _forecasts.FirstOrDefault(f => f.Id == id);
    }

    public string NextId()
    {
        lock (_lock) return $"F-{_next++}";
    }

    public void Add(Forecast forecast)
    {
        lock (_lock) _forecasts.Add(forecast);
    }
}
