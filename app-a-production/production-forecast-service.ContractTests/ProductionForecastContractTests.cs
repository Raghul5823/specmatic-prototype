using Prototype.ContractTesting;

namespace ProductionForecastService.ContractTests;

/// <summary>
/// Provider contract test: the real ProductionForecastService must satisfy its contract in contracts/ (incl. every
/// consumer-contributed example). Fails if Specmatic reports any failure.
/// </summary>
[Trait("Category", "ProviderContract")]
public class ProductionForecastContractTests
{
    [Fact]
    public void Provider_satisfies_its_contract()
    {
        // Dependencies (well-registry, and change-request from App B) are Specmatic mocks from the same config,
        // warmed up with one real example request each.
        using var mocks = Specmatic.StartDependencyMocks("production-forecast", "specmatic/production-forecast.specmatic.yaml",
            [9101, 9201],
            "http://localhost:9101/v2/wells/W-001",
            "http://localhost:9201/v2/change-requests?wellId=W-001&status=APPROVED");
        using var service = ServiceProcess.Start("app-a-production/production-forecast-service", "ProductionForecastService", 5102,
            new Dictionary<string, string>
            {
                ["Downstream__WellRegistryBaseUrl"] = "http://localhost:9101/v2/",
                ["Downstream__ChangeRequestBaseUrl"] = "http://localhost:9201/v2/",
                ["Downstream__TimeoutSeconds"] = "30",   // budget: service waits up to 30 s on a mock ...
            });
        // ... and Specmatic waits up to 90 s on the service, so a slow mock can't look like an unreachable provider.
        var run = Specmatic.Test("production-forecast-service", config: "specmatic/production-forecast.specmatic.yaml", timeoutMs: 90_000);

        Assert.True(run.ExitCode == 0, run.Summary);
    }
}
