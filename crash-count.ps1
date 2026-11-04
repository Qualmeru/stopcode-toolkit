<#
    crash-count.ps1 - count kernel error reports and diff against a saved baseline.

    First run saves a baseline. Later runs show what is NEW since then, so you
    can tell whether an activity (playing video, a game) actually triggers
    GPU engine timeouts or crashes.

    Usage:  .\crash-count.ps1            # compare to baseline (saves one if absent)
            .\crash-count.ps1 -Reset     # overwrite the baseline with current counts
#>

[CmdletBinding()]
param([switch]$Reset)

$baselineFile = Join-Path $PSScriptRoot 'crash-baseline.json'

$names = @{
    '141' = 'VIDEO_ENGINE_TIMEOUT (GPU hang / stutter)'
    '193' = 'VIDEO_DXGKRNL_LIVEDUMP'
    'a'   = 'IRQL_NOT_LESS_OR_EQUAL (BSOD)'
    'c4'  = 'DRIVER_VERIFIER_DETECTED_VIOLATION'
    'c1'  = 'SPECIAL_POOL_CORRUPTION'
    'c9'  = 'VERIFIER_IOMANAGER_VIOLATION'
    'd6'  = 'PAGE_FAULT_BEYOND_END_OF_ALLOCATION'
    '3b'  = 'SYSTEM_SERVICE_EXCEPTION'
    '18'  = 'REFERENCE_BY_POINTER'
}

$current = @{}
foreach ($root in @("$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
                    "$env:ProgramData\Microsoft\Windows\WER\ReportArchive")) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'Kernel_*' } |
        ForEach-Object {
            if ($_.Name -match '^Kernel_([0-9a-fA-F]+)_') {
                $k = $matches[1].ToLower()
                if ($current.ContainsKey($k)) { $current[$k]++ } else { $current[$k] = 1 }
            }
        }
}

if ($Reset -or -not (Test-Path $baselineFile)) {
    $current | ConvertTo-Json | Set-Content $baselineFile -Encoding utf8
    Write-Host 'Baseline saved:' -ForegroundColor Cyan
    foreach ($k in ($current.Keys | Sort-Object)) {
        Write-Host ("  0x{0,-5} {1,4}   {2}" -f $k, $current[$k], $names[$k])
    }
    Write-Host ''
    Write-Host 'Now go exercise the machine, then run this again.' -ForegroundColor DarkGray
    return
}

$base = @{}
(Get-Content $baselineFile -Raw | ConvertFrom-Json).PSObject.Properties |
    ForEach-Object { $base[$_.Name] = [int]$_.Value }

Write-Host ''
Write-Host ("  {0,-8} {1,7} {2,7} {3,6}   {4}" -f 'Bugcheck','before','now','NEW','meaning') -ForegroundColor Cyan
Write-Host ('  ' + ('-' * 74))

$any = $false
foreach ($k in (($current.Keys + $base.Keys) | Sort-Object -Unique)) {
    $b = 0; if ($base.ContainsKey($k))    { $b = $base[$k] }
    $c = 0; if ($current.ContainsKey($k)) { $c = $current[$k] }
    $delta = $c - $b
    $desc = $names[$k]; if (-not $desc) { $desc = 'unknown' }
    if ($delta -gt 0) { $col = 'Yellow'; $any = $true } else { $col = 'Gray' }
    Write-Host ("  0x{0,-6} {1,7} {2,7} {3,6}   {4}" -f $k, $b, $c, $delta, $desc) -ForegroundColor $col
}

Write-Host ''
if ($any) {
    Write-Host 'NEW kernel faults since baseline - that activity reproduced it.' -ForegroundColor Yellow
    Write-Host 'Run "ANALYZE CRASH.cmd" if any BSOD codes moved.' -ForegroundColor Yellow
} else {
    Write-Host 'No new kernel faults since baseline.' -ForegroundColor Green
}
Write-Host ''
