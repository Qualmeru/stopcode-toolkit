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
    '19'  = 'BAD_POOL_HEADER'
    '1a'  = 'MEMORY_MANAGEMENT'
    '1e'  = 'KMODE_EXCEPTION_NOT_HANDLED'
    '50'  = 'PAGE_FAULT_IN_NONPAGED_AREA'
    '7e'  = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED'
    '7f'  = 'UNEXPECTED_KERNEL_MODE_TRAP'
    '9c'  = 'MACHINE_CHECK_EXCEPTION'
    '9f'  = 'DRIVER_POWER_STATE_FAILURE'
    'a0'  = 'INTERNAL_POWER_ERROR'
    'be'  = 'ATTEMPTED_WRITE_TO_READONLY_MEMORY'
    'c2'  = 'BAD_POOL_CALLER'
    'c5'  = 'DRIVER_CORRUPTED_EXPOOL'
    'd1'  = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL'
    'd5'  = 'DRIVER_PAGE_FAULT_IN_FREED_SPECIAL_POOL'
    'e6'  = 'DRIVER_VERIFIER_DMA_VIOLATION'
    'ea'  = 'THREAD_STUCK_IN_DEVICE_DRIVER'
    'ef'  = 'CRITICAL_PROCESS_DIED'
    'fc'  = 'ATTEMPTED_EXECUTE_OF_NOEXECUTE_MEMORY'
    '101' = 'CLOCK_WATCHDOG_TIMEOUT'
    '116' = 'VIDEO_TDR_FAILURE'
    '117' = 'VIDEO_TDR_TIMEOUT_DETECTED'
    '119' = 'VIDEO_SCHEDULER_INTERNAL_ERROR'
    '124' = 'WHEA_UNCORRECTABLE_ERROR'
    '133' = 'DPC_WATCHDOG_VIOLATION'
    '139' = 'KERNEL_SECURITY_CHECK_FAILURE'
    '13a' = 'KERNEL_MODE_HEAP_CORRUPTION'
    '144' = 'BUGCODE_USB3_DRIVER'
    '154' = 'UNEXPECTED_STORE_EXCEPTION'
    '15f' = 'CONNECTED_STANDBY_WATCHDOG_TIMEOUT_LIVEDUMP'
    '161' = 'LIVE_SYSTEM_DUMP'
    '190' = 'WIN32K_CRITICAL_FAILURE_LIVEDUMP'
    '1c8' = 'MANUALLY_INITIATED_POWER_BUTTON_HOLD'
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
