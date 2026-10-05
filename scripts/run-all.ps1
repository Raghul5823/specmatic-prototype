<#
.SYNOPSIS
  SERVICE PIPELINE (simulation of pipelines/azure-pipelines.yml).
  Stage "BuildService": ordered gates; the first failure stops the run (exit code 1).
    1. Toolchain pinned            .NET SDK = global.json, Node = mfe/well-mfe/.nvmrc, Specmatic image present
    2. Build (.NET)                dotnet build SpecmaticPrototype.sln
    3. Unit tests                  dotnet test well-registry-service.Tests
    4. Provider contract tests     dotnet test *.ContractTests (each starts its service (+ dependency mocks) and runs Specmatic)
    5. Consumer contract tests     strict Specmatic stubs + dotnet test of the consumer test projects
    6. MFE: client + build         [npm ci] + npm run build (prebuild: bundle spec, generate client from the contract)
    7. MFE: Playwright vs stub     scripts\mfe-e2e.ps1 (strict stub via dev-server proxy)
  Stage "DeployDev": depends on BuildService; runs ONLY if every gate passed (simulated deploy).
  Results -> results\pipeline\<RunName>\ (one log per gate, summary.json).
.PARAMETER NpmCi
  Run `npm ci` for the MFE (clean install, about 3 min, as a CI agent would). Default: reuse node_modules.
.EXAMPLE
  .\scripts\run-all.ps1 -RunName green
#>
param([string]$RunName = 'green', [switch]$NpmCi)
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\common.ps1"
$runDir = Join-Path $ResultsDir "pipeline\$RunName"
if (Test-Path $runDir) { Remove-Item $runDir -Recurse -Force }
New-Item -ItemType Directory -Force $runDir | Out-Null
$testResults = Join-Path $runDir 'test-results'
$mfe = Join-Path $Root 'mfe\well-mfe'
$env:CONTRACT_TEST_RESULTS = "pipeline\$RunName\contract-tests"   # where the ContractTests write Specmatic reports
$env:NG_CLI_ANALYTICS = 'false'

$stubs = @(
    @('well-registry-service', 9101, 'specmatic\well-registry.mock.yaml'),
    @('approval-service', 9202, 'specmatic\approval.mock.yaml'),
    @('change-request-service', 9201, 'specmatic\change-request.mock.yaml'),
    @('production-forecast-service', 9102, 'specmatic\production-forecast.mock.yaml')
)

$gates = @(
    @{ Name = 'Toolchain pinned'; Run = {
        $sdk = (Get-Content (Join-Path $Root 'global.json') -Raw | ConvertFrom-Json).sdk.version
        $nodeWanted = (Get-Content (Join-Path $mfe '.nvmrc') -Raw).Trim()
        $dotnet = (dotnet --version).Trim(); $node = (node --version).Trim().TrimStart('v')
        docker image inspect $SpecmaticImage --format '{{.Id}}' 2>&1 | Out-Null; $img = $LASTEXITCODE
        ".NET SDK: $dotnet (global.json $sdk)   Node: $node (.nvmrc $nodeWanted)   $SpecmaticImage present: $($img -eq 0)"
        [int](-not ($dotnet -eq $sdk -and $node -eq $nodeWanted -and $img -eq 0)) } }
    @{ Name = 'Build (.NET)'; Run = {
        dotnet build (Join-Path $Root 'SpecmaticPrototype.sln') -nologo -v q 2>&1
        $LASTEXITCODE } }
    @{ Name = 'Unit tests'; Run = {
        dotnet test (Join-Path $Root 'app-a-production\well-registry-service.Tests') --no-build -nologo -v q `
            --logger "trx;LogFileName=unit-well-registry.trx" --results-directory $testResults 2>&1
        $LASTEXITCODE } }
    @{ Name = 'Provider contract tests'; Run = {
        & "$PSScriptRoot\stop-services.ps1" | Out-Null   # the ContractTests start the services themselves
        $failed = 0
        foreach ($p in Get-ChildItem $Root -Recurse -Filter '*.ContractTests.csproj' | Where-Object FullName -notmatch '\\(bin|obj|node_modules)\\') {
            "--- $($p.BaseName)"
            dotnet test $p.FullName --no-build -nologo -v q --logger "trx;LogFileName=$($p.BaseName).trx" --results-directory $testResults 2>&1
            if ($LASTEXITCODE -ne 0) { $failed++ }
        }
        $failed } }
    @{ Name = 'Consumer contract tests vs stubs'; Run = {
        foreach ($s in $stubs) { & "$PSScriptRoot\stub.ps1" start $s[0] $s[1] -Strict -Config $s[2] 2>&1 }
        $failed = 0
        try {
            foreach ($p in 'app-a-production\production-forecast-service.Tests', 'app-b-change-mgmt\change-request-service.Tests') {
                "--- $p"
                dotnet test (Join-Path $Root $p) --no-build -nologo -v q --filter 'Category=ConsumerContract' `
                    --logger "trx;LogFileName=$((Split-Path $p -Leaf)).trx" --results-directory $testResults 2>&1
                if ($LASTEXITCODE -ne 0) { $failed++ }
            }
        }
        finally { foreach ($s in $stubs) { & "$PSScriptRoot\stub.ps1" stop $s[0] -SaveLogTo "pipeline\$RunName\stub-logs" 2>&1 } }
        $failed } }
    @{ Name = 'MFE: client + build'; Run = {
        Push-Location $mfe
        try {
            if ($NpmCi) { npm ci --no-audit --no-fund 2>&1; if ($LASTEXITCODE -ne 0) { return 1 } }
            npm run build 2>&1   # prebuild: bundle-spec.mjs + ng-openapi-gen from contracts/
            $LASTEXITCODE
        }
        finally { Pop-Location } } }
    @{ Name = 'MFE: Playwright vs stub'; Run = {
        & "$PSScriptRoot\mfe-e2e.ps1" -Out "pipeline\$RunName\mfe-e2e" 2>&1
        $LASTEXITCODE } }
)

Write-Host "SERVICE PIPELINE  run=$RunName"
Write-Host "Stage BuildService"
$results = @(); $stoppedAt = $null; $i = 0; $total = [Diagnostics.Stopwatch]::StartNew()
foreach ($g in $gates) {
    $i++
    $log = Join-Path $runDir ("{0:00}-{1}.log.txt" -f $i, ($g.Name -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLower())
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = @(& $g.Run)
    $code = [int]($out | Select-Object -Last 1)
    $out | Select-Object -SkipLast 1 | ForEach-Object { "$_".Replace($Root, '.') } | Set-Content -Encoding utf8 $log
    $status = if ($code -eq 0) { 'PASSED' } else { 'FAILED' }
    $results += [ordered]@{ gate = $g.Name; status = $status; seconds = [math]::Round($sw.Elapsed.TotalSeconds) }
    Write-Host ("  [{0}/{1}] {2,-34} {3} ({4}s)" -f $i, $gates.Count, $g.Name, $status, [math]::Round($sw.Elapsed.TotalSeconds))
    if ($code -ne 0) { $stoppedAt = $g.Name; break }
}
foreach ($g in $gates | Select-Object -Skip $results.Count) { $results += [ordered]@{ gate = $g.Name; status = 'SKIPPED'; seconds = 0 } }

if ($stoppedAt) {
    $deploy = "BLOCKED: BuildService failed at gate '$stoppedAt'"
} else {
    $deploy = 'DEPLOYED (simulated): dependsOn BuildService, condition succeeded()'
    "Simulated deployment of this build to DEV at $(Get-Date -Format s)" | Set-Content -Encoding utf8 (Join-Path $runDir 'deploy-dev.txt')
}
Write-Host "Stage DeployDev: $deploy"
Write-Host ("Total {0:n1} min" -f $total.Elapsed.TotalMinutes)
[ordered]@{ pipeline = 'service'; run = $RunName; buildService = $results; stoppedAt = $stoppedAt; deployDev = $deploy
            minutes = [math]::Round($total.Elapsed.TotalMinutes, 1) } | ConvertTo-Json -Depth 4 |
    Set-Content -Encoding utf8 (Join-Path $runDir 'summary.json')
if ($stoppedAt) { exit 1 } else { exit 0 }
