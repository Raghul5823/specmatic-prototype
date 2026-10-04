<#
.SYNOPSIS
  Starts or stops the DEPENDENCY mocks declared in a provider's Specmatic v3 config
  (`specmatic mock --config` serves the `dependencies` section; `specmatic test --config`
  only tests the `systemUnderTest`, so both are needed for a provider test with mocked dependencies).
.EXAMPLE
  .\scripts\deps.ps1 start production-forecast -Config specmatic\production-forecast.specmatic.yaml -Ports 9101,9201
  .\scripts\deps.ps1 stop  production-forecast -SaveLogTo case3\stub-logs
#>
param(
    [Parameter(Mandatory, Position = 0)] [ValidateSet('start', 'stop')] [string]$Action,
    [Parameter(Mandatory, Position = 1)] [string]$Name,
    [string]$Config,
    [int[]]$Ports = @(),
    [string]$SaveLogTo
)
. "$PSScriptRoot\common.ps1"
$container = "deps-$Name"

if ($Action -eq 'stop') {
    if ($SaveLogTo) {
        $dir = Join-Path $ResultsDir $SaveLogTo
        New-Item -ItemType Directory -Force $dir | Out-Null
        docker logs $container 2>&1 | ForEach-Object { "$_" } | Set-Content -Encoding utf8 (Join-Path $dir "$container.log.txt")
    }
    docker container rm --force $container 2>$null | Out-Null
    Write-Host "  STOP  $container"
    return
}

docker container rm --force $container 2>$null | Out-Null
$work = Join-Path $ResultsDir 'specmatic-work'
New-Item -ItemType Directory -Force $work | Out-Null
$dockerArgs = @('run', '-d', '--name', $container)
foreach ($p in $Ports) { $dockerArgs += @('-p', "${p}:${p}") }
$dockerArgs += @('-v', "${Root}:/work", '-v', "$(Join-Path $Root 'contracts'):/work/contracts:ro",
    '-w', '/work/results/specmatic-work', $SpecmaticImage, 'mock', "--config=/work/$($Config -replace '\\', '/')")
docker @dockerArgs | Out-Null

$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline) {
    if (docker logs $container 2>&1 | Select-String -Quiet 'Press Ctrl') { break }
    Start-Sleep -Milliseconds 500
}
docker logs $container 2>&1 | ForEach-Object { "$_" } | Select-String '^- http://' | ForEach-Object { Write-Host "  UP    $container  $($_.Line.Trim().TrimStart('- '))" }
