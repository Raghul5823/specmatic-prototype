using WellRegistryService;

namespace WellRegistryService.Tests;

/// <summary>Service layer: validation rules and the order of repository calls.</summary>
public class WellServiceTests
{
    private static CreateWellRequest ValidRequest() =>
        new("Eagle-9", "Eagle Ford", WellStatus.ACTIVE, 28.7, -98.1, new DateOnly(2024, 5, 1), 650);

    [Fact]
    public void Validate_reports_every_missing_field_at_once()
    {
        var service = new WellService(new RecordingWellRepository());
        var errors = service.Validate(new CreateWellRequest());
        Assert.Equal(
            ["name", "field", "status", "latitude", "longitude", "spudDate", "dailyCapacityBbl"],
            errors.Keys);
    }

    [Theory]
    [InlineData(91, -98.1)]
    [InlineData(28.7, -181)]
    public void Validate_rejects_coordinates_out_of_range(double latitude, double longitude)
    {
        var service = new WellService(new RecordingWellRepository());
        var errors = service.Validate(ValidRequest() with { Latitude = latitude, Longitude = longitude });
        Assert.NotEmpty(errors);
    }

    [Fact]
    public void Create_asks_for_an_id_first_then_adds_the_well_once()
    {
        var repository = new RecordingWellRepository();
        var service = new WellService(repository);

        var well = service.Create(ValidRequest());

        Assert.Equal("W-004", well.Id);
        Assert.Equal(["NextId()=W-004", "Add(W-004)"], repository.Calls);
    }

    [Fact]
    public void List_passes_the_status_filter_to_the_repository()
    {
        var repository = new RecordingWellRepository();
        new WellService(repository).List(WellStatus.SHUT_IN);
        Assert.Equal(["List(SHUT_IN)"], repository.Calls);
    }
}
