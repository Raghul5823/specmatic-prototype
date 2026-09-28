using System.Text.RegularExpressions;

namespace WellRegistryService;

public sealed partial class WellService(IWellRepository repository)
{
    [GeneratedRegex(@"^W-\d{3}$")]
    public static partial Regex WellIdPattern();

    public IReadOnlyList<Well> List(WellStatus? status) => repository.List(status);

    public Well? Get(string id) => repository.Get(id);

    public Dictionary<string, string[]> Validate(CreateWellRequest request)
    {
        var errors = new Dictionary<string, string[]>();
        if (string.IsNullOrWhiteSpace(request.Name) || request.Name.Length > 100)
            errors["name"] = ["name is required (1-100 characters)."];
        if (string.IsNullOrWhiteSpace(request.Field) || request.Field.Length > 100)
            errors["field"] = ["field is required (1-100 characters)."];
        if (request.Status is null)
            errors["status"] = ["status is required."];
        if (request.Latitude is null or < -90 or > 90)
            errors["latitude"] = ["latitude is required (-90 to 90)."];
        if (request.Longitude is null or < -180 or > 180)
            errors["longitude"] = ["longitude is required (-180 to 180)."];
        if (request.SpudDate is null)
            errors["spudDate"] = ["spudDate is required (yyyy-MM-dd)."];
        if (request.DailyCapacityBbl is null or < 0)
            errors["dailyCapacityBbl"] = ["dailyCapacityBbl is required (>= 0)."];
        return errors;
    }

    /// <summary>Call only after <see cref="Validate"/> returned no errors.</summary>
    public Well Create(CreateWellRequest request)
    {
        var well = new Well(
            repository.NextId(),
            request.Name!.Trim(),
            request.Field!.Trim(),
            request.Status!.Value,
            request.Latitude!.Value,
            request.Longitude!.Value,
            request.SpudDate!.Value,
            request.DailyCapacityBbl!.Value);
        repository.Add(well);
        return well;
    }
}
