<#
.SYNOPSIS
  Runs Specmatic's backward-compatibility-check on a git checkout of the contract repo.
  The check is git-based: it compares the spec files changed on the current branch
  against --base-branch. Output -> results\<Out>\console.txt + summary.json (incl. exit code).
.EXAMPLE
  .\scripts\compat-check.ps1 -RepoDir $clone -BaseBranch main -Out case3\compat\01-compatible
#>
param(
    [Parameter(Mandatory)] [string]$RepoDir,     # a git checkout of the contracts repo (a throwaway clone)
    [Parameter(Mandatory)] [string]$BaseBranch,  # branch (or tag) to compare against
    [Parameter(Mandatory)] [string]$Out,
    [string[]]$ExtraArgs = @()
)
. "$PSScriptRoot\common.ps1"
$outDir = Join-Path $ResultsDir $Out
New-Item -ItemType Directory -Force $outDir | Out-Null

$branch = git -C $RepoDir rev-parse --abbrev-ref HEAD
$dockerArgs = @('run', '--rm', '-v', "${RepoDir}:/repo", '-w', '/repo', $SpecmaticImage,
    'backward-compatibility-check', '--repo-dir=/repo', "--base-branch=$BaseBranch") + $ExtraArgs
$console = Join-Path $outDir 'console.txt'
@("Branch under check: $branch   Base: $BaseBranch",
  "Change: $(git -C $RepoDir log -1 --format=%s)",
  ("Command: docker $($dockerArgs -join ' ')" -replace [regex]::Escape($RepoDir), '<contracts-clone>'), '') | Set-Content -Encoding utf8 $console
& docker @dockerArgs 2>&1 | ForEach-Object { "$_" } | Add-Content -Encoding utf8 $console
$exit = $LASTEXITCODE
[ordered]@{ branch = $branch; base = $BaseBranch; exitCode = $exit; verdict = $(if ($exit -eq 0) { 'PASS (exit 0)' } else { "FAIL (exit $exit)" }) } |
    ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $outDir 'summary.json')
Write-Host ("  {0}: branch={1} base={2} exit={3}" -f $Out, $branch, $BaseBranch, $exit)
