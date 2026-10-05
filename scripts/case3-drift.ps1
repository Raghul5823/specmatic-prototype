<#
.SYNOPSIS
  Phase 5: DRIFT between code and the central contract repo, both directions.
  D1  Provider code changes, contract NOT updated: production-forecast renames response field
      wellId -> well_id (C3's consumer change-request relies on wellId).
        a) provider contract test (deps mocked)        -> expected FAIL  (drift caught in provider pipeline)
        b) consumer tests vs stub built from contract   -> expected PASS  (consumer cannot see it)
        c) real services end to end                     -> expected 502   (what happens if (a) is skipped)
  D2  Contract changes, provider code NOT updated: the contract clone's branch renames wellId -> wellID.
        provider contract test against that branch      -> expected FAIL
  Restores original bytes and rebuilds at the end. Output -> results\case3\drift\
.PARAMETER ContractClone
  Git checkout of the contracts repo on branch feature/breaking-rename-field (for D2).
#>
param([Parameter(Mandatory)] [string]$ContractClone)
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\common.ps1"
$out = Join-Path $ResultsDir 'case3\drift'
New-Item -ItemType Directory -Force $out | Out-Null
$summary = [ordered]@{}

$models = Join-Path $Root 'app-a-production\production-forecast-service\Models.cs'
$project = 'app-a-production\production-forecast-service\ProductionForecastService.csproj'
$original = [IO.File]::ReadAllBytes($models)
$find = "    string WellId,`n    string WellName,"
$text = [IO.File]::ReadAllText($models)
if (([regex]::Matches($text, [regex]::Escape($find))).Count -ne 1) { throw 'D1 change text not found exactly once' }

try {
    # ---------- D1: provider drifts from the contract ----------
    & "$PSScriptRoot\stop-services.ps1" | Out-Null
    [IO.File]::WriteAllText($models, $text.Replace($find, "    [property: System.Text.Json.Serialization.JsonPropertyName(`"well_id`")] string WellId,`n    string WellName,"))
    dotnet build (Join-Path $Root $project) -nologo -v q | Out-Null   # only the changed service

    # D1a provider test with mocked dependencies (timeout budget from Phase 7: Specmatic 90 s > service 30 s,
    # so a slow cold mock cannot make the test fail for the wrong reason)
    & "$PSScriptRoot\deps.ps1" start production-forecast -Config specmatic\production-forecast.specmatic.yaml -Ports 9101, 9201 | Out-Null
    & "$PSScriptRoot\start-services.ps1" -Only production-forecast-service -NoBuild -Env @{ Downstream__WellRegistryBaseUrl = 'http://localhost:9101/v2/'; Downstream__ChangeRequestBaseUrl = 'http://localhost:9201/v2/'; Downstream__TimeoutSeconds = '30' } | Out-Null
    & "$PSScriptRoot\run-provider-test.ps1" -Service production-forecast-service -Out 'case3\drift\d1a-provider-test' -Config specmatic\production-forecast.specmatic.yaml -ExtraArgs @('--timeout-in-ms=90000') | Out-Null
    $s = Get-Content (Join-Path $out 'd1a-provider-test\summary.json') -Raw | ConvertFrom-Json
    $summary.d1a_provider_test = "exit=$($s.exitCode) tests=$($s.testsRun) failures=$($s.failures)"
    & "$PSScriptRoot\deps.ps1" stop production-forecast | Out-Null
    & "$PSScriptRoot\stop-services.ps1" | Out-Null

    # D1b consumer (change-request) tests against the stub built from the (unchanged) contract
    & "$PSScriptRoot\stub.ps1" start production-forecast-service 9102 -Strict -Config specmatic\production-forecast.mock.yaml | Out-Null
    $c = dotnet test (Join-Path $Root 'app-b-change-mgmt\change-request-service.Tests\ChangeRequestService.Tests.csproj') --no-build -nologo -v q --filter 'FullyQualifiedName~ProductionForecastClientStubTests' 2>&1 | ForEach-Object { "$_".Replace($Root, '.') }
    $summary.d1b_consumer_stub_tests = "exit=$LASTEXITCODE $(($c | Select-String 'Passed!|Failed!' | Select-Object -First 1).Line.Trim())"
    $c | Set-Content -Encoding utf8 (Join-Path $out 'd1b-consumer-stub-tests.txt')
    & "$PSScriptRoot\stub.ps1" stop production-forecast-service | Out-Null

    # D1c real services end to end: change-request -> (drifted) production-forecast
    & "$PSScriptRoot\start-services.ps1" -NoBuild | Out-Null
    # The JSON goes through a file: Windows PowerShell 5.1 strips the inner double quotes of an argument passed
    # to a native program, so `-d $body` sent invalid JSON there (400 instead of 502; found by the Phase 8a evidence run).
    $bodyFile = Join-Path $out 'd1c-request.json'
    [IO.File]::WriteAllText($bodyFile, '{"title":"Choke tweak","wellId":"W-001","forecastId":"F-5001","type":"CHOKE_CHANGE","capacityDeltaBbl":50,"requestedBy":"qa.user"}')
    $resp = curl.exe -s -i -X POST -H "Authorization: Bearer $TestToken" -H 'Content-Type: application/json' --data-binary "@$bodyFile" http://localhost:5201/v2/change-requests
    $resp | Set-Content -Encoding utf8 (Join-Path $out 'd1c-real-integration.txt')
    $summary.d1c_real_integration = ($resp | Select-Object -First 1)
    & "$PSScriptRoot\stop-services.ps1" | Out-Null
}
finally {
    [IO.File]::WriteAllBytes($models, $original)
    dotnet build (Join-Path $Root $project) -nologo -v q | Out-Null
}

# ---------- D2: contract changes, provider code not updated ----------
& "$PSScriptRoot\start-services.ps1" -NoBuild | Out-Null
& "$PSScriptRoot\run-provider-test.ps1" -Service production-forecast-service -Out 'case3\drift\d2-provider-vs-new-contract' -ContractsDir $ContractClone | Out-Null
$s = Get-Content (Join-Path $out 'd2-provider-vs-new-contract\summary.json') -Raw | ConvertFrom-Json
$summary.d2_provider_vs_changed_contract = "exit=$($s.exitCode) tests=$($s.testsRun) failures=$($s.failures)"
& "$PSScriptRoot\stop-services.ps1" | Out-Null

$summary | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $out 'summary.json')
$summary
