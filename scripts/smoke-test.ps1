<#
.SYNOPSIS
  Phase 1 sanity check: the four services run, enforce the token, return ProblemDetails,
  and the intra-app and cross-app call chains work. Not a contract test.
  Assumes start-services.ps1 has been run. Output -> results\phase1\smoke-test.txt
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

function Invoke-Api([string]$Method, [string]$Url, [object]$Body, [switch]$NoToken) {
    $headers = @{}
    if (-not $NoToken) { $headers['Authorization'] = "Bearer $TestToken" }
    $params = @{ Method = $Method; Uri = $Url; Headers = $headers; UseBasicParsing = $true }
    if ($null -ne $Body) { $params['Body'] = ($Body | ConvertTo-Json -Compress); $params['ContentType'] = 'application/json' }
    try {
        $r = Invoke-WebRequest @params
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Type = $r.Headers['Content-Type']; Body = $r.Content }
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if (-not $resp) { throw }
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Type = $resp.ContentType; Body = $reader.ReadToEnd() }
    }
}

$checks = @(
    # name, method, url, body, noToken, expected status  (leading comma keeps each row an array)
    ,@('well-registry: list ACTIVE wells',           'GET',  'http://localhost:5101/wells?status=ACTIVE', $null, $false, 200)
    ,@('well-registry: get W-001',                   'GET',  'http://localhost:5101/wells/W-001', $null, $false, 200)
    ,@('well-registry: unknown well -> 404',         'GET',  'http://localhost:5101/wells/W-999', $null, $false, 404)
    ,@('well-registry: no token -> 401',             'GET',  'http://localhost:5101/wells', $null, $true, 401)
    ,@('well-registry: bad body -> 400',             'POST', 'http://localhost:5101/wells', @{ name = 'X' }, $false, 400)
    ,@('well-registry: string for number -> 400',    'POST', 'http://localhost:5101/wells', @{ name='N'; field='F'; status='ACTIVE'; latitude='1'; longitude=2; spudDate='2024-01-01'; dailyCapacityBbl=10 }, $false, 400)
    ,@('well-registry: create well -> 201',          'POST', 'http://localhost:5101/wells', @{ name='Eagle-9'; field='Eagle Ford'; status='ACTIVE'; latitude=28.7; longitude=-98.1; spudDate='2024-05-01'; dailyCapacityBbl=650 }, $false, 201)
    ,@('approval: small change -> 201 APPROVED',     'POST', 'http://localhost:5202/approvals', @{ changeRequestId='CR-9999'; type='CHOKE_CHANGE'; capacityDeltaBbl=100 }, $false, 201)
    ,@('change-request: list APPROVED for W-001',    'GET',  'http://localhost:5201/change-requests?wellId=W-001&status=APPROVED', $null, $false, 200)
    ,@('CHAIN A->A, A->B: create forecast W-001',    'POST', 'http://localhost:5102/forecasts', @{ wellId='W-001'; horizonMonths=3; declineRatePct=5 }, $false, 201)
    ,@('forecast: shut-in well -> 400',              'POST', 'http://localhost:5102/forecasts', @{ wellId='W-003'; horizonMonths=3; declineRatePct=5 }, $false, 400)
    ,@('CHAIN B->A, B->B: create CR linked to F-5001','POST', 'http://localhost:5201/change-requests', @{ title='Choke tweak'; wellId='W-001'; forecastId='F-5001'; type='CHOKE_CHANGE'; capacityDeltaBbl=50; requestedBy='qa.user' }, $false, 201)
    ,@('change-request: unknown forecast -> 400',    'POST', 'http://localhost:5201/change-requests', @{ title='X'; wellId='W-001'; forecastId='F-9999'; type='WORKOVER'; capacityDeltaBbl=10; requestedBy='qa.user' }, $false, 400)
    ,@('unknown route -> 404 ProblemDetails',        'GET',  'http://localhost:5202/nope', $null, $false, 404)
)

$outDir = Join-Path $ResultsDir 'phase1'
New-Item -ItemType Directory -Force $outDir | Out-Null
$lines = @(); $failed = 0
foreach ($c in $checks) {
    $r = Invoke-Api -Method $c[1] -Url $c[2] -Body $c[3] -NoToken:$c[4]
    $ok = $r.Status -eq $c[5]
    if (-not $ok) { $failed++ }
    $lines += ('[{0}] {1}  (expected {2}, got {3}, {4})' -f ($(if ($ok) { 'PASS' } else { 'FAIL' })), $c[0], $c[5], $r.Status, $r.Type)
    $lines += "       $($c[1]) $($c[2])"
    $lines += "       $($r.Body)"
}
$lines += ''; $lines += "$($checks.Count - $failed)/$($checks.Count) passed"
$lines | Tee-Object -FilePath (Join-Path $outDir 'smoke-test.txt')
if ($failed -gt 0) { exit 1 }
