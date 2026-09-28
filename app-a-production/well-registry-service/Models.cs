namespace WellRegistryService;

public enum WellStatus { ACTIVE, SHUT_IN, ABANDONED }

public sealed record Well(
    string Id,
    string Name,
    string Field,
    WellStatus Status,
    double Latitude,
    double Longitude,
    DateOnly SpudDate,
    double DailyCapacityBbl);

// All members optional so the service can report every missing field in one 400 response.
public sealed record CreateWellRequest(
    string? Name = null,
    string? Field = null,
    WellStatus? Status = null,
    double? Latitude = null,
    double? Longitude = null,
    DateOnly? SpudDate = null,
    double? DailyCapacityBbl = null);
