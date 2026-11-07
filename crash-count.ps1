<#
    crash-count.ps1 - report kernel faults that are new since a saved baseline.

    Counts report IDENTITIES, not totals.

    The previous version stored a count per bugcheck and subtracted. That is
    wrong, because Windows Error Reporting purges old report folders as new
    ones arrive: three fresh 0x141 faults landed while the total stayed at 37,
    and the tool reported "no new faults". A measurement that can show success
    while the thing it measures is still happening is worse than no tool at
    all, so this records which reports it has seen.

    Each WER folder name ends in a GUID unique to that occurrence, so the set
    of names is a reliable identity even when the folder is later deleted.

    Usage:  .\crash-count.ps1            compare against the baseline
            .\crash-count.ps1 -Reset     take the current set as the baseline
            .\crash-count.ps1 -Detail    also list each new occurrence with its time
#>

[CmdletBinding()]
param([switch]$Reset, [switch]$Detail)

$baselineFile = Join-Path $PSScriptRoot 'crash-baseline.json'
$reportDir    = Join-Path $PSScriptRoot 'diag\reports'

$names = @{
    '141' = 'VIDEO_ENGINE_TIMEOUT (GPU hang / stutter)'
    '193' = 'VIDEO_DXGKRNL_LIVEDUMP'
    'a'   = 'IRQL_NOT_LESS_OR_EQUAL (BSOD)'
    'c4'  = 'DRIVER_VERIFIER_DETECTED_VIOLATION'
    'c1'  = 'SPECIAL_POOL_CORRUPTION'
    'c9'  = 'VERIFIER_IOMANAGER_VIOLATION'
    'd6'  = 'PAGE_FAULT_BEYOND_END_OF_ALLOCATION'
    'd5'  = 'DRIVER_PAGE_FAULT_IN_FREED_SPECIAL_POOL'
    '3b'  = 'SYSTEM_SERVICE_EXCEPTION'
    '18'  = 'REFERENCE_BY_POINTER'
    '1e'  = 'KMODE_EXCEPTION_NOT_HANDLED'
    '50'  = 'PAGE_FAULT_IN_NONPAGED_AREA'
}

function Get-ReportFolders {
    $out = @()
    foreach ($root in @("$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
                        "$env:ProgramData\Microsoft\Windows\WER\ReportArchive")) {
        if (-not (Test-Path $root)) { continue }
        $out += @(Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like 'Kernel_*' } |
                  Select-Object -ExpandProperty Name)
    }
    return @($out | Select-Object -Unique)
}

function Get-Code {
    param([string]$FolderName)
    if ($FolderName -match '^Kernel_([0-9a-fA-F]+)_') { return $matches[1].ToLower() }
    return 'unknown'
}

# The watcher writes one report file per occurrence and keeps it after WER has
# purged the folder, so it sees faults this script would otherwise lose. Used
# as a cross-check rather than the primary source.
function Get-WatcherOccurrences {
    $out = @()
    if (-not (Test-Path $reportDir)) { return $out }
    foreach ($f in (Get-ChildItem (Join-Path $reportDir 'live-*.txt') -ErrorAction SilentlyContinue)) {
        $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        $code = ''; $when = $null
        if ($c -match 'LIVE KERNEL EVENT\s+-\s+0x([0-9A-Fa-f]+)') { $code = $matches[1].ToLower() }
        if ($c -match 'occurred\s+:\s+([\d]{4}-[\d]{2}-[\d]{2} [\d:]{8})') { $when = [datetime]$matches[1] }
        if ($code -and $when) { $out += [pscustomobject]@{ Code = $code; When = $when } }
    }
    return $out
}

$currentSet = @(Get-ReportFolders)

if ($Reset -or -not (Test-Path $baselineFile)) {
    $state = [pscustomobject]@{
        Taken   = (Get-Date).ToString('s')
        Seen    = $currentSet
        LastRun = (Get-Date).ToString('s')
    }
    $state | ConvertTo-Json -Depth 4 | Set-Content $baselineFile -Encoding utf8

    $byCode = @{}
    foreach ($n in $currentSet) { $k = Get-Code $n; if ($byCode.ContainsKey($k)) { $byCode[$k]++ } else { $byCode[$k] = 1 } }
    Write-Host ''
    Write-Host ('  Baseline taken - {0} report(s) recorded as already seen' -f $currentSet.Count) -ForegroundColor Cyan
    foreach ($k in ($byCode.Keys | Sort-Object)) {
        $d = $names[$k]; if (-not $d) { $d = 'unknown' }
        Write-Host ('    0x{0,-5} {1,4}   {2}' -f $k, $byCode[$k], $d)
    }
    Write-Host ''
    Write-Host '  Anything that appears from now on counts as new, even if WER' -ForegroundColor DarkGray
    Write-Host '  deletes an old report to make room for it.' -ForegroundColor DarkGray
    Write-Host ''
    return
}

# --- load the baseline, tolerating the old count-based format ---------------
$raw = Get-Content $baselineFile -Raw | ConvertFrom-Json
$seen = @()
$takenAt = $null
if ($raw.PSObject.Properties.Name -contains 'Seen') {
    $seen = @($raw.Seen)
    if ($raw.Taken) { $takenAt = [datetime]$raw.Taken }
} else {
    # Without a recorded set there is nothing to compare against, and carrying
    # on would mark every existing report as new.
    Write-Host ''
    Write-Host '  The saved baseline is in the old count-only format, which could not' -ForegroundColor Yellow
    Write-Host '  detect faults that WER had purged - it reported "no new faults" while' -ForegroundColor Yellow
    Write-Host '  three were recorded by the watcher.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Re-run with -Reset to start a reliable baseline.' -ForegroundColor Cyan
    Write-Host ''
    return
}

$newOnes = @($currentSet | Where-Object { $seen -notcontains $_ })

Write-Host ''
if ($takenAt) {
    Write-Host ('  Baseline taken {0}  ({1:N1} days ago)' -f $takenAt.ToString('yyyy-MM-dd HH:mm'), ((Get-Date) - $takenAt).TotalDays) -ForegroundColor DarkGray
}

# --- cross-check against the watcher's own record ---------------------------
$watcherNew = @()
if ($takenAt) {
    $watcherNew = @(Get-WatcherOccurrences | Where-Object { $_.When -ge $takenAt } | Sort-Object When)
}

if (-not $newOnes -and -not $watcherNew) {
    Write-Host '  No new kernel faults since the baseline.' -ForegroundColor Green
    Write-Host ''
    return
}

# Report per bugcheck, preferring the watcher count where it is higher: it
# retains occurrences whose WER folder has since been deleted.
$codes = @{}
foreach ($n in $newOnes)   { $k = Get-Code $n;  if ($codes.ContainsKey($k)) { $codes[$k]++ } else { $codes[$k] = 1 } }
$wCodes = @{}
foreach ($w in $watcherNew) { if ($wCodes.ContainsKey($w.Code)) { $wCodes[$w.Code]++ } else { $wCodes[$w.Code] = 1 } }

Write-Host ''
Write-Host ('  {0,-8} {1,6} {2,8}   {3}' -f 'Bugcheck','NEW','watcher','meaning') -ForegroundColor Cyan
Write-Host ('  ' + ('-' * 74))
foreach ($k in (($codes.Keys + $wCodes.Keys) | Sort-Object -Unique)) {
    $a = 0; if ($codes.ContainsKey($k))  { $a = $codes[$k] }
    $b = 0; if ($wCodes.ContainsKey($k)) { $b = $wCodes[$k] }
    $d = $names[$k]; if (-not $d) { $d = 'unknown' }
    Write-Host ('  0x{0,-6} {1,6} {2,8}   {3}' -f $k, $a, $b, $d) -ForegroundColor Yellow
}

if ($watcherNew) {
    Write-Host ''
    Write-Host '  When they happened (from the watcher, which keeps purged reports):' -ForegroundColor Cyan
    foreach ($w in $watcherNew) {
        Write-Host ('    {0}   0x{1}' -f $w.When.ToString('yyyy-MM-dd HH:mm:ss'), $w.Code)
    }
}

if ($Detail -and $newOnes) {
    Write-Host ''
    Write-Host '  New report folders:' -ForegroundColor DarkGray
    foreach ($n in $newOnes) { Write-Host ('    ' + $n) -ForegroundColor DarkGray }
}

Write-Host ''
$fatal = @($codes.Keys + $wCodes.Keys | Where-Object { $_ -in @('a','c4','c1','c9','d6','d5','3b','1e','50') })
if ($fatal) {
    Write-Host '  A bugcheck code moved - run "ANALYZE CRASH.cmd" to name the driver.' -ForegroundColor Red
} else {
    Write-Host '  All non-fatal live kernel events; the system recovered each time.' -ForegroundColor DarkGray
}
Write-Host ''
