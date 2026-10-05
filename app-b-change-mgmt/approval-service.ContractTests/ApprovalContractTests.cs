using Prototype.ContractTesting;

namespace ApprovalService.ContractTests;

/// <summary>
/// Provider contract test: the real ApprovalService must satisfy its contract in contracts/ (incl. every
/// consumer-contributed example). Fails if Specmatic reports any failure.
/// </summary>
[Trait("Category", "ProviderContract")]
public class ApprovalContractTests
{
    [Fact]
    public void Provider_satisfies_its_contract()
    {
        using var service = ServiceProcess.Start("app-b-change-mgmt/approval-service", "ApprovalService", 5202);
        var run = Specmatic.Test("approval-service", spec: "specs/app-b-change-mgmt/approval-service.yaml", port: 5202);

        Assert.True(run.ExitCode == 0, run.Summary);
    }
}