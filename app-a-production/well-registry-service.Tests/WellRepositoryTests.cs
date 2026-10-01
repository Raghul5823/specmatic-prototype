using WellRegistryService;

namespace WellRegistryService.Tests;

/// <summary>Repository layer: data rules that are invisible over HTTP.</summary>
public class WellRepositoryTests
{
    [Fact]
    public void Seed_contains_three_wells()
    {
        var repository = new InMemoryWellRepository();
        Assert.Equal(["W-001", "W-002", "W-003"], repository.List(null).Select(w => w.Id));
    }

    [Fact]
    public void List_filters_by_status()
    {
        var repository = new InMemoryWellRepository();
        var shutIn = repository.List(WellStatus.SHUT_IN);
        Assert.Equal("W-003", Assert.Single(shutIn).Id);
    }

    [Fact]
    public void NextId_is_sequential_and_zero_padded()
    {
        var repository = new InMemoryWellRepository();
        Assert.Equal("W-004", repository.NextId());
        Assert.Equal("W-005", repository.NextId());
    }
}
