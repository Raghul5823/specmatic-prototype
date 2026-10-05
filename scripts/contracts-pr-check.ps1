<#
.SYNOPSIS
  CONTRACTS REPO PR PIPELINE (simulation of pipelines/contracts-pr-pipeline.yml).
  Gates, in order; the first failure stops the run and BLOCKS THE MERGE (exit code 1). No deploy stage.
    1. Validate specs + examples   specmatic examples validate --examples-to-validate BOTH, every spec
    2. Bundle check                every spec bundles into one document (external $refs resolve,
                                   no component-name clash); what the MFE client generator needs
    3. Backward compatibility      specmatic backward-compatibility-check against the base branch
.PARAMETER RepoDir
  A git checkout of the contracts repo with the PR branch checked out (use a short path on Windows).
.EXAMPLE
  .\scripts\contracts-pr-check.ps1 -RepoDir C:\temp\contracts-pr -BaseBranch main -RunName pr-compatible
#>
param(
    [Parameter(Mandatory)] [string]$RepoDir,
    [string]$BaseBranch = 'main',
    [string]$RunName = 'pr'
)
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\common.ps1"
$RepoDir = (Resolve-Path $RepoDir).Path
$runDir = Join-Path $ResultsDir "pipeline\contracts-pr\$RunName"
if (Test-Path $runDir) { Remove-Item $runDir -Recurse -Force }
New-Item -ItemType Directory -Force $runDir | Out-Null
$bundler = Join-Path $Root 'mfe\well-mfe\scripts\bundle-spec.mjs'   # the same bundler the MFE build uses
$specs = Get-ChildItem (Join-Path $RepoDir 'specs') -Recurse -Filter *.yaml |
    Where-Object { $_.DirectoryName -notmatch '_examples' } |
    ForEach-Object { $_.FullName.Substring($RepoDir.Length + 1) -replace '\\', '/' }

$gates = @(
    @{ Name = 'Validate specs + examples'; Run = {
        $failed = 0
        foreach ($s in $specs) {
            $o = docker run --rm -v "${RepoDir}:/repo:ro" -w /repo $SpecmaticImage examples validate --spec-file $s --examples-to-validate BOTH 2>&1 | ForEach-Object { "$_" }
            "--- $s  (exit $LASTEXITCODE)"; $o | Select-String 'valid|R\d{4}|expected|Error' | ForEach-Object { '    ' + $_.Line.Trim() }
            if ($LASTEXITCODE -ne 0) { $failed++ }
        }
        $failed } }
    @{ Name = 'Bundle check'; Run = {
        $failed = 0
        $tmp = Join-Path $runDir 'bundled'; New-Item -ItemType Directory -Force $tmp | Out-Null
        foreach ($s in $specs) {
            node $bundler (Join-Path $RepoDir $s) (Join-Path $tmp ((Split-Path $s -Leaf) -replace '\.yaml$', '.json')) 2>&1 | ForEach-Object { "    $_" }
            if ($LASTEXITCODE -ne 0) { $failed++ }
        }
        $failed } }
    @{ Name = "Backward compatibility vs $BaseBranch"; Run = {
        docker run --rm -v "${RepoDir}:/repo" -w /repo $SpecmaticImage backward-compatibility-check --repo-dir=/repo "--base-branch=$BaseBranch" 2>&1 |
            ForEach-Object { "$_" } | Select-String -Pattern 'Specs that have changed|^\s+\d+\. /repo|Verdict|INCOMPATIBLE|COMPATIBLE|>> |expects|Files checked' | ForEach-Object { '    ' + $_.Line.Trim() }
        $LASTEXITCODE } }
)

$branch = git -C $RepoDir rev-parse --abbrev-ref HEAD
$change = git -C $RepoDir log -1 --format=%s
Write-Host "CONTRACTS PR PIPELINE  run=$RunName  branch=$branch  base=$BaseBranch"
Write-Host "  change: $change"
$results = @(); $stoppedAt = $null; $i = 0
foreach ($g in $gates) {
    $i++
    $log = Join-Path $runDir ("{0:00}-{1}.log.txt" -f $i, ($g.Name -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLower())
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = & $g.Run
    $code = [int]($out | Select-Object -Last 1)
    $out | Select-Object -SkipLast 1 | ForEach-Object { "$_".Replace($RepoDir, '<contracts-checkout>').Replace($Root, '.') } | Set-Content -Encoding utf8 $log
    $status = if ($code -eq 0) { 'PASSED' } else { 'FAILED' }
    $results += [ordered]@{ gate = $g.Name; status = $status; seconds = [math]::Round($sw.Elapsed.TotalSeconds) }
    Write-Host ("  [{0}/{1}] {2,-36} {3} ({4}s)" -f $i, $gates.Count, $g.Name, $status, [math]::Round($sw.Elapsed.TotalSeconds))
    if ($code -ne 0) { $stoppedAt = $g.Name; break }
}
foreach ($g in $gates | Select-Object -Skip $results.Count) { $results += [ordered]@{ gate = $g.Name; status = 'SKIPPED'; seconds = 0 } }
$merge = if ($stoppedAt) { "BLOCKED by gate '$stoppedAt'" } else { 'ALLOWED' }
Write-Host "  MERGE: $merge"
[ordered]@{ pipeline = 'contracts-pr'; run = $RunName; branch = $branch; base = $BaseBranch; change = $change
            gates = $results; stoppedAt = $stoppedAt; merge = $merge } | ConvertTo-Json -Depth 4 |
    Set-Content -Encoding utf8 (Join-Path $runDir 'summary.json')
if ($stoppedAt) { exit 1 } else { exit 0 }
