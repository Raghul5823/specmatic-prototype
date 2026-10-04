<#
.SYNOPSIS
  Phase 6: runs the Angular MFE's Playwright tests against a STRICT Specmatic stub of
  well-registry (served under /v2). Starts the stub, runs `npm run test:e2e`, stops the stub,
  and copies the reports to results\<Out>\.
.EXAMPLE
  .\scripts\mfe-e2e.ps1 -Out case4-mfe\e2e
#>
param([string]$Out = 'case4-mfe\e2e')
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\common.ps1"
$mfe = Join-Path $Root 'mfe\well-mfe'
$outDir = Join-Path $ResultsDir $Out
if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
New-Item -ItemType Directory -Force $outDir | Out-Null

& "$PSScriptRoot\stub.ps1" start well-registry-service 9101 -Strict -Config specmatic\well-registry.mock.yaml
Push-Location $mfe
try {
    $env:NG_CLI_ANALYTICS = 'false'
    npm run test:e2e 2>&1 | ForEach-Object { "$_".Replace($Root, '.') } | Tee-Object -FilePath (Join-Path $outDir 'console.txt')
    $exit = $LASTEXITCODE
}
finally {
    Pop-Location
    & "$PSScriptRoot\stub.ps1" stop well-registry-service -SaveLogTo $Out
}
Copy-Item (Join-Path $mfe 'test-results\junit.xml') $outDir -ErrorAction SilentlyContinue
Copy-Item (Join-Path $mfe 'playwright-report') (Join-Path $outDir 'playwright-report') -Recurse -ErrorAction SilentlyContinue
Write-Host "  MFE e2e exit=$exit  -> results\$Out"
exit $exit
