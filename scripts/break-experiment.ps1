<#
.SYNOPSIS
  Runs ONE break experiment: applies text replacements, rebuilds, runs the xUnit tests and the
  Specmatic provider tests, records whether each caught the break, then restores the original
  files and rebuilds. Results go to results\<Out>\ (summary.json, xunit.txt, Specmatic reports).
.EXAMPLE
  .\scripts\break-experiment.ps1 -Name 'rename field' -Out case1\break\01-rename-field `
     -Changes @(@{ File = 'app-a-production\well-registry-service\Models.cs'; Find = 'double DailyCapacityBbl);'; Replace = 'double DailyCapacity);' })
#>
param(
    [Parameter(Mandatory)] [string]$Name,
    [Parameter(Mandatory)] [string]$Out,
    [Parameter(Mandatory)] [hashtable[]]$Changes,   # each: @{ File; Find; Replace } (literal text, must match exactly once)
    [string]$Service = 'well-registry-service',
    [string]$TestProject = 'app-a-production\well-registry-service.Tests\WellRegistryService.Tests.csproj',
    [string]$Expected = '',
    # Consumer mode: no provider test; the TestProject (consumer stub tests) runs against a STRICT
    # Specmatic stub of StubService started on StubPort with StubConfig.
    [ValidateSet('Provider', 'Consumer')] [string]$Mode = 'Provider',
    [string]$StubService,
    [int]$StubPort,
    [string]$StubConfig,
    # dotnet test --filter for the TestProject. Needed in consumer mode: since Phase 5 the consumer test
    # projects also hold cross-app tests that need OTHER stubs, which would fail for the wrong reason.
    [string]$TestFilter
)
# 'Continue', not 'Stop': in PowerShell 5.1 a failing `dotnet test` writes to stderr, which
# 'Stop' turns into a terminating error and aborts the experiment (seen in Phase 3).
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\common.ps1"
$outDir = Join-Path $ResultsDir $Out
New-Item -ItemType Directory -Force $outDir | Out-Null

# 1. Apply the changes. Originals are kept as raw BYTES so the restore is exact
#    (a text round-trip drops a UTF-8 BOM, seen in Phase 3).
$originals = @{}
foreach ($c in $Changes) {
    $path = Join-Path $Root $c.File
    if (-not $originals.ContainsKey($path)) { $originals[$path] = [IO.File]::ReadAllBytes($path) }
    $text = [IO.File]::ReadAllText($path)
    $count = ([regex]::Matches($text, [regex]::Escape($c.Find))).Count
    if ($count -ne 1) {
        foreach ($p in $originals.Keys) { [IO.File]::WriteAllBytes($p, $originals[$p]) }
        throw "Change for $($c.File): expected exactly 1 match of the Find text, found $count."
    }
    [IO.File]::WriteAllText($path, $text.Replace($c.Find, $c.Replace))
}

$result = [ordered]@{ name = $Name; expected = $Expected; compiled = $false; xunitFailed = $null; specmaticFailures = $null; specmaticExit = $null }
$clock = [Diagnostics.Stopwatch]::StartNew()
# Build only what this experiment runs: the test project (it references the service under test) or the
# service itself. Phase 3 rebuilt the whole solution, about 4-5 minutes per experiment.
$svc = Get-ProtoService $Service
$buildTarget = if ($TestProject) { Join-Path $Root $TestProject } else { Join-Path $Root "$($svc.Dir)\$($svc.Dll).csproj" }
$filterArgs = if ($TestFilter) { @('--filter', $TestFilter) } else { @() }
try {
    & "$PSScriptRoot\stop-services.ps1" -Only $Service | Out-Null

    # 2. Build. A compile error is itself a result (the type system caught it).
    # Logs are committed to a public repo, so the local path is replaced with '.'.
    $build = dotnet build $buildTarget -nologo -v q 2>&1 | ForEach-Object { "$_".Replace($Root, '.') }
    $result.compiled = ($LASTEXITCODE -eq 0)
    $build | Set-Content -Encoding utf8 (Join-Path $outDir 'build.txt')

    if ($result.compiled -and $Mode -eq 'Consumer') {
        # 3c. Consumer side: the (broken) consumer's tests against a strict stub of the provider.
        & "$PSScriptRoot\stub.ps1" start $StubService $StubPort -Strict -Config $StubConfig | Out-Null
        $xunit = dotnet test (Join-Path $Root $TestProject) --no-build -nologo -v q @filterArgs 2>&1 | ForEach-Object { "$_".Replace($Root, '.') }
        $result.xunitFailed = ($LASTEXITCODE -ne 0)
        $xunit | Set-Content -Encoding utf8 (Join-Path $outDir 'consumer-tests.txt')
        & "$PSScriptRoot\stub.ps1" stop $StubService -SaveLogTo $Out | Out-Null
    }
    elseif ($result.compiled) {
        # 3. xUnit (in-process, internal layers), if the service has a unit-test project.
        if ($TestProject) {
            $xunit = dotnet test (Join-Path $Root $TestProject) --no-build -nologo -v q @filterArgs 2>&1 | ForEach-Object { "$_".Replace($Root, '.') }
            $result.xunitFailed = ($LASTEXITCODE -ne 0)
            $xunit | Set-Content -Encoding utf8 (Join-Path $outDir 'xunit.txt')
        }

        # 4. Specmatic against the running (broken) service, examples only (deterministic, fast).
        & "$PSScriptRoot\start-services.ps1" -Only $Service -NoBuild | Out-Null
        & "$PSScriptRoot\run-provider-test.ps1" -Service $Service -Out "$Out\specmatic" | Out-Null
        $sum = Get-Content (Join-Path $outDir 'specmatic\summary.json') -Raw | ConvertFrom-Json
        $result.specmaticExit = $sum.exitCode
        $result.specmaticFailures = $sum.failures
        $result.specmaticTests = $sum.testsRun
    }
}
finally {
    # 5. Always restore the original files and rebuild.
    & "$PSScriptRoot\stop-services.ps1" -Only $Service | Out-Null
    foreach ($p in $originals.Keys) { [IO.File]::WriteAllBytes($p, $originals[$p]) }
    dotnet build $buildTarget -nologo -v q | Out-Null
}

$result.mode = $Mode
$result.seconds = [math]::Round($clock.Elapsed.TotalSeconds)
$result.specmaticCaught = ($result.specmaticExit -ne $null -and $result.specmaticExit -ne 0)
$result.changes = $Changes | ForEach-Object { "$($_.File): '$($_.Find)' -> '$($_.Replace)'" }
$result | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 (Join-Path $outDir 'experiment.json')
Write-Host ("  [{0}] compiled={1} xunitCaught={2} specmaticCaught={3} ({4} of {5} Specmatic tests failed)" -f `
    $Name, $result.compiled, $result.xunitFailed, $result.specmaticCaught, $result.specmaticFailures, $result.specmaticTests)
