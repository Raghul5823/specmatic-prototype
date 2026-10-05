# Helpers for scripts\run-evidence.ps1: result parsers, sanitising, clean-up. Windows PowerShell 5.1 compatible.
Set-StrictMode -Off

# ------------------------------------------------------------------ sanitising
# Everything that goes into the report passes through Protect-Text, so no local path, user or host name
# ends up in a file that may be committed (evidence/sample) or shared.
$script:Replacements = New-Object System.Collections.Generic.List[object]

function Set-EvidenceSanitizer {
    param([hashtable]$Paths)   # @{ 'C:\path' = '.' ; ... }
    $script:Replacements.Clear()
    $pairs = @()
    foreach ($k in $Paths.Keys) { if ($k) { $pairs += , @($k, $Paths[$k]) } }
    $tempLong = (Get-Item $env:TEMP).FullName
    $pairs += , @($tempLong, '<temp>')
    $pairs += , @($env:TEMP, '<temp>')
    $pairs += , @($env:USERPROFILE, '<home>')
    # Longest first, so a repo path wins over the home folder that contains it; also the forward-slash forms.
    $sorted = $pairs | Sort-Object -Property @{ Expression = { $_[0].Length } } -Descending
    foreach ($p in $sorted) {
        Add-Replacement ([regex]::Escape([string]$p[0])) ([string]$p[1])
        Add-Replacement ([regex]::Escape(([string]$p[0] -replace '\\', '/'))) ([string]$p[1])
    }
    if ($env:USERDOMAIN -and $env:USERNAME) { Add-Replacement ([regex]::Escape("$env:USERDOMAIN\$env:USERNAME")) '<user>' }
    if ($env:USERNAME) { Add-Replacement ('\b' + [regex]::Escape($env:USERNAME) + '\b') '<user>' }
    if ($env:COMPUTERNAME) { Add-Replacement ('\b' + [regex]::Escape($env:COMPUTERNAME) + '\b') '<host>' }
}

function Add-Replacement([string]$Pattern, [string]$With) {
    $rx = New-Object System.Text.RegularExpressions.Regex($Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $script:Replacements.Add([pscustomobject]@{ Regex = $rx; With = $With })
}

function Protect-Text {
    param([AllowNull()] [string]$Text, [int]$Max = 0)
    if ($null -eq $Text) { return $null }
    $t = $Text
    foreach ($r in $script:Replacements) { $t = $r.Regex.Replace($t, $r.With.Replace('$', '$$')) }
    if ($Max -gt 0 -and $t.Length -gt $Max) { $t = $t.Substring(0, $Max) + "`n... (truncated)" }
    return $t
}

function Save-ProtectedLog {
    param([object[]]$Lines, [string]$Path)
    New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
    $text = ($Lines | ForEach-Object { "$_" }) -join "`r`n"
    [IO.File]::WriteAllText($Path, (Protect-Text $text), (New-Object Text.UTF8Encoding $false))
}

# ------------------------------------------------------------------ parsers
function Get-ExampleOwner {
    # Specmatic test names carry the example name: ... with the request from the example 'production-forecast__get_well_W-001_active'
    param([string]$TestName)
    $m = [regex]::Match($TestName, "example '([^']+)'")
    if (-not $m.Success) { return 'generated' }
    $ex = $m.Groups[1].Value
    if ($ex -match '^(.+?)__') { if ($Matches[1] -eq 'provider') { return 'provider (own example)' } else { return $Matches[1] } }
    return 'provider (inline example)'
}

function ConvertTo-ShortTestName {
    param([string]$Name)
    $n = $Name -replace '^Contract Tests > SpecmaticJUnitSupport > contractTest\(\) > ', ''
    $n = $n -replace '^Scenario: ', ''
    return $n
}

function Read-JUnit {
    # Specmatic writes <testsuite> as the root; Playwright writes <testsuites><testsuite>...
    param([string[]]$Paths, [switch]$Owners)
    $cases = @()   # plain array: @() around a generic List of dictionaries throws in PowerShell 5.1
    foreach ($p in $Paths) {
        if (-not (Test-Path $p)) { continue }
        $xml = New-Object Xml.XmlDocument
        $xml.Load($p)
        foreach ($tc in $xml.SelectNodes('//testcase')) {
            $fail = $tc.SelectSingleNode('failure'); if (-not $fail) { $fail = $tc.SelectSingleNode('error') }
            $skip = $tc.SelectSingleNode('skipped')
            $status = if ($fail) { 'FAIL' } elseif ($skip) { 'SKIPPED' } else { 'PASS' }
            $msg = $null
            if ($fail) {
                # Specmatic puts the full explanation in the message attribute; Playwright puts a short
                # message there and the details (expected/received, call log) in the element text.
                $attr = $fail.GetAttribute('message'); $body = "$($fail.InnerText)".Trim()
                $msg = if (-not $attr) { $body } elseif (-not $body -or $body.StartsWith($attr)) { $attr } else { "$attr`n$body" }
            }
            $name = $tc.GetAttribute('name')
            # Specmatic sometimes writes a negative time; treat anything unparsable or negative as unknown.
            $tm = 0.0
            $ok = [double]::TryParse($tc.GetAttribute('time'), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$tm)
            $case = [ordered]@{
                name    = Protect-Text (ConvertTo-ShortTestName $name) 400
                status  = $status
                seconds = $(if ($ok -and $tm -ge 0) { [math]::Round($tm, 2) } else { $null })
                message = Protect-Text $msg 3000
            }
            if ($Owners) { $case['owner'] = Get-ExampleOwner $name }
            $cases += , $case
        }
    }
    return (New-TestSummary $cases)
}

function Read-Trx {
    param([string[]]$Paths)
    $cases = @()
    foreach ($p in $Paths) {
        if (-not (Test-Path $p)) { continue }
        $xml = New-Object Xml.XmlDocument
        $xml.Load($p)
        $ns = New-Object Xml.XmlNamespaceManager $xml.NameTable
        $ns.AddNamespace('t', 'http://microsoft.com/schemas/VisualStudio/TeamTest/2010')
        foreach ($r in $xml.SelectNodes('//t:UnitTestResult', $ns)) {
            $outcome = $r.GetAttribute('outcome')
            $status = switch ($outcome) { 'Passed' { 'PASS' } 'Failed' { 'FAIL' } default { 'SKIPPED' } }
            $msgNode = $r.SelectSingleNode('t:Output/t:ErrorInfo/t:Message', $ns)
            $dur = [TimeSpan]::Zero; [void][TimeSpan]::TryParse($r.GetAttribute('duration'), [ref]$dur)
            $cases += , ([ordered]@{
                name    = Protect-Text ($r.GetAttribute('testName') -replace '^[A-Za-z]+\.(Tests|ContractTests)\.', '') 400
                status  = $status
                seconds = [math]::Round($dur.TotalSeconds, 2)
                message = $(if ($msgNode) { Protect-Text $msgNode.InnerText 3000 } else { $null })
            })
        }
    }
    return (New-TestSummary $cases)
}

function New-TestSummary {
    param([object[]]$Cases = @())
    $list = $Cases
    return [ordered]@{
        total     = $list.Count
        passed    = @($list | Where-Object { $_.status -eq 'PASS' }).Count
        failed    = @($list | Where-Object { $_.status -eq 'FAIL' }).Count
        skipped   = @($list | Where-Object { $_.status -eq 'SKIPPED' }).Count
        testcases = $list
    }
}

function Get-OwnerBreakdown {
    # Per example owner (consumer): how many of "their" tests passed in a provider run.
    param($TestSummary)
    $rows = @()
    foreach ($g in ($TestSummary.testcases | Group-Object { $_.owner } | Sort-Object Name)) {
        $rows += [ordered]@{ owner = $g.Name; total = $g.Count; passed = @($g.Group | Where-Object { $_.status -eq 'PASS' }).Count }
    }
    return , $rows
}

function Read-SpecmaticCoverage {
    # Parses Specmatic's "API COVERAGE SUMMARY" table from console output (the free edition has no coverage JSON).
    param([string]$ConsoleFile, [string]$Service)
    if (-not (Test-Path $ConsoleFile)) { return $null }
    $lines = Get-Content $ConsoleFile
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match 'SPECMATIC API COVERAGE SUMMARY') { $start = $i } }
    if ($start -lt 0) { return $null }
    $rows = @(); $path = ''; $method = ''; $cov = ''
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        $l = $lines[$i].Trim()
        if (-not $l.StartsWith('|')) { break }
        if ($l -match '^\|\s*(coverage\s*\||-{3})' -or $l -match '^\|-') { continue }
        if ($l -match '^\|\s*[\*!pfw] =' -or $l -match 'API Coverage reported|Absolute Coverage|^\|\s*\|$') { continue }
        $cells = $l.Trim('|').Split('|') | ForEach-Object { $_.Trim() }
        if ($cells.Count -lt 8) { continue }
        if ($cells[0]) { $cov = $cells[0] }
        if ($cells[1]) { $path = $cells[1] }
        if ($cells[2]) { $method = $cells[2] }
        $rows += [ordered]@{ coverage = $cov; path = $path; method = $method; response = $cells[4]; remarks = $cells[6]; result = $cells[7] }
    }
    $text = $lines -join "`n"
    $m = [regex]::Match($text, '(\d+)% API Coverage reported from (\d+) operations')
    return [ordered]@{
        service    = $Service
        pct        = if ($m.Success) { [int]$m.Groups[1].Value } else { $null }
        operations = if ($m.Success) { [int]$m.Groups[2].Value } else { $null }
        rows       = $rows
    }
}

# ------------------------------------------------------------------ machine state
$script:OurPorts = 5101, 5102, 5201, 5202, 9101, 9102, 9201, 9202, 4200

function Get-BusyPorts {
    $busy = @()
    foreach ($port in $script:OurPorts) {
        foreach ($c in @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) {
            $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
            $busy += [ordered]@{ port = $port; process = if ($p) { $p.ProcessName } else { "pid $($c.OwningProcess)" }; pid = $c.OwningProcess }
        }
    }
    return , $busy
}

function Stop-EvidenceProcesses {
    # Stops what the evidence run (or an earlier, interrupted run) may have left: services, mock/stub
    # containers (our names only: stub-*, deps-*, ct-deps-*), and dotnet/node processes on our ports.
    param([string]$Root)
    & (Join-Path $Root 'scripts\stop-services.ps1') *> $null
    $names = @(docker ps -a --format '{{.Names}}' 2>$null | Where-Object { $_ -match '^(stub-|deps-|ct-deps-)' })
    foreach ($n in $names) { docker container rm --force $n 2>&1 | Out-Null }
    foreach ($b in (Get-BusyPorts)) {
        if ($b.process -in 'dotnet', 'node') { Stop-Process -Id $b.pid -Force -ErrorAction SilentlyContinue }
    }
    return $names
}

function Get-GitState {
    param([string]$Dir)
    $state = [ordered]@{ commit = $null; branch = $null; describe = $null; exactTag = $null; lastTag = $null; aheadOfTag = $null; dirty = $null; changes = @() }
    if (-not (Test-Path (Join-Path $Dir '.git'))) { return $state }
    $state.commit   = (git -C $Dir rev-parse --short HEAD 2>$null)
    $state.branch   = (git -C $Dir rev-parse --abbrev-ref HEAD 2>$null)
    $state.describe = (git -C $Dir describe --tags --always 2>$null)
    $state.exactTag = (git -C $Dir describe --tags --exact-match 2>$null)
    $state.lastTag  = (git -C $Dir describe --tags --abbrev=0 2>$null)
    if ($state.lastTag) { $state.aheadOfTag = [int](git -C $Dir rev-list --count "$($state.lastTag)..HEAD" 2>$null) }
    $state.changes  = @(git -C $Dir status --porcelain 2>$null)
    $state.dirty    = ($state.changes.Count -gt 0)
    $state.fingerprint = Get-TreeFingerprint $Dir
    return $state
}

function Get-TreeFingerprint {
    # Content fingerprint of the working tree's uncommitted state: `git status` alone only shows WHICH files
    # differ, so a run that changed an already-modified file would go unnoticed. Ignored files are excluded.
    param([string]$Dir)
    $diff = (git -C $Dir diff HEAD --binary 2>$null) -join "`n"
    $untracked = @(git -C $Dir ls-files --others --exclude-standard 2>$null | ForEach-Object { "$_ $(git -C $Dir hash-object -- "$_" 2>$null)" })
    $bytes = [Text.Encoding]::UTF8.GetBytes($diff + "`n--untracked--`n" + ($untracked -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').Substring(0, 16) } finally { $sha.Dispose() }
}

function Remove-TempCopy {
    # SAFETY: the copy's node_modules is a junction to the real one. Windows PowerShell 5.1's
    # Remove-Item -Recurse can follow a junction and delete the TARGET's files, so junctions are removed
    # first with rmdir (removes the link only), then the tree with cmd's rmdir /s, which never follows them.
    param([string]$Path, [string[]]$Junctions = @())
    foreach ($j in $Junctions) { if ($j -and (Test-Path $j)) { cmd /c rmdir "$j" 2>&1 | Out-Null } }
    foreach ($j in $Junctions) { if ($j -and (Test-Path $j)) { throw "Junction $j could not be removed; refusing to delete $Path." } }
    if ($Path -and (Test-Path $Path)) {
        # git marks pack files read-only (Phase 7 finding); clear the flag so the delete cannot fail on them.
        Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
        cmd /c rmdir /s /q "$Path" 2>&1 | Out-Null
    }
    return -not (Test-Path $Path)
}

function Save-Json {
    param($Object, [string]$Path, [int]$Depth = 30)
    New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
    $json = ConvertTo-Json -InputObject $Object -Depth $Depth
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
}

Export-ModuleMember -Function *
