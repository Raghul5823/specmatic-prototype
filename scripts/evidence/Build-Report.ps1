<#
.SYNOPSIS
  Renders the evidence report (one self-contained HTML file: inline CSS/JS, the run's data embedded as JSON,
  no external links) from a run folder's evidence.json. Called by run-evidence.ps1; can also re-render a
  run without rerunning it.
    <run>\index.html             links raw reports in <run>\raw\
    evidence\latest\index.html   the same report, linking into ..\history\<run>\
    -Sample: evidence\sample\index.html (committed snapshot; raw links and run history left out)
.EXAMPLE
  .\scripts\evidence\Build-Report.ps1 -RunDir evidence\history\2026-10-05_1430
  .\scripts\evidence\Build-Report.ps1 -RunDir evidence\history\2026-10-05_1430 -Sample
#>
param([Parameter(Mandatory)] [string]$RunDir, [switch]$Sample)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$RunDir = (Resolve-Path $RunDir).Path
$runId = Split-Path $RunDir -Leaf
$template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'report-template.html'))
$evidence = [IO.File]::ReadAllText((Join-Path $RunDir 'evidence.json'))
$history = @(Get-ChildItem (Join-Path $Root 'evidence\history') -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending |
    Select-Object -First 10 | ForEach-Object { $f = Join-Path $_.FullName 'run.json'; if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } })

function Write-Report([string]$OutFile, [string]$RawBase, [string]$HistoryBase, [bool]$IsSample) {
    $view = [ordered]@{   # (a $null passed to a [string] parameter arrives as "", so the template tests for empty)
        rawBase = $RawBase; historyBase = $HistoryBase; sample = $IsSample; current = $runId
        generated = (Get-Date).ToString('yyyy-MM-dd HH:mm'); history = $(if ($IsSample) { @() } else { $history })
    }
    $data = '{"evidence":' + $evidence + ',"view":' + (ConvertTo-Json -InputObject $view -Depth 6 -Compress) + '}'
    $data = $data.Replace('</', '<\/')   # the data sits inside a <script> element: never close it early
    $html = $template.Replace('/*__EVIDENCE_DATA__*/null', $data)
    New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
    [IO.File]::WriteAllText($OutFile, $html, (New-Object Text.UTF8Encoding $false))
}

if ($Sample) {
    Write-Report (Join-Path $Root 'evidence\sample\index.html') $null $null $true
    Write-Host 'Report: evidence\sample\index.html'
    return
}
Write-Report (Join-Path $RunDir 'index.html') 'raw/' '../' $false
Write-Report (Join-Path $Root 'evidence\latest\index.html') "../history/$runId/raw/" '../history/' $false
