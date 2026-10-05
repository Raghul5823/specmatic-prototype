<#
.SYNOPSIS
  ONE-COMMAND EVIDENCE RUN. Runs every planned case of the prototype (Phases 3-7) from a clean start and
  writes ONE self-contained HTML report:
    evidence\latest\index.html               the newest run (open it by double-clicking; works offline)
    evidence\history\<yyyy-MM-dd_HHmm>\      every run: index.html, evidence.json, raw\ reports (last 10 kept)
  Sections, in order (the run continues after a failure, so the report shows everything):
    env, contracts, case1, case2, case3, mfe, pipeline, [breaks], hygiene
  Output of the reused scripts is redirected (PROTO_RESULTS_DIR), so the committed results\ folder is never touched.
.PARAMETER IncludeBreakDemos
  Also run the 27 break demos of Phases 3-7 LIVE, in a throwaway copy under %TEMP% (never in the working tree
  or the contracts repo). Adds about 15-30 minutes (measured: 14 and 28 min).
.PARAMETER Open
  Open the report in the default browser at the end.
.PARAMETER Only
  Debugging aid: run only these sections (env and hygiene always run). The report is marked PARTIAL and the
  exit code is never 0.
.EXAMPLE
  .\scripts\run-evidence.ps1 -Open
  .\scripts\run-evidence.ps1 -IncludeBreakDemos -Open
  .\scripts\run-evidence.ps1 -Only case3,mfe
#>
param(
    [switch]$IncludeBreakDemos,
    [switch]$Open,
    [ValidateSet('contracts', 'case1', 'case2', 'case3', 'mfe', 'pipeline', 'breaks')] [string[]]$Only
)
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$scripts = $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'evidence\Evidence.psm1') -Force -DisableNameChecking
$plan = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'evidence\plan.psd1')

# ------------------------------------------------------------------ run folder and output redirection
$started = Get-Date
$historyRoot = Join-Path $Root 'evidence\history'
$runId = $started.ToString('yyyy-MM-dd_HHmm'); $n = 2
while (Test-Path (Join-Path $historyRoot $runId)) { $runId = $started.ToString('yyyy-MM-dd_HHmm') + "_$n"; $n++ }
$runDir = Join-Path $historyRoot $runId
$raw = Join-Path $runDir 'raw'
New-Item -ItemType Directory -Force $raw | Out-Null
$env:PROTO_RESULTS_DIR = $raw          # every reused script writes here instead of results\
$env:NG_CLI_ANALYTICS = 'false'
Remove-Item Env:\CONTRACT_TEST_RESULTS -ErrorAction SilentlyContinue
. (Join-Path $PSScriptRoot 'common.ps1')   # $SpecmaticImage, $Services (after PROTO_RESULTS_DIR is set)
$tempBase = Join-Path (Get-Item $env:TEMP).FullName ('sp-ev\' + $started.ToString('HHmmss'))   # short: 260-char limit
Set-EvidenceSanitizer @{ $Root = '.'; $tempBase = '<temp-copy>' }
$mfe = Join-Path $Root 'mfe\well-mfe'

$all = @('contracts', 'case1', 'case2', 'case3', 'mfe', 'pipeline')
$selected = if ($Only) { @($Only) } else { $all }
if ($IncludeBreakDemos -and $selected -notcontains 'breaks') { $selected += 'breaks' }
$partial = [bool]$Only
$flags = @(); if ($IncludeBreakDemos) { $flags += '-IncludeBreakDemos' }; if ($Only) { $flags += "-Only $($Only -join ',')" }

$script:Checks = @()
$script:Demos = @()
$script:Blocked = $null       # set when a prerequisite fails: later checks are SKIPPED with this reason
$script:MfeBlocked = $null
$E = [ordered]@{
    schema = 1
    run    = [ordered]@{ id = $runId; started = $started.ToString('yyyy-MM-dd HH:mm'); durationSec = $null; verdict = $null
                         flags = $flags; partial = $partial; sections = @(@('env') + $selected + @('hygiene')) }
    versions = [ordered]@{}
    repos    = [ordered]@{}
    pairs    = [ordered]@{}
}

# ------------------------------------------------------------------ helpers
function Write-Status([string]$Status, [string]$Text) {
    $color = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'DarkYellow' } }
    Write-Host ("  {0,-7} {1}" -f $Status, $Text) -ForegroundColor $color
}

function Invoke-Check {
    param([string]$Section, [string]$Name, [string]$Kind, [scriptblock]$Body, [string[]]$Pairs = @(), [string]$Skip)
    $check = [ordered]@{ section = $Section; name = $Name; kind = $Kind; pairs = $Pairs; status = 'SKIPPED'; seconds = 0
                         tests = $null; coverage = $null; owners = $null; raw = @(); notes = @(); error = $null }
    if (-not $Skip -and $script:Blocked) { $Skip = $script:Blocked }
    if ($Skip) {
        $check.notes = @("Skipped: $Skip")
        Write-Status 'SKIPPED' "[$Section] $Name ($Skip)"
        $script:Checks += , $check
        return
    }
    Write-Host ("          [{0}] {1} ..." -f $Section, $Name) -ForegroundColor DarkGray
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $out = @(& $Body)
        $res = $out | Where-Object { $_ -is [Collections.IDictionary] -and $_.Contains('status') } | Select-Object -Last 1
        $check.seconds = [math]::Round($sw.Elapsed.TotalSeconds)
        if ($res) { foreach ($k in @($res.Keys)) { $check[$k] = $res[$k] } }
        else { $check.status = 'FAIL'; $check.error = 'The check produced no result.' }
    }
    catch {
        $check.seconds = [math]::Round($sw.Elapsed.TotalSeconds)
        $check.status = 'FAIL'; $check.error = Protect-Text "$($_.Exception.Message)" 2000
    }
    $t = if ($check.tests) { " - $($check.tests.passed)/$($check.tests.total) tests" } else { '' }
    Write-Status $check.status ("[{0}] {1}{2} ({3}s)" -f $Section, $Name, $t, $check.seconds)
    $script:Checks += , $check
}

function New-Result([string]$Status, $Tests = $null, [string[]]$Notes = @(), $Raw = @(), [string]$ErrorText = $null) {
    return [ordered]@{ status = $Status; tests = $Tests; notes = @($Notes); raw = @($Raw); error = $ErrorText }
}

function RawLink([string]$Label, [string]$RelPath) {
    # Only link files that exist; paths are relative to raw\ (forward slashes for the browser).
    $p = $RelPath -replace '\\', '/'
    if (Test-Path (Join-Path $raw ($p -replace '/', '\'))) { return , ([ordered]@{ label = $Label; path = $p }) }
    return $null
}
function Links { param([object[]]$Items) return , @($Items | Where-Object { $_ }) }

function Invoke-Logged([string]$LogRel, [scriptblock]$Command) {
    # Runs a command, saves its sanitised output under raw\, returns the exit code.
    $o = @(& $Command 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    Save-ProtectedLog $o (Join-Path $raw $LogRel)
    return $code
}

function Start-Svc([string]$Name, [hashtable]$Env = @{}) {
    & (Join-Path $scripts 'start-services.ps1') -Only $Name -NoBuild -Env $Env *> $null
}
function Stop-Svc { & (Join-Path $scripts 'stop-services.ps1') *> $null }

function Wait-MockHealthy([int]$Port) {
    # First request to a fresh Specmatic mock can be slow (Phase 7); wait for its health endpoint.
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        try { if ((Invoke-WebRequest "http://localhost:$Port/actuator/health" -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200) { return } } catch { }
        Start-Sleep -Milliseconds 500
    }
}
function Start-Stub([string]$Service, [int]$Port, [string]$Config) {
    & (Join-Path $scripts 'stub.ps1') start $Service $Port -Strict -Config $Config *> $null
    Wait-MockHealthy $Port
}
function Stop-Stub([string]$Service, [string]$SaveTo) { & (Join-Path $scripts 'stub.ps1') stop $Service -SaveLogTo $SaveTo *> $null }

function Invoke-ProviderRun {
    param([string]$Service, [string]$Out, [string]$Config, [hashtable]$Env = @{}, [string[]]$ExtraArgs = @())
    $p = @{ Service = $Service; Out = $Out }
    if ($Config) { $p.Config = $Config }
    if ($Env.Count) { $p.Env = $Env }
    if ($ExtraArgs.Count) { $p.ExtraArgs = $ExtraArgs }
    & (Join-Path $scripts 'run-provider-test.ps1') @p *> $null
    $exit = $LASTEXITCODE
    $dir = Join-Path $raw $Out
    $tests = Read-JUnit @(Get-ChildItem (Join-Path $dir 'junit') -Filter *.xml -ErrorAction SilentlyContinue | ForEach-Object FullName) -Owners
    $r = New-Result $(if ($exit -eq 0 -and $tests.total -gt 0 -and $tests.failed -eq 0) { 'PASS' } else { 'FAIL' }) $tests @("Specmatic exit code $exit") (Links @(
        (RawLink 'Specmatic HTML report' "$Out/build/reports/specmatic/test/html/index.html"),
        (RawLink 'JUnit XML' "$Out/junit/TEST-junit-jupiter.xml"),
        (RawLink 'Specmatic console output' "$Out/console.txt")))
    $r.coverage = Read-SpecmaticCoverage (Join-Path $dir 'console.txt') $Service
    $r.owners = Get-OwnerBreakdown $tests
    return $r
}

function Invoke-DotnetTest {
    param([string]$Project, [string]$Out, [string]$TrxName, [string]$Filter)
    $dir = Join-Path $raw $Out
    New-Item -ItemType Directory -Force $dir | Out-Null
    $a = @('test', (Join-Path $Root $Project), '--no-build', '-nologo', '-v', 'q', '--logger', "trx;LogFileName=$TrxName.trx", '--results-directory', $dir)
    if ($Filter) { $a += @('--filter', $Filter) }
    $exit = Invoke-Logged "$Out\$TrxName.console.txt" { dotnet @a }
    $tests = Read-Trx (Join-Path $dir "$TrxName.trx")
    $notes = @("dotnet test exit code $exit")
    if ($Filter) { $notes += "filter: $Filter" }
    $err = ($tests.testcases | Where-Object { $_.status -eq 'FAIL' } | Select-Object -First 1).message
    return (New-Result $(if ($exit -eq 0 -and $tests.total -gt 0 -and $tests.failed -eq 0) { 'PASS' } else { 'FAIL' }) $tests $notes (Links @(
        (RawLink 'dotnet test output' "$Out/$TrxName.console.txt"))) $err)
}

function Invoke-ContractTests([string]$Project, [string]$Service, [string]$Out) {
    # xUnit ContractTests project: starts the service and its dependency mocks, runs Specmatic (Phase 7).
    $env:CONTRACT_TEST_RESULTS = $Out
    try { $r = Invoke-DotnetTest -Project $Project -Out $Out -TrxName "$Service.ContractTests" }
    finally { Remove-Item Env:\CONTRACT_TEST_RESULTS -ErrorAction SilentlyContinue }
    $spec = Join-Path $raw "$Out\$Service"
    $specTests = Read-JUnit @(Get-ChildItem (Join-Path $spec 'junit') -Filter *.xml -ErrorAction SilentlyContinue | ForEach-Object FullName) -Owners
    $wrapper = $r.tests
    $r.notes += "xUnit wrapper test: $($wrapper.passed)/$($wrapper.total) passed; the Specmatic tests it ran are listed below"
    $r.tests = $specTests
    if ($specTests.total -eq 0 -or $specTests.failed -gt 0) { $r.status = 'FAIL' }
    $r.coverage = Read-SpecmaticCoverage (Join-Path $spec 'console.txt') $Service
    $r.owners = Get-OwnerBreakdown $specTests
    $mockLog = Get-ChildItem (Join-Path $raw $Out) -Filter 'ct-deps-*.log.txt' -ErrorAction SilentlyContinue | Select-Object -First 1
    $r.raw = Links @(
        (RawLink 'Specmatic HTML report' "$Out/$Service/build/reports/specmatic/test/html/index.html"),
        (RawLink 'JUnit XML' "$Out/$Service/junit/TEST-junit-jupiter.xml"),
        (RawLink 'Specmatic console output' "$Out/$Service/console.txt"),
        $(if ($mockLog) { RawLink 'Dependency mock log' "$Out/$($mockLog.Name)" }),
        (RawLink 'dotnet test output' "$Out/$Service.ContractTests.console.txt"))
    return $r
}

function Select-OwnerTests($ProviderResult, [string]$Owner) {
    $cases = @($ProviderResult.tests.testcases | Where-Object { $_.owner -eq $Owner })
    $sum = New-TestSummary $cases
    $status = if ($sum.total -gt 0 -and $sum.failed -eq 0) { 'PASS' } else { 'FAIL' }
    return (New-Result $status $sum @("The $Owner examples inside the Case 1 provider run (not run twice)") $ProviderResult.raw)
}

function Edit-Once([string]$Path, [string]$Find, [string]$Replace) {
    $t = [IO.File]::ReadAllText($Path)
    if (([regex]::Matches($t, [regex]::Escape($Find))).Count -ne 1) { throw "Find text not exactly once in $(Protect-Text $Path)" }
    [IO.File]::WriteAllText($Path, $t.Replace($Find, $Replace))
}

function Read-ConsumerMap([string]$Path) {
    $map = [ordered]@{}; $cur = $null
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*-\s*id:\s*(\S+)') { $cur = [ordered]@{ id = $Matches[1] }; $map[$Matches[1]] = $cur; continue }
        if ($cur -and $line -match '^\s+(consumer|provider|scope|operation):\s*(.+?)\s*(#.*)?$') { $cur[$Matches[1]] = $Matches[2] }
    }
    return $map
}

# ------------------------------------------------------------------ start
$eta = if ($selected -contains 'breaks') { 'about 25-45 min' } else { 'about 15 min' }
Write-Host "EVIDENCE RUN  $runId  sections: env, $($selected -join ', '), hygiene  (estimated $eta)" -ForegroundColor Cyan
$gitStart = [ordered]@{ prototype = Get-GitState $Root; contracts = Get-GitState (Join-Path $Root 'contracts') }
$E.pairs = Read-ConsumerMap (Join-Path $Root 'contracts\consumers.yaml')
$nmMarker = Join-Path $mfe 'node_modules\@angular\core\package.json'
$nmCount = @(Get-ChildItem (Join-Path $mfe 'node_modules') -ErrorAction SilentlyContinue).Count

try {
# ================================================================== 1. environment
Write-Host "Section env" -ForegroundColor Cyan
Invoke-Check 'env' 'Tool versions' 'info' {
    $v = [ordered]@{}
    $v.dotnetSdk  = "$(dotnet --version 2>$null)".Trim()
    $v.node       = "$(node --version 2>$null)".Trim().TrimStart('v')
    $v.npm        = "$(cmd /c npm --version 2>$null)".Trim()
    $v.docker     = "$(docker version --format '{{.Server.Version}}' 2>$null)".Trim()
    $v.specmaticImage = $SpecmaticImage
    $v.specmaticImageId = "$(docker image inspect $SpecmaticImage --format '{{.Id}}' 2>$null)".Trim() -replace '^sha256:(.{12}).*', '$1'
    $v.specmatic  = "$(docker run --rm $SpecmaticImage --version 2>$null | Select-Object -Last 1)".Trim() -replace '^Specmatic Version:\s*', ''
    foreach ($pkg in @(@('angular', '@angular\core'), @('playwright', '@playwright\test'), @('ngOpenapiGen', 'ng-openapi-gen'))) {
        $pj = Join-Path $mfe "node_modules\$($pkg[1])\package.json"
        $v[$pkg[0]] = if (Test-Path $pj) { (Get-Content $pj -Raw | ConvertFrom-Json).version } else { $null }
    }
    $v.powershell = "$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    $v.os = [Environment]::OSVersion.VersionString
    $script:E.versions = $v
    $missing = @('dotnetSdk', 'node', 'docker') | Where-Object { -not $v[$_] }
    if (-not $v.docker) { $script:Blocked = 'Docker engine is not running' }
    elseif (-not $v.specmaticImageId) { $script:Blocked = "Specmatic image missing: docker pull $SpecmaticImage (not done automatically)" }
    $notes = @($v.Keys | ForEach-Object { "${_}: $($v[$_])" })
    New-Result $(if ($missing.Count -eq 0 -and -not $script:Blocked) { 'PASS' } else { 'FAIL' }) $null $notes @() $(if ($script:Blocked) { $script:Blocked } elseif ($missing) { "Missing: $($missing -join ', ')" })
}
Invoke-Check 'env' 'Version pins match (global.json, .nvmrc)' 'check' {
    $sdk = (Get-Content (Join-Path $Root 'global.json') -Raw | ConvertFrom-Json).sdk.version
    $nodeWanted = (Get-Content (Join-Path $mfe '.nvmrc') -Raw).Trim()
    $ok = ($script:E.versions.dotnetSdk -eq $sdk) -and ($script:E.versions.node -eq $nodeWanted)
    New-Result $(if ($ok) { 'PASS' } else { 'FAIL' }) $null @(".NET SDK $($script:E.versions.dotnetSdk) (global.json $sdk)", "Node $($script:E.versions.node) (.nvmrc $nodeWanted)", "Specmatic image tag $SpecmaticImage (pinned in scripts and YAML)")
}
Invoke-Check 'env' 'Contract and code revisions' 'info' {
    $p = $gitStart.prototype; $c = $gitStart.contracts
    $script:E.repos = [ordered]@{
        prototype = [ordered]@{ commit = $p.commit; branch = $p.branch; dirty = $p.dirty; changes = $p.changes.Count }
        contracts = [ordered]@{ commit = $c.commit; branch = $c.branch; tag = $c.exactTag; lastTag = $c.lastTag; aheadOfTag = $c.aheadOfTag; dirty = $c.dirty; changes = $c.changes.Count }
    }
    $tagText = if ($c.exactTag) { "tag $($c.exactTag)" } else { "$($c.aheadOfTag) commit(s) after $($c.lastTag)" }
    New-Result 'PASS' $null @(
        "contracts: $($c.commit) on $($c.branch), $tagText$(if ($c.dirty) { ", $($c.changes.Count) uncommitted change(s)" })",
        "prototype: $($p.commit) on $($p.branch)$(if ($p.dirty) { ", $($p.changes.Count) uncommitted change(s) (the run uses the working tree as it is)" })")
}
Invoke-Check 'env' 'Clean start: services, containers and ports' 'check' {
    $stopped = Stop-EvidenceProcesses $Root
    Start-Sleep -Seconds 1
    $busy = Get-BusyPorts
    $notes = @("Ports checked: 5101-5202 (services), 9101-9202 (stubs/mocks), 4200 (MFE dev server)")
    if ($stopped.Count) { $notes += "Removed leftover containers: $($stopped -join ', ')" }
    if ($busy.Count) { $script:Blocked = "ports in use by other programs: $(($busy | ForEach-Object { "$($_.port) ($($_.process))" }) -join ', ')" }
    New-Result $(if ($busy.Count -eq 0) { 'PASS' } else { 'FAIL' }) $null $notes @() $script:Blocked
}
Invoke-Check 'env' 'Build the solution' 'build' {
    $code = Invoke-Logged 'env\build.txt' { dotnet build (Join-Path $Root 'SpecmaticPrototype.sln') -nologo -v q }
    if ($code -ne 0) { $script:Blocked = 'the solution did not build' }
    New-Result $(if ($code -eq 0) { 'PASS' } else { 'FAIL' }) $null @("dotnet build exit code $code") (Links @((RawLink 'Build output' 'env/build.txt')))
}
Invoke-Check 'env' 'MFE dependencies present (node_modules)' 'check' {
    if (-not (Test-Path $nmMarker)) { $script:MfeBlocked = 'mfe\well-mfe\node_modules is missing: run npm ci there (not done automatically)' }
    New-Result $(if ($script:MfeBlocked) { 'FAIL' } else { 'PASS' }) $null @("node_modules entries: $nmCount") @() $script:MfeBlocked
}

# ================================================================== 2. contracts
if ($selected -contains 'contracts') {
    Write-Host "Section contracts" -ForegroundColor Cyan
    $script:PrSummary = $null
    Invoke-Check 'contracts' 'Validate specs + examples (--examples-to-validate BOTH)' 'specmatic' {
        # A fresh clone, not the real repo: the compatibility check mounts the repo writable and uses git.
        $clone = Join-Path $tempBase 'c'
        git -c core.autocrlf=false clone -q (Join-Path $Root 'contracts') $clone 2>&1 | Out-Null
        git -C $clone config core.autocrlf false
        & (Join-Path $scripts 'contracts-pr-check.ps1') -RepoDir $clone -BaseBranch main -RunName evidence -ContinueOnFailure *> $null
        $null = Remove-TempCopy $clone
        $sumFile = Join-Path $raw 'pipeline\contracts-pr\evidence\summary.json'
        if (-not (Test-Path $sumFile)) { return (New-Result 'FAIL' $null @() @() 'contracts-pr-check.ps1 wrote no summary') }
        $script:PrSummary = Get-Content $sumFile -Raw | ConvertFrom-Json
        $g = $script:PrSummary.gates[0]
        # One test case per spec, from the gate log ("--- specs/... (exit N)" + indented details).
        $log = Get-ChildItem (Join-Path $raw 'pipeline\contracts-pr\evidence') -Filter '01-*.log.txt' | Select-Object -First 1
        $cases = @(); $cur = $null
        foreach ($l in (Get-Content $log.FullName)) {
            if ($l -match '^--- (\S+)\s+\(exit (-?\d+)\)') {
                $cur = [ordered]@{ name = $Matches[1]; status = $(if ($Matches[2] -eq '0') { 'PASS' } else { 'FAIL' }); seconds = $null; message = '' }
                $cases += , $cur
            }
            elseif ($cur -and $cur.status -eq 'FAIL') { $cur.message += "$($l.Trim())`n" }
        }
        $r = New-Result $(if ($g.status -eq 'PASSED') { 'PASS' } else { 'FAIL' }) (New-TestSummary $cases) @("Contracts at $($gitStart.contracts.commit), checked in a fresh clone") (Links @((RawLink 'Gate log' "pipeline/contracts-pr/evidence/$($log.Name)")))
        $r.seconds = $g.seconds
        $r
    }
    foreach ($i in 1, 2) {
        $gateName = @('Bundle check (every spec bundles for code generators)', 'Backward compatibility vs main')[$i - 1]
        Invoke-Check 'contracts' $gateName 'specmatic' {
            if (-not $script:PrSummary) { return (New-Result 'FAIL' $null @() @() 'No contracts PR summary (see the first check)') }
            $g = $script:PrSummary.gates[$i]
            $log = Get-ChildItem (Join-Path $raw 'pipeline\contracts-pr\evidence') -Filter ('{0:00}-*.log.txt' -f ($i + 1)) | Select-Object -First 1
            $notes = @()
            if ($i -eq 2 -and $gitStart.contracts.branch -eq 'main') { $notes += 'HEAD is main, so there is nothing to compare: this proves the gate runs. Break demos A3-A5 show it catching real changes.' }
            if ($log) { $notes += @(Get-Content $log.FullName | Where-Object { $_.Trim() } | Select-Object -First 8 | ForEach-Object { Protect-Text $_.Trim() 300 }) }
            $r = New-Result $(if ($g.status -eq 'PASSED') { 'PASS' } else { 'FAIL' }) $null $notes $(if ($log) { Links @((RawLink 'Gate log' "pipeline/contracts-pr/evidence/$($log.Name)")) } else { @() })
            $r.seconds = $g.seconds
            $r
        }
    }
}

# ================================================================== 3. case 1
$script:Case1Examples = $null
if ($selected -contains 'case1') {
    Write-Host "Section case1" -ForegroundColor Cyan
    Invoke-Check 'case1' 'Provider contract test: all examples (inline, provider and consumer)' 'specmatic' -Pairs @('C1', 'C5') {
        Start-Svc 'well-registry-service'
        $r = Invoke-ProviderRun -Service 'well-registry-service' -Out 'case1\examples'
        $script:Case1Examples = $r
        $r
    }
    Invoke-Check 'case1' 'Provider contract test: examples + generated negative (resiliency) tests, capped' 'specmatic' {
        try {
            Invoke-ProviderRun -Service 'well-registry-service' -Out 'case1\resiliency' -Config 'specmatic\well-registry.specmatic.yaml' `
                -Env @{ MAX_TEST_REQUEST_COMBINATIONS = '1' } -ExtraArgs @('--timeout-in-ms=30000')
        }
        finally { Stop-Svc }
    }
    Invoke-Check 'case1' 'Internal layers: xUnit unit tests' 'xunit' {
        Invoke-DotnetTest -Project 'app-a-production\well-registry-service.Tests' -Out 'case1\unit' -TrxName 'well-registry-unit'
    }
}

# ================================================================== 4. case 2
if ($selected -contains 'case2') {
    Write-Host "Section case2" -ForegroundColor Cyan
    Invoke-Check 'case2' 'C1 provider side: well-registry satisfies production-forecast''s examples' 'derived' -Pairs @('C1') {
        if (-not $script:Case1Examples) {
            Start-Svc 'well-registry-service'
            try { $script:Case1Examples = Invoke-ProviderRun -Service 'well-registry-service' -Out 'case2\c1-provider' } finally { Stop-Svc }
        }
        Select-OwnerTests $script:Case1Examples 'production-forecast'
    }
    Invoke-Check 'case2' 'C2 provider side: approval-service contract test' 'specmatic' -Pairs @('C2') {
        Start-Svc 'approval-service'
        try { Invoke-ProviderRun -Service 'approval-service' -Out 'case2\c2-provider' } finally { Stop-Svc }
    }
    Invoke-Check 'case2' 'C1 consumer side: production-forecast vs strict well-registry stub' 'xunit' -Pairs @('C1') {
        Start-Stub 'well-registry-service' 9101 'specmatic\well-registry.mock.yaml'
        try { Invoke-DotnetTest -Project 'app-a-production\production-forecast-service.Tests' -Out 'case2\c1-consumer' -TrxName 'c1-consumer' -Filter 'FullyQualifiedName~WellRegistryClientStubTests' }
        finally { Stop-Stub 'well-registry-service' 'case2\c1-consumer' }
    }
    Invoke-Check 'case2' 'C2 consumer side: change-request vs strict approval stub' 'xunit' -Pairs @('C2') {
        Start-Stub 'approval-service' 9202 'specmatic\approval.mock.yaml'
        try { Invoke-DotnetTest -Project 'app-b-change-mgmt\change-request-service.Tests' -Out 'case2\c2-consumer' -TrxName 'c2-consumer' -Filter 'FullyQualifiedName~ApprovalClientStubTests' }
        finally { Stop-Stub 'approval-service' 'case2\c2-consumer' }
    }
}

# ================================================================== 5. case 3
if ($selected -contains 'case3') {
    Write-Host "Section case3" -ForegroundColor Cyan
    Stop-Svc   # the ContractTests start their own services
    Invoke-Check 'case3' 'C3 provider side: production-forecast ContractTests (well-registry and change-request mocked)' 'specmatic' -Pairs @('C3') {
        Invoke-ContractTests 'app-a-production\production-forecast-service.ContractTests' 'production-forecast-service' 'case3\contract-tests'
    }
    Invoke-Check 'case3' 'C4 provider side: change-request ContractTests (approval and production-forecast mocked)' 'specmatic' -Pairs @('C4') {
        Invoke-ContractTests 'app-b-change-mgmt\change-request-service.ContractTests' 'change-request-service' 'case3\contract-tests'
    }
    Invoke-Check 'case3' 'C3 consumer side: change-request vs strict production-forecast stub' 'xunit' -Pairs @('C3') {
        Start-Stub 'production-forecast-service' 9102 'specmatic\production-forecast.mock.yaml'
        try { Invoke-DotnetTest -Project 'app-b-change-mgmt\change-request-service.Tests' -Out 'case3\c3-consumer' -TrxName 'c3-consumer' -Filter 'FullyQualifiedName~ProductionForecastClientStubTests' }
        finally { Stop-Stub 'production-forecast-service' 'case3\c3-consumer' }
    }
    Invoke-Check 'case3' 'C4 consumer side: production-forecast vs strict change-request stub' 'xunit' -Pairs @('C4') {
        Start-Stub 'change-request-service' 9201 'specmatic\change-request.mock.yaml'
        try { Invoke-DotnetTest -Project 'app-a-production\production-forecast-service.Tests' -Out 'case3\c4-consumer' -TrxName 'c4-consumer' -Filter 'FullyQualifiedName~ChangeRequestClientStubTests' }
        finally { Stop-Stub 'change-request-service' 'case3\c4-consumer' }
    }
}

# ================================================================== 6. case 4: MFE
if ($selected -contains 'mfe') {
    Write-Host "Section mfe" -ForegroundColor Cyan
    Invoke-Check 'mfe' 'C5 provider side: well-registry satisfies well-mfe''s examples' 'derived' -Pairs @('C5') {
        if (-not $script:Case1Examples) {
            Start-Svc 'well-registry-service'
            try { $script:Case1Examples = Invoke-ProviderRun -Service 'well-registry-service' -Out 'mfe\c5-provider' } finally { Stop-Svc }
        }
        Select-OwnerTests $script:Case1Examples 'well-mfe'
    }
    Invoke-Check 'mfe' 'Bundle the spec and generate the TypeScript client' 'build' -Skip $script:MfeBlocked {
        Push-Location $mfe
        try { $code = Invoke-Logged 'mfe\generate.txt' { cmd /c npm run generate:api } } finally { Pop-Location }
        New-Result $(if ($code -eq 0) { 'PASS' } else { 'FAIL' }) $null @('npm run generate:api (scripts/bundle-spec.mjs + ng-openapi-gen)', "exit code $code") (Links @((RawLink 'Generator output' 'mfe/generate.txt')))
    }
    Invoke-Check 'mfe' 'Compile check: ng build against the generated client' 'build' -Skip $script:MfeBlocked {
        Push-Location $mfe
        try { $code = Invoke-Logged 'mfe\build.txt' { cmd /c npx ng build } } finally { Pop-Location }
        New-Result $(if ($code -eq 0) { 'PASS' } else { 'FAIL' }) $null @("ng build exit code $code") (Links @((RawLink 'Build output' 'mfe/build.txt')))
    }
    Invoke-Check 'mfe' 'Playwright end-to-end tests vs strict well-registry stub' 'playwright' -Pairs @('C5') -Skip $script:MfeBlocked {
        & (Join-Path $scripts 'mfe-e2e.ps1') -Out 'mfe\e2e' *> $null
        $code = $LASTEXITCODE
        $tests = Read-JUnit @(Join-Path $raw 'mfe\e2e\junit.xml')
        New-Result $(if ($code -eq 0 -and $tests.total -gt 0 -and $tests.failed -eq 0) { 'PASS' } else { 'FAIL' }) $tests @("Playwright exit code $code") (Links @(
            (RawLink 'JUnit XML (Playwright)' 'mfe/e2e/junit.xml'), (RawLink 'Playwright console output' 'mfe/e2e/console.txt'),
            (RawLink 'Stub request log' 'mfe/e2e/stub-well-registry-service.log.txt')))
    }
}

# ================================================================== 7. pipeline
if ($selected -contains 'pipeline') {
    Write-Host "Section pipeline (run-all.ps1, about 4-5 min)" -ForegroundColor Cyan
    $script:Pipe = $null
    $pipeClock = [Diagnostics.Stopwatch]::StartNew()
    if (-not $script:Blocked) {
        & (Join-Path $scripts 'run-all.ps1') -RunName 'evidence' *> $null
        Remove-Item Env:\CONTRACT_TEST_RESULTS -ErrorAction SilentlyContinue   # run-all sets it for its ContractTests
        $f = Join-Path $raw 'pipeline\evidence\summary.json'
        if (Test-Path $f) { $script:Pipe = Get-Content $f -Raw | ConvertFrom-Json }
    }
    $gateNames = @('Toolchain pinned', 'Build (.NET)', 'Unit tests', 'Provider contract tests', 'Consumer contract tests vs stubs', 'MFE: client + build', 'MFE: Playwright vs stub')
    for ($gi = 0; $gi -lt $gateNames.Count; $gi++) {
        $gname = $gateNames[$gi]
        Invoke-Check 'pipeline' ("Gate {0}: {1}" -f ($gi + 1), $gname) 'gate' {
            if (-not $script:Pipe) { return (New-Result 'FAIL' $null @() @() 'run-all.ps1 wrote no summary') }
            $g = @($script:Pipe.buildService | Where-Object { $_.gate -eq $gname })[0]
            $st = switch ($g.status) { 'PASSED' { 'PASS' } 'FAILED' { 'FAIL' } default { 'SKIPPED' } }
            $log = Get-ChildItem (Join-Path $raw 'pipeline\evidence') -Filter ('{0:00}-*.log.txt' -f ($gi + 1)) -ErrorAction SilentlyContinue | Select-Object -First 1
            $r = New-Result $st $null @() $(if ($log) { Links @((RawLink 'Gate log' "pipeline/evidence/$($log.Name)")) } else { @() })
            $r.seconds = $g.seconds
            if ($st -eq 'SKIPPED') { $r.notes = @('Not reached: an earlier gate failed (the pipeline stops at the first failure)') }
            $r
        }
    }
    Invoke-Check 'pipeline' 'Stage DeployDev (dependsOn: BuildService)' 'gate' {
        if (-not $script:Pipe) { return (New-Result 'FAIL' $null @() @() 'run-all.ps1 wrote no summary') }
        $ok = "$($script:Pipe.deployDev)".StartsWith('DEPLOYED')
        $r = New-Result $(if ($ok) { 'PASS' } else { 'FAIL' }) $null @("$($script:Pipe.deployDev)", "Whole pipeline: $($script:Pipe.minutes) min")
        $r.seconds = 0
        $r
    }
}

# ================================================================== 8. break demos (throwaway copy)
if ($selected -contains 'breaks') {
    Write-Host "Section breaks (throwaway copy under %TEMP%, about 15-30 min)" -ForegroundColor Cyan
    $copy = Join-Path $tempBase 'p'
    $junction = Join-Path $copy 'mfe\well-mfe\node_modules'
    $script:BreaksBlocked = $null
    $savedResults = $env:PROTO_RESULTS_DIR
    try {
        Invoke-Check 'breaks' 'Create the throwaway copy (working tree + contracts clone) and build it' 'setup' {
            New-Item -ItemType Directory -Force $copy | Out-Null
            # Working tree as it is (incl. uncommitted work), without build output, dependencies or results.
            # /XJ: never follow junctions in the working tree.
            robocopy $Root $copy /E /XJ /XD bin obj node_modules .vs .git .specmatic .angular .generated dist test-results playwright-report results evidence contracts /XF *.log *.trx /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
            if ($LASTEXITCODE -ge 8) { $script:BreaksBlocked = "robocopy failed ($LASTEXITCODE)"; return (New-Result 'FAIL' $null @() @() $script:BreaksBlocked) }
            git -c core.autocrlf=false clone -q (Join-Path $Root 'contracts') (Join-Path $copy 'contracts') 2>&1 | Out-Null
            git -C (Join-Path $copy 'contracts') config core.autocrlf false
            # node_modules: a junction to the real folder (read-only use; removed with rmdir at the end).
            cmd /c mklink /J "$junction" "$(Join-Path $mfe 'node_modules')" | Out-Null
            Remove-Item Env:\PROTO_RESULTS_DIR -ErrorAction SilentlyContinue   # the copy's scripts write to the copy's results\
            $code = Invoke-Logged 'breaks\setup-build.txt' { dotnet build (Join-Path $copy 'SpecmaticPrototype.sln') -nologo -v q }
            $env:PROTO_RESULTS_DIR = $savedResults
            if ($code -ne 0) { $script:BreaksBlocked = 'the copy did not build' }
            New-Result $(if ($code -eq 0 -and (Test-Path $junction)) { 'PASS' } else { 'FAIL' }) $null @('Copy at <temp-copy>\p (deleted at the end)', "dotnet build exit code $code", 'node_modules: junction to the real folder') (Links @((RawLink 'Build output' 'breaks/setup-build.txt'))) $script:BreaksBlocked
        }
        Remove-Item Env:\PROTO_RESULTS_DIR -ErrorAction SilentlyContinue
        $copyResults = Join-Path $copy 'results'

        $batches = @(
            @{ Name = 'Phase 3: Case 1 provider breaks (9 demos)'; Script = 'case1-break-experiments.ps1'; Args = @{} }
            @{ Name = 'Phase 4: Case 2 consumer and provider breaks (6 demos)'; Script = 'case2-break-experiments.ps1'; Args = @{} }
            @{ Name = 'Phase 5: Case 3 drift in both directions (D1, D2)'; Script = 'case3-drift.ps1'; Args = @{ ContractClone = (Join-Path $tempBase 'd2') } }
            @{ Name = 'Phase 6: contract change becomes an MFE compile error'; Script = 'mfe-compile-break.ps1'; Args = @{} }
            @{ Name = 'Phase 7: contracts PR demos A1-A5'; Script = 'pipeline-failure-demos.ps1'; Args = @{ Only = @('A') } }
        )
        foreach ($b in $batches) {
            Invoke-Check 'breaks' $b.Name 'demo-batch' -Skip $script:BreaksBlocked {
                if ($b.Script -eq 'case3-drift.ps1') {
                    # D2 needs a contracts clone on a branch where the contract (not the code) renames wellId -> wellID.
                    $d2 = $b.Args.ContractClone
                    git -c core.autocrlf=false clone -q (Join-Path $copy 'contracts') $d2 2>&1 | Out-Null
                    git -C $d2 config core.autocrlf false; git -C $d2 config user.name 'evidence-demo'; git -C $d2 config user.email 'evidence-demo@example.invalid'
                    git -C $d2 checkout -q -b feature/breaking-rename-field 2>&1 | Out-Null
                    $pf = Join-Path $d2 'specs\app-a-production\production-forecast-service.yaml'
                    Edit-Once $pf "        - wellId`n        - wellName" "        - wellID`n        - wellName"
                    Edit-Once $pf "        wellId:`n          `$ref: '#/components/schemas/WellId'`n        wellName:" "        wellID:`n          `$ref: '#/components/schemas/WellId'`n        wellName:"
                    git -C $d2 commit -q -am 'Contract renames Forecast.wellId -> wellID' 2>&1 | Out-Null
                }
                $a = $b.Args
                $logRel = 'breaks\' + ($b.Script -replace '\.ps1$', '.log.txt')
                $o = @(& (Join-Path $copy "scripts\$($b.Script)") @a *>&1 | ForEach-Object { "$_" })
                Save-ProtectedLog $o (Join-Path $raw $logRel)
                New-Result 'PASS' $null @('Demo results are evaluated in the break-demo matrix') (Links @((RawLink 'Script output' ($logRel -replace '\\', '/'))))
            }
        }

        # Phase 7 B and C: only the relevant check (gate 4 ContractTests, gate 6 MFE build).
        Invoke-Check 'breaks' 'Phase 7: demos B (provider ContractTests) and C (MFE build)' 'demo-batch' -Skip $script:BreaksBlocked {
            $notes = @()
            # B
            $models = Join-Path $copy 'app-a-production\well-registry-service\Models.cs'
            $orig = [IO.File]::ReadAllBytes($models)
            $ctProj = Join-Path $copy 'app-a-production\well-registry-service.ContractTests\WellRegistryService.ContractTests.csproj'
            try {
                Edit-Once $models '    double DailyCapacityBbl);' '    double DailyCapacity);'
                dotnet build $ctProj -nologo -v q 2>&1 | Out-Null
                $env:CONTRACT_TEST_RESULTS = 'breaks\B'
                $o = @(dotnet test $ctProj --no-build -nologo -v q 2>&1 | ForEach-Object { "$_" })
                $script:DemoB = [ordered]@{ exit = $LASTEXITCODE; output = ($o -join "`n") }
                Save-ProtectedLog $o (Join-Path $raw 'breaks\demo-B.log.txt')
            }
            finally {
                Remove-Item Env:\CONTRACT_TEST_RESULTS -ErrorAction SilentlyContinue
                [IO.File]::WriteAllBytes($models, $orig)
                dotnet build $ctProj -nologo -v q 2>&1 | Out-Null
            }
            # C
            $copyMfe = Join-Path $copy 'mfe\well-mfe'
            $app = Join-Path $copyMfe 'src\app\app.ts'
            $origApp = [IO.File]::ReadAllBytes($app)
            Push-Location $copyMfe
            try {
                cmd /c npm run generate:api 2>&1 | Out-Null
                Edit-Once $app 'well.dailyCapacityBbl.toLocaleString' 'well.dailyCapacity.toLocaleString'
                $o = @(cmd /c npx ng build 2>&1 | ForEach-Object { "$_" })
                $script:DemoC = [ordered]@{ exit = $LASTEXITCODE; output = ($o -join "`n") }
                Save-ProtectedLog $o (Join-Path $raw 'breaks\demo-C.log.txt')
            }
            finally { [IO.File]::WriteAllBytes($app, $origApp); Pop-Location }
            New-Result 'PASS' $null @('Demo results are evaluated in the break-demo matrix') (Links @((RawLink 'Demo B output' 'breaks/demo-B.log.txt'), (RawLink 'Demo C output' 'breaks/demo-C.log.txt')))
        }

        # Keep the copy's reports as raw evidence (without Specmatic's git clones).
        if (Test-Path $copyResults) {
            robocopy $copyResults (Join-Path $raw 'breaks\results') /E /XD .specmatic specmatic-work /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
        }

        # ---- evaluate every demo against the plan ----
        foreach ($d in $plan.BreakDemos) {
            $demo = [ordered]@{ id = $d.Id; phase = $d.Phase; change = $d.Change; layer = $d.Layer; expected = $d.Expected
                                actual = 'not run'; caught = $null; gate = [bool]$d.Gate; asExpected = $false; seconds = $null; raw = @() }
            try {
                switch ($d.Source) {
                    { $_ -in 'case1', 'case2' } {
                        $f = Join-Path $copyResults "$($d.Source)\break\$($d.Key)\experiment.json"
                        if (-not (Test-Path $f)) { break }
                        $x = Get-Content $f -Raw | ConvertFrom-Json
                        $spec = if ($null -ne $x.specmaticExit) { [bool]$x.specmaticCaught } else { $null }
                        $xu = if ($null -ne $x.xunitFailed) { [bool]$x.xunitFailed } else { $null }
                        $ok = [bool]$x.compiled
                        if ($null -ne $d.ExpectSpecmatic) { $ok = $ok -and ($spec -eq $d.ExpectSpecmatic) }
                        if ($null -ne $d.ExpectXunit) { $ok = $ok -and ($xu -eq $d.ExpectXunit) }
                        $parts = @()
                        if (-not $x.compiled) { $parts += 'did not compile' }
                        if ($null -ne $spec) { $parts += $(if ($spec) { "Specmatic failed ($($x.specmaticFailures)/$($x.specmaticTests))" } else { "Specmatic passed ($($x.specmaticTests))" }) }
                        if ($null -ne $xu) { $what = if ($x.mode -eq 'Consumer') { 'consumer tests' } else { 'xUnit' }; $parts += $(if ($xu) { "$what failed" } else { "$what passed" }) }
                        $demo.actual = $parts -join '; '
                        $demo.caught = (-not $x.compiled) -or ($spec -eq $true) -or ($xu -eq $true)
                        $demo.asExpected = $ok
                        $demo.seconds = $x.seconds
                        $base = "breaks/results/$($d.Source)/break/$($d.Key)"
                        $demo.raw = Links @((RawLink 'Specmatic HTML report' "$base/specmatic/build/reports/specmatic/test/html/index.html"),
                                            (RawLink 'xUnit output' "$base/xunit.txt"), (RawLink 'Consumer test output' "$base/consumer-tests.txt"))
                    }
                    'drift' {
                        $f = Join-Path $copyResults 'case3\drift\summary.json'
                        if (-not (Test-Path $f)) { break }
                        $val = "$((Get-Content $f -Raw | ConvertFrom-Json).($d.Key))"
                        $demo.actual = $val
                        $ok = $true
                        if ($d.ExpectExit) {
                            $m = [regex]::Match($val, 'exit=(-?\d+)')
                            $exit = if ($m.Success) { [int]$m.Groups[1].Value } else { $null }
                            $ok = ($null -ne $exit) -and $(if ($d.ExpectExit -eq 'zero') { $exit -eq 0 } else { $exit -ne 0 })
                            $demo.caught = ($null -ne $exit -and $exit -ne 0)
                        }
                        if ($d.ExpectText) { $ok = $ok -and $val.Contains($d.ExpectText); $demo.caught = $false }
                        $demo.asExpected = $ok
                        $demo.raw = Links @((RawLink 'Drift results' 'breaks/results/case3/drift/summary.json'),
                                            (RawLink 'D1a Specmatic report' 'breaks/results/case3/drift/d1a-provider-test/build/reports/specmatic/test/html/index.html'),
                                            (RawLink 'D2 Specmatic report' 'breaks/results/case3/drift/d2-provider-vs-new-contract/build/reports/specmatic/test/html/index.html'))
                    }
                    'mfe-compile' {
                        $f = Join-Path $copyResults 'case4-mfe\compile-break\summary.json'
                        if (-not (Test-Path $f)) { break }
                        $x = Get-Content $f -Raw | ConvertFrom-Json
                        $tsErr = (Get-Content (Join-Path $copyResults 'case4-mfe\compile-break\build.txt') | Select-String 'TS\d{4}' | Select-Object -First 1)
                        $demo.actual = "broken-contract build exit=$($x.brokenContractBuildExit)$(if ($tsErr) { " ($([regex]::Match($tsErr.Line, 'TS\d{4}').Value))" }); real-contract build exit=$($x.realContractBuildExit)"
                        $demo.caught = ($x.brokenContractBuildExit -ne 0)
                        $demo.asExpected = ($x.brokenContractBuildExit -ne 0) -and ($x.realContractBuildExit -eq 0)
                        $demo.raw = Links @((RawLink 'Build output' 'breaks/results/case4-mfe/compile-break/build.txt'))
                    }
                    'pr' {
                        $f = Join-Path $copyResults "pipeline\contracts-pr\$($d.Key)\summary.json"
                        if (-not (Test-Path $f)) { break }
                        $x = Get-Content $f -Raw | ConvertFrom-Json
                        $demo.actual = "MERGE $($x.merge)"
                        $demo.caught = "$($x.merge)".StartsWith('BLOCKED')
                        $ok = "$($x.merge)".StartsWith($d.ExpectMerge)
                        if ($d.ExpectGate) { $ok = $ok -and ($x.stoppedAt -eq $d.ExpectGate) }
                        $demo.asExpected = $ok
                        $demo.seconds = [int](($x.gates | Measure-Object -Property seconds -Sum).Sum)
                        $demo.raw = Links @((RawLink 'Spec diff' "breaks/results/pipeline/contracts-pr/$($d.Key)/change.diff.txt"),
                                            (RawLink 'Validate log' "breaks/results/pipeline/contracts-pr/$($d.Key)/01-validate-specs-examples.log.txt"),
                                            (RawLink 'Compatibility log' "breaks/results/pipeline/contracts-pr/$($d.Key)/03-backward-compatibility-vs-main.log.txt"))
                    }
                    'svc-provider' {
                        if (-not $script:DemoB) { break }
                        $fails = [regex]::Match($script:DemoB.output, 'Failures: (\d+)')
                        $demo.actual = "ContractTests exit=$($script:DemoB.exit)$(if ($fails.Success) { ", Specmatic failures: $($fails.Groups[1].Value)" })"
                        $demo.caught = ($script:DemoB.exit -ne 0)
                        $demo.asExpected = ($script:DemoB.exit -ne 0)
                        $demo.raw = Links @((RawLink 'ContractTests output' 'breaks/demo-B.log.txt'),
                                            (RawLink 'Specmatic HTML report' 'breaks/results/breaks/B/well-registry-service/build/reports/specmatic/test/html/index.html'))
                    }
                    'svc-mfe' {
                        if (-not $script:DemoC) { break }
                        $has = $script:DemoC.output.Contains($d.ExpectText)
                        $demo.actual = "ng build exit=$($script:DemoC.exit)$(if ($has) { " ($($d.ExpectText))" })"
                        $demo.caught = ($script:DemoC.exit -ne 0)
                        $demo.asExpected = ($script:DemoC.exit -ne 0) -and $has
                        $demo.raw = Links @((RawLink 'Build output' 'breaks/demo-C.log.txt'))
                    }
                }
            }
            catch { $demo.actual = "evaluation error: $(Protect-Text $_.Exception.Message 300)" }
            $demo.actual = Protect-Text $demo.actual 400
            $script:Demos += , $demo
        }
        $bad = @($script:Demos | Where-Object { -not $_.asExpected })
        Write-Status $(if ($bad.Count -eq 0) { 'PASS' } else { 'FAIL' }) ("[breaks] {0}/{1} demos behaved as expected" -f ($script:Demos.Count - $bad.Count), $script:Demos.Count)
    }
    finally {
        # The copy's own services and containers, then the copy itself (junction first), then restore output redirection.
        if (Test-Path (Join-Path $copy 'scripts\stop-services.ps1')) { & (Join-Path $copy 'scripts\stop-services.ps1') *> $null }
        $null = Stop-EvidenceProcesses $Root
        $script:CopyRemoved = Remove-TempCopy -Path $tempBase -Junctions @($junction)
        $env:PROTO_RESULTS_DIR = $raw
    }
}
}
finally {
    # ================================================================== hygiene (always)
    Write-Host "Section hygiene" -ForegroundColor Cyan
    $script:Blocked = $null
    Remove-Item Env:\CONTRACT_TEST_RESULTS -ErrorAction SilentlyContinue
    Invoke-Check 'hygiene' 'Services, stubs and mocks stopped; ports free' 'check' {
        $null = Stop-EvidenceProcesses $Root
        Start-Sleep -Seconds 1
        $left = @(docker ps -a --format '{{.Names}}' 2>$null | Where-Object { $_ -match '^(stub-|deps-|ct-deps-)' })
        $busy = Get-BusyPorts
        New-Result $(if ($left.Count -eq 0 -and $busy.Count -eq 0) { 'PASS' } else { 'FAIL' }) $null @("containers left: $($left.Count)", "busy ports: $($busy.Count)")
    }
    if (Test-Path $tempBase) { $null = Remove-TempCopy -Path $tempBase -Junctions @((Join-Path $tempBase 'p\mfe\well-mfe\node_modules')) }
    foreach ($repo in 'prototype', 'contracts') {
        $label = (Get-Culture).TextInfo.ToTitleCase($repo)
        Invoke-Check 'hygiene' "$label repo unchanged (changed files and their content)" 'check' {
            $dir = if ($repo -eq 'prototype') { $Root } else { Join-Path $Root 'contracts' }
            $now = @(git -C $dir status --porcelain 2>$null)
            $before = @($gitStart[$repo].changes)
            $fpNow = Get-TreeFingerprint $dir
            # Same set of changed files AND the same content (fingerprint of git diff + untracked files).
            $same = (($now -join "`n") -eq ($before -join "`n")) -and ($fpNow -eq $gitStart[$repo].fingerprint)
            $notes = @("changes before: $($before.Count), after: $($now.Count)", "content fingerprint before $($gitStart[$repo].fingerprint), after $fpNow")
            if (-not $same) {
                # (Compare-Object cannot take an empty list in PowerShell 5.1)
                $notes += @($now | Where-Object { $before -notcontains $_ } | Select-Object -First 10 | ForEach-Object { "new: $(Protect-Text $_)" })
                $notes += @($before | Where-Object { $now -notcontains $_ } | Select-Object -First 10 | ForEach-Object { "gone: $(Protect-Text $_)" })
            }
            New-Result $(if ($same) { 'PASS' } else { 'FAIL' }) $null $notes
        }
    }
    Invoke-Check 'hygiene' 'Throwaway copy removed; real node_modules intact' 'check' {
        $gone = -not (Test-Path $tempBase)
        $intact = (Test-Path $nmMarker) -and (@(Get-ChildItem (Join-Path $mfe 'node_modules') -ErrorAction SilentlyContinue).Count -eq $nmCount)
        New-Result $(if ($gone -and $intact) { 'PASS' } else { 'FAIL' }) $null @("temp copy present: $(-not $gone)", "node_modules entries: $nmCount before, $(@(Get-ChildItem (Join-Path $mfe 'node_modules') -ErrorAction SilentlyContinue).Count) after")
    }

    # ================================================================== verdict, files, report
    $ended = Get-Date
    $failed = @($script:Checks | Where-Object { $_.status -eq 'FAIL' }).Count
    $demosBad = @($script:Demos | Where-Object { -not $_.asExpected }).Count
    $verdict = if ($failed -gt 0 -or $demosBad -gt 0) { 'FAIL' } elseif ($partial) { 'PARTIAL' } else { 'PASS' }
    $E.run.durationSec = [math]::Round(($ended - $started).TotalSeconds)
    $E.run.verdict = $verdict
    $E.sections = @()
    foreach ($s in $plan.Sections) {
        if ($E.run.sections -notcontains $s.Id) { continue }
        $cs = @($script:Checks | Where-Object { $_.section -eq $s.Id })
        $st = if (@($cs | Where-Object { $_.status -eq 'FAIL' }).Count) { 'FAIL' } elseif ($cs.Count -and @($cs | Where-Object { $_.status -eq 'SKIPPED' }).Count -eq $cs.Count) { 'SKIPPED' } else { 'PASS' }
        if ($s.Id -eq 'breaks' -and $demosBad -gt 0) { $st = 'FAIL' }
        $E.sections += , ([ordered]@{ id = $s.Id; title = $s.Title; proves = $s.Proves; pairs = @($s.Pairs | Where-Object { $_ }); status = $st
                                      seconds = [int](($cs | ForEach-Object { $_.seconds } | Measure-Object -Sum).Sum); checks = $cs })
    }
    $E.breakDemos = @($script:Demos)
    $E.coverage = @($script:Checks | Where-Object { $_.coverage -and $null -ne $_.coverage.pct } | ForEach-Object {
        [ordered]@{ service = $_.coverage.service; check = $_.name; section = $_.section; pct = $_.coverage.pct; operations = $_.coverage.operations; rows = $_.coverage.rows } })
    $E.totals = [ordered]@{
        checks = $script:Checks.Count
        passed = @($script:Checks | Where-Object { $_.status -eq 'PASS' }).Count
        failed = $failed
        skipped = @($script:Checks | Where-Object { $_.status -eq 'SKIPPED' }).Count
        # 'derived' checks show a subset of another run's tests, so they are not counted twice.
        testCases = [int](($script:Checks | Where-Object { $_.tests -and $_.kind -ne 'derived' } | ForEach-Object { $_.tests.total } | Measure-Object -Sum).Sum)
        demos = $script:Demos.Count
        demosAsExpected = $script:Demos.Count - $demosBad
        demosCaught = @($script:Demos | Where-Object { $_.caught -eq $true }).Count
    }
    Save-Json $E (Join-Path $runDir 'evidence.json')
    Save-Json ([ordered]@{ id = $runId; started = $E.run.started; durationSec = $E.run.durationSec; verdict = $verdict; flags = $flags
                           checks = $E.totals.checks; failed = $failed; demos = $E.totals.demos; demosAsExpected = $E.totals.demosAsExpected }) (Join-Path $runDir 'run.json')

    # Keep the last 10 runs.
    $old = @(Get-ChildItem $historyRoot -Directory | Sort-Object Name -Descending | Select-Object -Skip 10)
    foreach ($o in $old) { Remove-Item $o.FullName -Recurse -Force -ErrorAction SilentlyContinue }

    & (Join-Path $PSScriptRoot 'evidence\Build-Report.ps1') -RunDir $runDir
    Remove-Item Env:\PROTO_RESULTS_DIR -ErrorAction SilentlyContinue

    $latest = Join-Path $Root 'evidence\latest\index.html'
    $color = if ($verdict -eq 'PASS') { 'Green' } else { 'Red' }
    Write-Host ''
    Write-Host ("VERDICT {0}: {1}/{2} checks passed, {3} failed, {4} skipped; {5} test cases; break demos {6}" -f $verdict, $E.totals.passed, $E.totals.checks, $failed, $E.totals.skipped, $E.totals.testCases,
        $(if ($script:Demos.Count) { "$($E.totals.demosAsExpected)/$($E.totals.demos) as expected ($($E.totals.demosCaught) caught)" } else { 'not run' })) -ForegroundColor $color
    Write-Host ("Duration {0:n1} min. Report: evidence\latest\index.html  (run folder evidence\history\{1})" -f (($ended - $started).TotalMinutes), $runId)
    if ($Open -and (Test-Path $latest)) { Start-Process $latest }
}
if ($verdict -eq 'PASS') { exit 0 } else { exit 1 }
