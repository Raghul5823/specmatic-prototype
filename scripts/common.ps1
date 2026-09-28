# Shared settings for all scripts. Dot-source it:  . "$PSScriptRoot\common.ps1"

$Root           = Split-Path -Parent $PSScriptRoot
$ResultsDir     = Join-Path $Root 'results'
$LogDir         = Join-Path $ResultsDir 'logs'
$PidFile        = Join-Path $ResultsDir 'service-pids.json'
$SpecmaticImage = 'specmatic/specmatic:2.55.0'
$TestToken      = 'test-token-123'

# One entry per service: name, folder, assembly name, port.
$Services = @(
    [pscustomobject]@{ Name = 'well-registry-service';       Dir = 'app-a-production\well-registry-service';       Dll = 'WellRegistryService';       Port = 5101 }
    [pscustomobject]@{ Name = 'production-forecast-service'; Dir = 'app-a-production\production-forecast-service'; Dll = 'ProductionForecastService'; Port = 5102 }
    [pscustomobject]@{ Name = 'change-request-service';      Dir = 'app-b-change-mgmt\change-request-service';      Dll = 'ChangeRequestService';      Port = 5201 }
    [pscustomobject]@{ Name = 'approval-service';            Dir = 'app-b-change-mgmt\approval-service';            Dll = 'ApprovalService';           Port = 5202 }
)

function Get-ProtoService([string]$Name) {
    $s = $Services | Where-Object Name -eq $Name
    if (-not $s) { throw "Unknown service '$Name'. Known: $($Services.Name -join ', ')" }
    return $s
}

function Wait-Healthy([int]$Port, [int]$TimeoutSeconds = 30) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest "http://localhost:$Port/health" -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -eq 200) { return $true }
        } catch { Start-Sleep -Milliseconds 500 }
    }
    return $false
}
