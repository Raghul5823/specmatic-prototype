using Prototype.ContractTesting;

namespace WellRegistryService.ContractTests;

/// <summary>
/// Provider contract test: the real WellRegistryService must satisfy its contract in contracts/ (incl. every
/// consumer-contributed example). Fails if Specmatic reports any failure.
/// </summary>
[Trait("Category", "ProviderContract")]
public class WellRegistryContractTests
{
    [Fact]
    public void Provider_satisfies_its_contract()
    {
        using var service = ServiceProcess.Start("app-a-production/well-registry-service", "WellRegistryService", 5101);
        var run = Specmatic.Test("well-registry-service", spec: "specs/app-a-production/well-registry-service.yaml", port: 5101);

        Assert.True(run.ExitCode == 0, run.Summary);
    }
}