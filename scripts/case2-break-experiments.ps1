<#
.SYNOPSIS
  Phase 4: Case 2 break experiments on BOTH sides of the intra-app interactions
  C1 (production-forecast -> well-registry) and C2 (change-request -> approval).
  Consumer breaks run the consumer's tests against a STRICT Specmatic stub;
  provider breaks run Specmatic contract tests against the real provider.
  Writes results\case2\break\summary.md. About 1-2 minutes per experiment.
#>
param([int]$From = 1)
. "$PSScriptRoot\common.ps1"

# TestFilter: only this interaction's tests (the projects also hold the cross-app C3/C4 tests since Phase 5).
$c1 = @{ Mode = 'Consumer'; StubService = 'well-registry-service'; StubPort = 9101; StubConfig = 'specmatic\well-registry.mock.yaml'
         TestProject = 'app-a-production\production-forecast-service.Tests\ProductionForecastService.Tests.csproj'
         TestFilter = 'FullyQualifiedName~WellRegistryClientStubTests' }
$c2 = @{ Mode = 'Consumer'; StubService = 'approval-service'; StubPort = 9202; StubConfig = 'specmatic\approval.mock.yaml'
         TestProject = 'app-b-change-mgmt\change-request-service.Tests\ChangeRequestService.Tests.csproj'
         TestFilter = 'FullyQualifiedName~ApprovalClientStubTests' }
$p2 = @{ Mode = 'Provider'; Service = 'approval-service'; TestProject = '' }
$jsonNs = 'System.Text.Json.Serialization'

$experiments = @(
    @{ Out = '01-consumer-wrong-path'; Side = 'consumer (C1)'; Args = $c1; Expected = 'caught by stub'
       Name = 'Consumer calls GET /v2/well/{id} instead of /v2/wells/{id}'
       Changes = @(@{ File = 'app-a-production\production-forecast-service\Clients.cs'; Find = '$"wells/{Uri.EscapeDataString(wellId)}"'; Replace = '$"well/{Uri.EscapeDataString(wellId)}"' }) }
    @{ Out = '02-consumer-expects-extra-field'; Side = 'consumer (C1)'; Args = $c1; Expected = 'caught (field not in contract)'
       Name = 'Consumer starts relying on a field the contract does not have (WellSummary.Operator)'
       Changes = @(@{ File = 'app-a-production\production-forecast-service\Models.cs'; Find = 'public sealed record WellSummary(string Id, string Name, string Status, double DailyCapacityBbl);'; Replace = 'public sealed record WellSummary(string Id, string Name, string Status, double DailyCapacityBbl, string Operator);' }) }
    @{ Out = '03-consumer-wrong-auth-scheme'; Side = 'consumer (C1)'; Args = $c1; Expected = 'only the token-recording test (T5)'
       Name = 'Consumer sends "Authorization: Token ..." instead of "Bearer ..."'
       Changes = @(@{ File = 'shared\Prototype.ServiceDefaults\ServiceDefaults.cs'; Find = 'new AuthenticationHeaderValue("Bearer", token)'; Replace = 'new AuthenticationHeaderValue("Token", token)' }) }
    @{ Out = '04-consumer-renames-request-field'; Side = 'consumer (C2)'; Args = $c2; Expected = 'caught by stub'
       Name = 'Consumer sends capacityDelta instead of required capacityDeltaBbl'
       Changes = @(@{ File = 'app-b-change-mgmt\change-request-service\Models.cs'; Find = 'public sealed record ApprovalRequest(string ChangeRequestId, string Type, double CapacityDeltaBbl);'; Replace = 'public sealed record ApprovalRequest(string ChangeRequestId, string Type, double CapacityDelta);' }) }
    @{ Out = '05-provider-renames-decision'; Side = 'provider (C2)'; Args = $p2; Expected = 'caught by provider test'
       Name = 'Provider renames response field decision -> outcome'
       Changes = @(@{ File = 'app-b-change-mgmt\approval-service\Models.cs'; Find = '    Decision Decision,'; Replace = "    [property: $jsonNs.JsonPropertyName(`"outcome`")] Decision Decision," }) }
    @{ Out = '06-provider-changes-status'; Side = 'provider (C2)'; Args = $p2; Expected = 'caught by provider test'
       Name = 'Provider returns 200 instead of 201 for POST /approvals'
       Changes = @(@{ File = 'app-b-change-mgmt\approval-service\ApprovalEndpoints.cs'; Find = 'return Results.Created($"/v2/approvals/{approval.Id}", approval);'; Replace = 'return Results.Ok(approval);' }) }
)

foreach ($e in $experiments | Select-Object -Skip ($From - 1)) {
    $started = Get-Date
    $a = $e.Args
    & "$PSScriptRoot\break-experiment.ps1" -Name $e.Name -Out "case2\break\$($e.Out)" -Changes $e.Changes -Expected $e.Expected @a
    Write-Host ("  ({0} took {1:n1} min)" -f $e.Out, ((Get-Date) - $started).TotalMinutes)
}

$rows = foreach ($e in $experiments) {
    $f = Join-Path $ResultsDir "case2\break\$($e.Out)\experiment.json"
    if (-not (Test-Path $f)) { continue }
    $r = Get-Content $f -Raw | ConvertFrom-Json
    $caught = if (-not $r.compiled) { 'n/a (did not compile)' }
              elseif ($r.mode -eq 'Consumer') { if ($r.xunitFailed) { '**YES**: consumer tests vs strict stub failed' } else { 'no' } }
              else { if ($r.specmaticCaught) { "**YES**: provider contract test ($($r.specmaticFailures)/$($r.specmaticTests) failed)" } else { 'no' } }
    "| $($e.Side) | $($r.name) | $($r.expected) | $caught | [$($e.Out)](results/case2/break/$($e.Out)/) |"
}
$md = @('| Side | Change | Expected | Caught? | Evidence |', '|---|---|---|---|---|') + $rows
$md | Set-Content -Encoding utf8 (Join-Path $ResultsDir 'case2\break\summary.md')
$md
