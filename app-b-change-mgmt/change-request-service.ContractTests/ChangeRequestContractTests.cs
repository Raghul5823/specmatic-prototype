using Prototype.ContractTesting;

namespace ChangeRequestService.ContractTests;

/// <summary>
/// Provider contract test: the real ChangeRequestService must satisfy its contract in contracts/ (incl. every
/// consumer-contributed example). Fails if Specmatic reports any failure.
/// </summary>
[Trait("Category", "ProviderContract")]
public class ChangeRequestContractTests
{
    [Fact]
    public void Provider_satisfies_its_contract()
    {
        // Dependencies (approval, and production-forecast from App A) are Specmatic mocks from the same config,
        // warmed up with one real example request each.
        using var mocks = Specmatic.StartDependencyMocks("change-request", "specmatic/change-request.specmatic.yaml",
            [9202, 9102],
            "http://localhost:9202/v2/approvals/A-7001",
            "http://localhost:9102/v2/forecasts/F-5001");
        using var service = ServiceProcess.Start("app-b-change-mgmt/change-request-service", "ChangeRequestService", 5201,
            new Dictionary<string, string>
            {
                ["Downstream__ApprovalBaseUrl"] = "http://localhost:9202/v2/",
                ["Downstream__ProductionForecastBaseUrl"] = "http://localhost:9102/v2/",
                ["Downstream__TimeoutSeconds"] = "30",   // budget: service waits up to 30 s on a mock ...
            });
        // ... and Specmatic waits up to 90 s on the service, so a slow mock can't look like an unreachable provider.
        var run = Specmatic.Test("change-request-service", config: "specmatic/change-request.specmatic.yaml", timeoutMs: 90_000);

        Assert.True(run.ExitCode == 0, run.Summary);
    }
}
