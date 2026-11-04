<#
    gpu-monitor.ps1 - sample GPU telemetry while a stress test runs.

    Records temperature, power, clocks, utilisation and NVIDIA's own throttle
    reasons, plus Windows GPU engine counters and any new kernel fault reports.
    Writes a CSV and prints a summary that says whether the GPU throttled,
    hung, or stayed healthy.

    Usage:  .\gpu-monitor.ps1                # 5 minutes, 2s interval
            .\gpu-monitor.ps1 -Minutes 10
            .\gpu-monitor.ps1 -Minutes 2 -IntervalSec 1
#>

[CmdletBinding()]
param(
    [int]$Minutes = 5,
    [int]$IntervalSec = 2
)

$smi = 'C:\Windows\System32\nvidia-smi.exe'
if (-not (Test-Path $smi)) { Write-Warning 'nvidia-smi.exe not found.'; return }

$csv = Join-Path $PSScriptRoot ('gpu-log-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')

function Get-KernelReportCount {
    $n = 0
    foreach ($root in @("$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
                        "$env:ProgramData\Microsoft\Windows\WER\ReportArchive")) {
        if (Test-Path $root) {
            $n += @(Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like 'Kernel_*' }).Count
        }
    }
    return $n
}

$startReports = Get-KernelReportCount
$startTdr = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=4101} -MaxEvents 200 -ErrorAction SilentlyContinue).Count

Write-Host ''
Write-Host ("Monitoring for {0} min (interval {1}s)" -f $Minutes, $IntervalSec) -ForegroundColor Cyan
Write-Host ("Log: {0}" -f $csv) -ForegroundColor DarkGray
Write-Host ("Kernel reports at start: {0}   TDR events: {1}" -f $startReports, $startTdr) -ForegroundColor DarkGray
Write-Host ''
Write-Host '   time     temp   power    SM MHz   GPU%   mem%   throttle' -ForegroundColor Cyan
Write-Host '   -------- -----  -------  -------  -----  -----  --------------------'

# Ask for each event reason by name - decoding the raw bitmask is unreliable
# because newer drivers add bits (board_limit, reliability) beyond the classic set.
$reasonFields = @(
    'clocks_throttle_reasons.sw_power_cap',
    'clocks_throttle_reasons.hw_slowdown',
    'clocks_throttle_reasons.hw_thermal_slowdown',
    'clocks_throttle_reasons.hw_power_brake_slowdown',
    'clocks_throttle_reasons.sw_thermal_slowdown',
    'clocks_throttle_reasons.sync_boost',
    'clocks_throttle_reasons.board_limit',
    'clocks_throttle_reasons.reliability'
)
$reasonLabels = @('SwPowerCap','HW_SLOWDOWN','HW_THERMAL','HW_POWER_BRAKE',
                  'SwThermal','SyncBoost','BoardLimit','Reliability')
# Drop any reason this driver does not support, so the query never fails.
$probe = & $smi --query-gpu=($reasonFields -join ',') --format=csv,noheader 2>&1
if ($LASTEXITCODE -ne 0) {
    $keep = @(); $keepL = @()
    for ($i = 0; $i -lt $reasonFields.Count; $i++) {
        $t = & $smi --query-gpu=$($reasonFields[$i]) --format=csv,noheader 2>&1
        if ($LASTEXITCODE -eq 0) { $keep += $reasonFields[$i]; $keepL += $reasonLabels[$i] }
    }
    $reasonFields = $keep; $reasonLabels = $keepL
}

$fields = 'temperature.gpu,power.draw,clocks.sm,utilization.gpu,utilization.memory,memory.used,clocks_throttle_reasons.active'
if ($reasonFields.Count) { $fields = $fields + ',' + ($reasonFields -join ',') }
$rows = @()
$deadline = (Get-Date).AddMinutes($Minutes)
$maxTemp = 0; $maxPower = 0; $minClock = [int]::MaxValue; $maxClock = 0
$throttleHits = 0

while ((Get-Date) -lt $deadline) {
    $raw = & $smi --query-gpu=$fields --format=csv,noheader,nounits 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { Start-Sleep -Seconds $IntervalSec; continue }

    $p = ($raw -split ',') | ForEach-Object { $_.Trim() }
    $temp = [double]$p[0]; $pw = [double]$p[1]; $clk = [int]$p[2]
    $gu = [int]$p[3]; $mu = [int]$p[4]; $mem = [int]$p[5]; $thr = $p[6]

    if ($temp -gt $maxTemp)  { $maxTemp = $temp }
    if ($pw   -gt $maxPower) { $maxPower = $pw }
    if ($clk  -gt $maxClock) { $maxClock = $clk }
    if ($clk  -lt $minClock -and $gu -gt 30) { $minClock = $clk }

    # Named reasons start at index 7; each is "Active" / "Not Active".
    $names = @()
    for ($i = 0; $i -lt $reasonLabels.Count; $i++) {
        if ($p[7 + $i] -eq 'Active') { $names += $reasonLabels[$i] }
    }
    if ($names.Count) {
        $thrShort = ($names -join ',')
        $throttleHits++
    } elseif ($thr -eq '0x0000000000000001') {
        $thrShort = 'GpuIdle'          # idling at low clocks is normal, not a fault
    } elseif ($thr -and $thr -ne '0x0000000000000000') {
        $thrShort = $thr               # unrecognised bit - report it raw
    } else {
        $thrShort = 'none'
    }

    $now = Get-Date
    $rows += [pscustomobject]@{
        Time = $now.ToString('HH:mm:ss'); TempC = $temp; PowerW = $pw
        ClockMHz = $clk; GpuPct = $gu; MemPct = $mu; MemUsedMB = $mem; Throttle = $thrShort
    }

    $col = 'Gray'
    if ($temp -ge 87 -or $thrShort -match 'THERMAL|BRAKE|SLOWDOWN') { $col = 'Red' }
    elseif ($temp -ge 80 -or $thrShort -ne 'none') { $col = 'Yellow' }
    Write-Host ("   {0}  {1,4}C  {2,6}W  {3,7}  {4,4}%  {5,4}%  {6}" -f `
        $now.ToString('HH:mm:ss'), $temp, $pw, $clk, $gu, $mu, $thrShort) -ForegroundColor $col

    Start-Sleep -Seconds $IntervalSec
}

$rows | Export-Csv -Path $csv -NoTypeInformation -Encoding utf8

$endReports = Get-KernelReportCount
$endTdr = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=4101} -MaxEvents 200 -ErrorAction SilentlyContinue).Count
if ($minClock -eq [int]::MaxValue) { $minClock = 0 }

Write-Host ''
Write-Host '  ================ SUMMARY ================' -ForegroundColor Cyan
Write-Host ("  samples          : {0}" -f $rows.Count)
Write-Host ("  peak temperature : {0} C" -f $maxTemp)
Write-Host ("  peak power       : {0} W" -f $maxPower)
Write-Host ("  SM clock range   : {0} - {1} MHz (under load)" -f $minClock, $maxClock)
Write-Host ("  throttled samples: {0}" -f $throttleHits)
Write-Host ("  new TDR events   : {0}" -f ($endTdr - $startTdr))
Write-Host ("  new kernel faults: {0}" -f ($endReports - $startReports))
Write-Host ''

if (($endReports - $startReports) -gt 0) {
    Write-Host '  >> NEW KERNEL FAULTS during the run - the stress reproduced it.' -ForegroundColor Red
    Write-Host '     Run crash-count.ps1 to see which bugcheck.' -ForegroundColor Red
} elseif ($maxTemp -ge 87 -or $throttleHits -gt ($rows.Count * 0.2)) {
    Write-Host '  >> Thermal or power throttling is significant.' -ForegroundColor Yellow
} else {
    Write-Host '  >> GPU stayed healthy through this run.' -ForegroundColor Green
}
Write-Host ("  CSV: {0}" -f $csv) -ForegroundColor DarkGray
Write-Host ''
