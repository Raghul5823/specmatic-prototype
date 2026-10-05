# Shared settings for all scripts. Dot-source it:  . "$PSScriptRoot\common.ps1"

$Root           = Split-Path -Parent $PSScriptRoot
# PROTO_RESULTS_DIR (absolute, inside $Root) redirects every script's output, e.g. the evidence run
# writes to evidence\history\<run>\raw so it never overwrites the committed results\ folder.
$ResultsDir     = if ($env:PROTO_RESULTS_DIR) { $env:PROTO_RESULTS_DIR.TrimEnd('\') } else { Join-Path $Root 'results' }
$LogDir         = Join-Path $ResultsDir 'logs'
$PidFile        = Join-Path $ResultsDir 'service-pids.json'
$SpecmaticImage = 'specmatic/specmatic:2.55.0'
$TestToken      = 'test-token-123'

# One entry per service: name, folder, assembly name, port, spec (relative to contracts/).
$Services = @(
    [pscustomobject]@{ Name = 'well-registry-service';       Dir = 'app-a-production\well-registry-service';       Dll = 'WellRegistryService';       Port = 5101; Spec = 'specs/app-a-production/well-registry-service.yaml' }
    [pscustomobject]@{ Name = 'production-forecast-service'; Dir = 'app-a-production\production-forecast-service'; Dll = 'ProductionForecastService'; Port = 5102; Spec = 'specs/app-a-production/production-forecast-service.yaml' }
    [pscustomobject]@{ Name = 'change-request-service';      Dir = 'app-b-change-mgmt\change-request-service';      Dll = 'ChangeRequestService';      Port = 5201; Spec = 'specs/app-b-change-mgmt/change-request-service.yaml' }
    [pscustomobject]@{ Name = 'approval-service';            Dir = 'app-b-change-mgmt\approval-service';            Dll = 'ApprovalService';           Port = 5202; Spec = 'specs/app-b-change-mgmt/approval-service.yaml' }
)

function ConvertTo-WorkPath([string]$Path) {
    # Host path inside $Root -> path inside the Specmatic container, where $Root is mounted at /work.
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -eq $Root) { return '/work' }
    if (-not $full.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$full' is outside the prototype root, so the Specmatic container cannot see it."
    }
    return '/work/' + ($full.Substring($Root.Length + 1) -replace '\\', '/')
}

function Get-ProtoService([string]$Name) {
    $s = $Services | Where-Object Name -eq $Name
    if (-not $s) { throw "Unknown service '$Name'. Known: $($Services.Name -join ', ')" }
    return $s
}

function Wait-Healthy([int]$Port, [int]$TimeoutSeconds = 30) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest "http://localhost:$Port/readiness" -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -eq 200) { return $true }
        } catch { Start-Sleep -Milliseconds 500 }
    }
    return $false
}
