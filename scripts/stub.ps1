<#
.SYNOPSIS
  Starts or stops a Specmatic stub (mock) for a provider, in Docker, on a fixed host port.
  The stub's container is named stub-<service>. contracts/ is mounted read-only.
.EXAMPLE
  .\scripts\stub.ps1 start well-registry-service 9101                 # spec only, serves at the root
  .\scripts\stub.ps1 start well-registry-service 9101 -Strict         # only example matches answer; others -> 400
  .\scripts\stub.ps1 start well-registry-service 9101 -Config specmatic\well-registry.mock.yaml   # e.g. baseUrl with /v2
  .\scripts\stub.ps1 stop  well-registry-service -SaveLogTo case2\stub-logs    # saves the stub's request log
#>
param(
    [Parameter(Mandatory, Position = 0)] [ValidateSet('start', 'stop')] [string]$Action,
    [Parameter(Mandatory, Position = 1)] [string]$Service,
    [Parameter(Position = 2)] [int]$Port,
    [switch]$Strict,
    [string]$Config,          # optional specmatic.yaml (v3) relative to the prototype root
    [string]$SaveLogTo        # on stop: folder under results\ to save the stub's log into
)
. "$PSScriptRoot\common.ps1"
$s = Get-ProtoService $Service
$name = "stub-$Service"

if ($Action -eq 'stop') {
    if ($SaveLogTo) {
        $dir = Join-Path $ResultsDir $SaveLogTo
        New-Item -ItemType Directory -Force $dir | Out-Null
        docker logs $name 2>&1 | ForEach-Object { "$_" } | Set-Content -Encoding utf8 (Join-Path $dir "$name.log.txt")
    }
    docker container rm --force $name 2>$null | Out-Null
    Write-Host "  STOP  $name"
    return
}

if (-not $Port) { throw 'Port is required for start.' }
docker container rm --force $name 2>$null | Out-Null
$dockerArgs = @('run', '-d', '--name', $name, '-p', "${Port}:9000",
    '-v', "${Root}:/work", '-v', "$(Join-Path $Root 'contracts'):/work/contracts:ro", '-w', '/work',
    $SpecmaticImage, 'mock')
if ($Config) { $dockerArgs += "--config=/work/$($Config -replace '\\', '/')" }
else { $dockerArgs += "/work/contracts/$($s.Spec)" }
if ($Strict) { $dockerArgs += '--strict' }
docker @dockerArgs | Out-Null

# Wait until the mock server reports it is running.
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline) {
    $log = docker logs $name 2>&1 | Out-String
    if ($log -match 'Press Ctrl') { break }
    if ($log -match '(?i)exception|error:') { break }
    Start-Sleep -Milliseconds 500
}
$mode = if ($Strict) { 'strict' } else { 'lenient' }
Write-Host "  UP    $name  http://localhost:$Port  ($mode)"
