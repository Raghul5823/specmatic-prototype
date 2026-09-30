<#
.SYNOPSIS
  Starts services in the background (built DLLs), waits for /readiness, records PIDs.
.EXAMPLE
  .\scripts\start-services.ps1                                  # all four
  .\scripts\start-services.ps1 -Only well-registry-service
  .\scripts\start-services.ps1 -Only production-forecast-service -Env @{ 'Downstream__WellRegistryBaseUrl' = 'http://localhost:9101' }
#>
param(
    [string[]]$Only,
    [hashtable]$Env = @{},     # extra environment variables, e.g. to point a consumer at a Specmatic stub
    [switch]$NoBuild
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

if (-not $NoBuild) {
    dotnet build (Join-Path $Root 'SpecmaticPrototype.sln') -nologo -v q
    if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
}

New-Item -ItemType Directory -Force $LogDir | Out-Null
$pids = @{}
if (Test-Path $PidFile) {
    (Get-Content $PidFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $pids[$_.Name] = $_.Value }
}

$targets = if ($Only) { $Only | ForEach-Object { Get-ProtoService $_ } } else { $Services }
foreach ($s in $targets) {
    if (Get-NetTCPConnection -LocalPort $s.Port -State Listen -ErrorAction SilentlyContinue) {
        throw "Port $($s.Port) is already in use. Run .\scripts\stop-services.ps1 first."
    }
    $bin = Join-Path $Root "$($s.Dir)\bin\Debug\net10.0"

    # Environment variables are inherited by the child process, so set them temporarily.
    $saved = @{}
    foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
    try {
        $p = Start-Process dotnet -ArgumentList "$($s.Dll).dll" -WorkingDirectory $bin -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput (Join-Path $LogDir "$($s.Name).log") `
            -RedirectStandardError  (Join-Path $LogDir "$($s.Name).err.log")
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
    $pids[$s.Name] = $p.Id

    if (Wait-Healthy $s.Port) { Write-Host ("  UP    {0,-28} http://localhost:{1}  (pid {2})" -f $s.Name, $s.Port, $p.Id) }
    else { throw "$($s.Name) did not become healthy on port $($s.Port). See $LogDir." }
}
$pids | ConvertTo-Json | Set-Content -Encoding utf8 $PidFile
