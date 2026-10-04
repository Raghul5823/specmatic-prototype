<#
.SYNOPSIS
  Runs Specmatic contract tests (provider mode) against a RUNNING service and saves every
  report into one results folder:
    console.txt   full Specmatic output (requests, responses, coverage table)
    coverage.txt  just the API coverage summary table
    junit/        JUnit XML (for Azure DevOps "Publish Test Results")
    build/reports/specmatic/test/html/index.html   Specmatic's HTML report
    summary.json  parsed totals: tests, successes, failures, coverage, exit code
  contracts/ is mounted READ-ONLY, so Specmatic can never write into the contract repo.
.EXAMPLE
  .\scripts\run-provider-test.ps1 -Service well-registry-service -Out case1\01-baseline
  .\scripts\run-provider-test.ps1 -Service well-registry-service -Out case1\03-resiliency -Config specmatic\well-registry.specmatic.yaml
#>
param(
    [Parameter(Mandatory)] [string]$Service,
    [Parameter(Mandatory)] [string]$Out,     # folder under results\
    [string]$Config,                         # optional specmatic.yaml, relative to the prototype root
    [string]$Token = $null,                  # token for the bearerAuth scheme (default: the test token)
    [hashtable]$Env = @{},                   # extra env vars for Specmatic, e.g. @{ MAX_TEST_REQUEST_COMBINATIONS = '1' }
    [int[]]$PublishPorts = @(),              # host ports of dependency mocks started by the config (same port inside)
    [string]$ContractsDir,                   # alternative contracts checkout (e.g. a branch clone); default: .\contracts
    [string[]]$ExtraArgs = @()
)
. "$PSScriptRoot\common.ps1"
$s = Get-ProtoService $Service
if (-not $PSBoundParameters.ContainsKey('Token')) { $Token = $TestToken }

$outDir = Join-Path $ResultsDir $Out
if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
New-Item -ItemType Directory -Force $outDir | Out-Null
$work = '/work/results/' + ($Out -replace '\\', '/')

$dockerArgs = @('run', '--rm',
    # Resolve host.docker.internal from /etc/hosts instead of Docker Desktop's DNS, which was
    # measured at up to 3.7 s per lookup on this machine (Phase 3 finding).
    '--add-host', 'host.docker.internal:host-gateway',
    '-e', "bearerAuth=$Token")
foreach ($k in $Env.Keys) { $dockerArgs += @('-e', "$k=$($Env[$k])") }
foreach ($p in $PublishPorts) { $dockerArgs += @('-p', "${p}:${p}") }
$dockerArgs += @(
    '-v', "${Root}:/work",
    '-v', "$(if ($ContractsDir) { $ContractsDir } else { Join-Path $Root 'contracts' }):/work/contracts:ro",
    '-w', $work,
    $SpecmaticImage, 'test')
if ($Config) {
    $dockerArgs += @("--config=/work/$($Config -replace '\\', '/')")
} else {
    $dockerArgs += @("/work/contracts/$($s.Spec)", "--testBaseURL=http://host.docker.internal:$($s.Port)/v2")
}
$dockerArgs += @("--junitReportDir=$work/junit") + $ExtraArgs

$console = Join-Path $outDir 'console.txt'
"Command: docker $($dockerArgs -join ' ')" -replace [regex]::Escape($Root), '<prototype-root>' | Set-Content -Encoding utf8 $console
& docker @dockerArgs 2>&1 | ForEach-Object { "$_" } | Add-Content -Encoding utf8 $console
$exit = $LASTEXITCODE

$text = Get-Content $console
$start = ($text | Select-String 'SPECMATIC API COVERAGE SUMMARY' | Select-Object -First 1).LineNumber
if ($start) { $text[($start - 2)..($text.Count - 1)] | Where-Object { $_ -match '^\|' } | Set-Content -Encoding utf8 (Join-Path $outDir 'coverage.txt') }

$totals = ($text | Select-String 'Tests run: (\d+), Successes: (\d+), Failures: (\d+), WIP: (\d+), Errors: (\d+)' | Select-Object -Last 1)
$cov    = ($text | Select-String '(\d+)% API Coverage reported from (\d+) operations' | Select-Object -Last 1)
$summary = [ordered]@{
    service    = $Service
    run        = $Out
    exitCode   = $exit
    testsRun   = if ($totals) { [int]$totals.Matches[0].Groups[1].Value } else { $null }
    successes  = if ($totals) { [int]$totals.Matches[0].Groups[2].Value } else { $null }
    failures   = if ($totals) { [int]$totals.Matches[0].Groups[3].Value } else { $null }
    errors     = if ($totals) { [int]$totals.Matches[0].Groups[5].Value } else { $null }
    apiCoveragePct     = if ($cov) { [int]$cov.Matches[0].Groups[1].Value } else { $null }
    coverageOperations = if ($cov) { [int]$cov.Matches[0].Groups[2].Value } else { $null }
}
$summary | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $outDir 'summary.json')
Write-Host ("  {0}: exit={1} tests={2} pass={3} fail={4} coverage={5}%  -> results\{0}" -f $Out, $exit, $summary.testsRun, $summary.successes, $summary.failures, $summary.apiCoveragePct)
exit $exit
