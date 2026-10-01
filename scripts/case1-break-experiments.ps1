<#
.SYNOPSIS
  Phase 3c: runs every Case 1 break experiment on well-registry-service, one at a time
  (apply -> build -> xUnit -> Specmatic -> revert), then writes results\case1\break\summary.md.
  Takes a while: each experiment rebuilds the solution and starts a Specmatic container
  (about 4-5 minutes each on the evaluation laptop).
.PARAMETER From
  Start at this experiment number (e.g. 6) to resume an interrupted run.
#>
param([int]$From = 1)
. "$PSScriptRoot\common.ps1"

$models    = 'app-a-production\well-registry-service\Models.cs'
$endpoints = 'app-a-production\well-registry-service\WellEndpoints.cs'
$repo      = 'app-a-production\well-registry-service\WellRepository.cs'
$defaults  = 'shared\Prototype.ServiceDefaults\ServiceDefaults.cs'
$spec      = 'contracts\specs\app-a-production\well-registry-service.yaml'
$jsonNs    = 'System.Text.Json.Serialization'

$experiments = @(
    @{ Out = '01-rename-field'; Name = 'Rename response field dailyCapacityBbl -> dailyCapacity'; Expected = 'caught'
       Changes = @(@{ File = $models; Find = '    double DailyCapacityBbl);'; Replace = '    double DailyCapacity);' }) }
    @{ Out = '02-change-type'; Name = 'Change field type: latitude number -> string ("28.5")'; Expected = 'caught'
       Changes = @(@{ File = $models; Find = '    double Latitude,'; Replace = "    [property: $jsonNs.JsonNumberHandling($jsonNs.JsonNumberHandling.WriteAsString)] double Latitude," }) }
    @{ Out = '03-remove-required-field'; Name = 'Remove required response field spudDate'; Expected = 'caught'
       Changes = @(@{ File = $models; Find = '    DateOnly SpudDate,'; Replace = "    [property: $jsonNs.JsonIgnore] DateOnly SpudDate," }) }
    @{ Out = '04-change-success-status'; Name = 'Change success status of POST /wells: 201 -> 200'; Expected = 'caught'
       Changes = @(@{ File = $endpoints; Find = 'return Results.Created($"/v2/wells/{well.Id}", well);'; Replace = 'return Results.Ok(well);' }) }
    @{ Out = '05-non-problemdetails-error'; Name = '404 body is {message} (application/json), not ProblemDetails'; Expected = 'caught'
       Changes = @(@{ File = $endpoints; Find = ': Results.Problem(statusCode: 404, title: "Not Found", detail: $"Well {wellId} does not exist.");'; Replace = ': Results.NotFound(new { message = $"Well {wellId} does not exist." });' }) }
    @{ Out = '06-drop-auth-check'; Name = 'Drop the auth check (every request accepted)'; Expected = 'caught via 401 examples'
       Changes = @(@{ File = $defaults; Find = '|| context.Request.Headers.Authorization.ToString() == _expected)'; Replace = '|| true)' }) }
    @{ Out = '07-wrong-business-logic'; Name = 'Wrong logic, correct shape: status filter inverted (SHUT_IN returns the ACTIVE wells)'; Expected = 'NOT caught by Specmatic'
       Changes = @(@{ File = $repo; Find = 'w.Status == status'; Replace = 'w.Status != status' }) }
    @{ Out = '08-new-field-no-spec-update'; Name = 'Provider adds NEW response field "region" without a spec update'; Expected = 'caught (closed schema)'
       Changes = @(@{ File = $models; Find = '    double DailyCapacityBbl);'; Replace = "    double DailyCapacityBbl)`n{`n    public string Region => `"Americas`";`n}" }) }
    @{ Out = '09-new-field-additionalProperties-true'; Name = 'Same new field, but spec Well schema has additionalProperties: true'; Expected = 'not caught (open schema)'
       Changes = @(
           @{ File = $models; Find = '    double DailyCapacityBbl);'; Replace = "    double DailyCapacityBbl)`n{`n    public string Region => `"Americas`";`n}" }
           @{ File = $spec; Find = "    Well:`n      type: object`n"; Replace = "    Well:`n      type: object`n      additionalProperties: true`n" }) }
)

foreach ($e in $experiments | Select-Object -Skip ($From - 1)) {
    $started = Get-Date
    & "$PSScriptRoot\break-experiment.ps1" -Name $e.Name -Out "case1\break\$($e.Out)" -Changes $e.Changes -Expected $e.Expected
    Write-Host ("  ({0} took {1:n1} min)" -f $e.Out, ((Get-Date) - $started).TotalMinutes)
}

# Summary table
$rows = foreach ($e in $experiments) {
    $r = Get-Content (Join-Path $ResultsDir "case1\break\$($e.Out)\experiment.json") -Raw | ConvertFrom-Json
    $spec = if (-not $r.compiled) { 'n/a (did not compile)' } elseif ($r.specmaticCaught) { "**YES** ($($r.specmaticFailures)/$($r.specmaticTests) failed)" } else { "no ($($r.specmaticTests) passed)" }
    $xu   = if (-not $r.compiled) { 'n/a' } elseif ($r.xunitFailed) { '**YES**' } else { 'no' }
    "| $($r.name) | $($r.expected) | $spec | $xu | [results/case1/break/$($e.Out)/](results/case1/break/$($e.Out)/) |"
}
$md = @('| Change | Expected | Specmatic caught? | xUnit caught? | Evidence |', '|---|---|---|---|---|') + $rows
$md | Set-Content -Encoding utf8 (Join-Path $ResultsDir 'case1\break\summary.md')
$md
