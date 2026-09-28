<#
.SYNOPSIS
  Stops services started by start-services.ps1 (by recorded PID, then by port as a fallback).
#>
param([string[]]$Only)
. "$PSScriptRoot\common.ps1"

$pids = @{}
if (Test-Path $PidFile) {
    (Get-Content $PidFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $pids[$_.Name] = $_.Value }
}

$targets = if ($Only) { $Only | ForEach-Object { Get-ProtoService $_ } } else { $Services }
foreach ($s in $targets) {
    $ids = @()
    if ($pids.ContainsKey($s.Name)) { $ids += $pids[$s.Name] }
    $ids += Get-NetTCPConnection -LocalPort $s.Port -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess
    foreach ($id in ($ids | Sort-Object -Unique)) {
        $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -eq 'dotnet') {
            Stop-Process -Id $id -Force -Confirm:$false
            Write-Host "  STOP  $($s.Name) (pid $id)"
        }
    }
    $pids.Remove($s.Name)
}

if ($pids.Count -gt 0) { $pids | ConvertTo-Json | Set-Content -Encoding utf8 $PidFile }
elseif (Test-Path $PidFile) { Remove-Item $PidFile }
