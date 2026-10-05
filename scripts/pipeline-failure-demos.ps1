<#
.SYNOPSIS
  Phase 7: one deliberate failure per gate type, each run on its own, recording which gate stopped it.
    A  Contracts PR pipeline (throwaway clone of the contracts repo, one branch per scenario):
       A1 optional field (expect ALLOWED), A2 deprecated endpoint (expect ALLOWED),
       A3 new REQUIRED request field (expect BLOCKED at compatibility),
       A4 renamed required response field (expect BLOCKED, examples no longer match)
    B  Service pipeline: provider code breaks its contract (expect stop at provider contract tests)
    C  Service pipeline: MFE code relies on a field the contract lacks (expect stop at MFE build)
  Code changes are restored byte-for-byte. Summary -> results\pipeline\failure-demos.md
.PARAMETER Only
  Run only some parts, e.g. -Only A or -Only B,C
#>
param([string[]]$Only = @('A', 'B', 'C'), [string[]]$Pick = @())   # -Pick A3,A4 runs only those A scenarios
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\common.ps1"
$rows = @()

function Edit-Once([string]$Path, [string]$Find, [string]$Replace) {
    $t = [IO.File]::ReadAllText($Path)
    if (([regex]::Matches($t, [regex]::Escape($Find))).Count -ne 1) { throw "Find text not exactly once in $Path" }
    [IO.File]::WriteAllText($Path, $t.Replace($Find, $Replace))
}
function Summary([string]$Path) { Get-Content $Path -Raw | ConvertFrom-Json }

# ---------------- A: contracts PR pipeline ----------------
if ($Only -contains 'A') {
    $clone = Join-Path (Get-Item $env:TEMP).FullName 'sp-pr'   # short path (Windows 260-char limit)
    if (Test-Path $clone) { Remove-Item $clone -Recurse -Force }
    git -c core.autocrlf=false clone -q (Join-Path $Root 'contracts') $clone
    # persist it: otherwise every later `git checkout` re-applies the global autocrlf=true (CRLF)
    git -C $clone config core.autocrlf false
    git -C $clone config user.name 'pr-demo'; git -C $clone config user.email 'pr-demo@example.invalid'
    $wr = Join-Path $clone 'specs\app-a-production\well-registry-service.yaml'
    $pf = Join-Path $clone 'specs\app-a-production\production-forecast-service.yaml'
    $scenarios = @(
        @{ Run = 'A1-compatible-optional-field'; Expect = 'ALLOWED'; Msg = 'Add optional response field Forecast.notes'
           Edit = { Edit-Once $pf "        createdAt:`n          type: string`n          format: date-time`n" "        createdAt:`n          type: string`n          format: date-time`n        notes:`n          type: string`n" } }
        @{ Run = 'A2-deprecate-endpoint'; Expect = 'ALLOWED'; Msg = 'Mark GET /wells (listWells) as deprecated'
           Edit = { Edit-Once $wr "      operationId: listWells`n" "      operationId: listWells`n      deprecated: true`n" } }
        @{ Run = 'A3-breaking-required-request-field'; Expect = 'BLOCKED'; Msg = 'Make new request field CreateWellRequest.operator REQUIRED'
           Edit = {
               Edit-Once $wr "      required: [name, field, status, latitude, longitude, spudDate, dailyCapacityBbl]`n      properties:`n" "      required: [name, field, status, latitude, longitude, spudDate, dailyCapacityBbl, operator]`n      properties:`n        operator:`n          type: string`n          minLength: 1`n"
               Edit-Once $wr "value: { name: Eagle-9, field: Eagle Ford, status: ACTIVE, latitude: 28.7, longitude: -98.1, spudDate: '2024-05-01', dailyCapacityBbl: 650 }" "value: { name: Eagle-9, field: Eagle Ford, status: ACTIVE, latitude: 28.7, longitude: -98.1, spudDate: '2024-05-01', dailyCapacityBbl: 650, operator: Ops-Team-1 }" } }
        @{ Run = 'A5-breaking-examples-updated'; Expect = 'BLOCKED'; Msg = 'Make CreateWellRequest.operator REQUIRED and update every example (careful but breaking PR)'
           Edit = {
               Edit-Once $wr "      required: [name, field, status, latitude, longitude, spudDate, dailyCapacityBbl]`n      properties:`n" "      required: [name, field, status, latitude, longitude, spudDate, dailyCapacityBbl, operator]`n      properties:`n        operator:`n          type: string`n          minLength: 1`n"
               Edit-Once $wr "value: { name: Eagle-9, field: Eagle Ford, status: ACTIVE, latitude: 28.7, longitude: -98.1, spudDate: '2024-05-01', dailyCapacityBbl: 650 }" "value: { name: Eagle-9, field: Eagle Ford, status: ACTIVE, latitude: 28.7, longitude: -98.1, spudDate: '2024-05-01', dailyCapacityBbl: 650, operator: Ops-Team-1 }"
               Edit-Once (Join-Path $clone 'specs\app-a-production\well-registry-service_examples\provider__create_well_invalid_token_401.json') '"dailyCapacityBbl": 500 }' '"dailyCapacityBbl": 500, "operator": "Ops-Team-1" }' } }
        @{ Run = 'A4-breaking-rename-response-field'; Expect = 'BLOCKED'; Msg = 'Rename required response field Forecast.wellId -> wellID'
           Edit = {
               Edit-Once $pf "        - wellId`n        - wellName" "        - wellID`n        - wellName"
               Edit-Once $pf "        wellId:`n          `$ref: '#/components/schemas/WellId'`n        wellName:" "        wellID:`n          `$ref: '#/components/schemas/WellId'`n        wellName:" } }
    )
    if ($Pick.Count -gt 0) { $scenarios = $scenarios | Where-Object { $Pick -contains ($_.Run -split '-')[0] } }
    foreach ($s in $scenarios) {
        git -C $clone checkout -q main
        git -C $clone checkout -q -b "pr/$($s.Run)"
        & $s.Edit
        git -C $clone commit -q -am $s.Msg
        & "$PSScriptRoot\contracts-pr-check.ps1" -RepoDir $clone -BaseBranch main -RunName $s.Run
        $r = Summary (Join-Path $ResultsDir "pipeline\contracts-pr\$($s.Run)\summary.json")
        $rows += [pscustomobject]@{ Demo = $s.Run; Pipeline = 'contracts PR'; Change = $s.Msg; Expected = $s.Expect
            StoppedAt = $(if ($r.stoppedAt) { $r.stoppedAt } else { '-' }); Outcome = "MERGE $($r.merge)" }
    }
    # keep the exact spec diffs (one file per scenario), then remove the clone
    foreach ($s in $scenarios) {
        $diff = git -C $clone diff "main..pr/$($s.Run)" -- specs
        [IO.File]::WriteAllLines((Join-Path $ResultsDir "pipeline\contracts-pr\$($s.Run)\change.diff.txt"), [string[]]$diff)
    }
    Remove-Item $clone -Recurse -Force
}

# ---------------- B and C: service pipeline ----------------
$service = @(
    @{ Key = 'B'; Run = 'fail-provider'; Expect = 'stop at Provider contract tests'
       Change = 'well-registry code renames response field dailyCapacityBbl -> dailyCapacity (contract unchanged)'
       File = 'app-a-production\well-registry-service\Models.cs'; Find = '    double DailyCapacityBbl);'; Replace = '    double DailyCapacity);' }
    @{ Key = 'C'; Run = 'fail-mfe'; Expect = 'stop at MFE: client + build'
       Change = 'MFE code reads well.dailyCapacity, a field the contract does not have'
       File = 'mfe\well-mfe\src\app\app.ts'; Find = 'well.dailyCapacityBbl.toLocaleString'; Replace = 'well.dailyCapacity.toLocaleString' }
)
foreach ($d in $service | Where-Object { $Only -contains $_.Key }) {
    $path = Join-Path $Root $d.File
    $original = [IO.File]::ReadAllBytes($path)
    try {
        Edit-Once $path $d.Find $d.Replace
        & "$PSScriptRoot\run-all.ps1" -RunName $d.Run
    }
    finally { [IO.File]::WriteAllBytes($path, $original) }
    $r = Summary (Join-Path $ResultsDir "pipeline\$($d.Run)\summary.json")
    $rows += [pscustomobject]@{ Demo = "$($d.Key) $($d.Run)"; Pipeline = 'service'; Change = $d.Change; Expected = $d.Expect
        StoppedAt = $(if ($r.stoppedAt) { $r.stoppedAt } else { '-' }); Outcome = "DeployDev $($r.deployDev)" }
}
if ($Only -contains 'B' -or $Only -contains 'C') { dotnet build (Join-Path $Root 'SpecmaticPrototype.sln') -nologo -v q | Out-Null }

$rows | Format-Table -AutoSize | Out-String -Width 220

# Summary table built from ALL saved run summaries (so partial reruns still give the full picture)
$expected = @{ 'A1' = 'ALLOWED'; 'A2' = 'ALLOWED'; 'A3' = 'BLOCKED'; 'A4' = 'BLOCKED'; 'A5' = 'BLOCKED'; 'fail-provider' = 'stop at Provider contract tests'; 'fail-mfe' = 'stop at MFE: client + build' }
$md = @('| Demo | Pipeline | Change | Expected | Stopped at gate | Outcome |', '|---|---|---|---|---|---|')
foreach ($f in Get-ChildItem (Join-Path $ResultsDir 'pipeline\contracts-pr') -Recurse -Filter summary.json -ErrorAction SilentlyContinue | Sort-Object { $_.Directory.Name }) {
    $r = Summary $f.FullName
    $md += "| $($r.run) | contracts PR | $($r.change) | MERGE $($expected[($r.run -split '-')[0]]) | $(if ($r.stoppedAt) { $r.stoppedAt } else { '-' }) | MERGE $($r.merge) |"
}
foreach ($run in 'fail-provider', 'fail-mfe') {
    $f = Join-Path $ResultsDir "pipeline\$run\summary.json"
    if (-not (Test-Path $f)) { continue }
    $r = Summary $f
    $change = ($service | Where-Object Run -eq $run).Change
    $md += "| $run | service | $change | $($expected[$run]) | $(if ($r.stoppedAt) { $r.stoppedAt } else { '-' }) | DeployDev $($r.deployDev) |"
}
$md | Set-Content -Encoding utf8 (Join-Path $ResultsDir 'pipeline\failure-demos.md')
$md
