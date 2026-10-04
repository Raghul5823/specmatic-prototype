<#
.SYNOPSIS
  Phase 6: shows a contract break becoming a TypeScript COMPILE error in the Angular MFE.
  1. Copies the well-registry spec (+ common.yaml) to a temp folder and renames the response
     field dailyCapacityBbl -> dailyCapacity (the contracts repo itself is not touched).
  2. Generates the client from that copy and runs `ng build` -> expected to FAIL.
  3. Regenerates from the real contract and builds again -> expected to PASS.
  Output -> results\case4-mfe\compile-break\
#>
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\common.ps1"
$mfe = Join-Path $Root 'mfe\well-mfe'
$out = Join-Path $ResultsDir 'case4-mfe\compile-break'
New-Item -ItemType Directory -Force $out | Out-Null
$env:NG_CLI_ANALYTICS = 'false'

# 1. Modified copy of the contract, same folder layout so the relative $ref still resolves.
$tmp = Join-Path $mfe '.generated\break'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $tmp 'specs\app-a-production'), (Join-Path $tmp 'common') | Out-Null
Copy-Item (Join-Path $Root 'contracts\common\common.yaml') (Join-Path $tmp 'common')
$specSrc = Join-Path $Root 'contracts\specs\app-a-production\well-registry-service.yaml'
$spec = Join-Path $tmp 'specs\app-a-production\well-registry-service.yaml'
$text = [IO.File]::ReadAllText($specSrc)
$find1 = 'required: [id, name, field, status, latitude, longitude, spudDate, dailyCapacityBbl]'
$find2 = "        dailyCapacityBbl:`n          type: number`n          minimum: 0`n          description: Nameplate capacity in barrels per day."
foreach ($f in $find1, $find2) { if (([regex]::Matches($text, [regex]::Escape($f))).Count -ne 1) { throw "not found exactly once: $f" } }
$text = $text.Replace($find1, $find1.Replace('dailyCapacityBbl', 'dailyCapacity')).Replace($find2, $find2.Replace('dailyCapacityBbl:', 'dailyCapacity:'))
[IO.File]::WriteAllText($spec, $text)

Push-Location $mfe
try {
    # 2. Generate from the BROKEN contract and build (ng build directly: no prebuild regeneration).
    $log = @('### Contract change: Well.dailyCapacityBbl renamed to dailyCapacity', '')
    $log += (node scripts/bundle-spec.mjs $spec .generated/break.json 2>&1 | ForEach-Object { "$_" })
    $log += (npx ng-openapi-gen --input .generated/break.json --output src/app/api --ignoreUnusedModels false 2>&1 | Select-Object -Last 1 | ForEach-Object { "$_" })
    $log += '', '### npx ng build  (client generated from the BROKEN contract)'
    $log += (npx ng build 2>&1 | ForEach-Object { "$_".Replace($Root, '.') })
    $brokenExit = $LASTEXITCODE
    $log += "exit=$brokenExit"

    # 3. Back to the real contract.
    $log += '', '### npm run build  (prebuild regenerates the client from the REAL contract)'
    $log += (npm run build 2>&1 | ForEach-Object { "$_".Replace($Root, '.') } | Select-String 'Bundled|Generation|Initial total|complete|error' | ForEach-Object { $_.Line })
    $fixedExit = $LASTEXITCODE
    $log += "exit=$fixedExit"
}
finally {
    Pop-Location
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
$log | Set-Content -Encoding utf8 (Join-Path $out 'build.txt')
[ordered]@{ brokenContractBuildExit = $brokenExit; realContractBuildExit = $fixedExit } | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $out 'summary.json')
$log | Select-String -Pattern 'TS\d+|error|exit=|Property' | ForEach-Object { $_.Line }
