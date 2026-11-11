<#
    watch-dumps.ps1 - background watcher for new kernel crash dumps.

    Sits in the tray. When a new .dmp appears in C:\Windows\Minidump it parses
    it, writes a plain-text report, and raises a notification. Click the
    notification to open the report.

    A minidump is normally written during the boot AFTER a bugcheck (the crash
    data goes to the pagefile first, then Session Manager converts it), so the
    watcher also scans once at startup to catch anything that landed while it
    was not running.

    The dump parser is inline - no Python, because python3.exe here is a Store
    app-execution alias that does not resolve inside an elevated task.

    Usage:
        .\watch-dumps.ps1 -Install      register to start at logon (elevated)
        .\watch-dumps.ps1 -Uninstall    remove the scheduled task
        .\watch-dumps.ps1 -Once         scan now, report, exit
        .\watch-dumps.ps1               run the watcher in the foreground

    By default only a fatal bugcheck - a real minidump - raises a notification.
    Live kernel events (0x141 engine timeouts, 0x193 dxgkrnl livedumps) are
    non-fatal, recover on their own, and can fire often, so they are written
    to diag\reports and the log silently. Add -NotifyLiveEvents to be
    notified about those too. "Scan now" from the tray always shows both.
#>

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Once,
    [switch]$ReportExisting,
    [switch]$NotifyLiveEvents,
    [string]$DumpDir      = 'C:\Windows\Minidump',
    [string[]]$WerRoot,
    [int]   $PollSeconds  = 15
)

$ErrorActionPreference = 'Stop'
$root       = $PSScriptRoot
$reportDir  = Join-Path $root 'diag\reports'
$stateFile  = Join-Path $root 'diag\seen-dumps.txt'
$liveState  = Join-Path $root 'diag\seen-kernel-reports.txt'
$logFile    = Join-Path $root 'diag\watcher.log'
$taskName   = 'KernelDumpWatcher'

function Write-Log {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        New-Item -ItemType Directory -Path (Split-Path $logFile) -Force | Out-Null
        Add-Content -Path $logFile -Value $line -Encoding utf8
    } catch { }
    Write-Host $line
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

# ---------------------------------------------------------------- dump parser

$script:BugcheckNames = @{
    0x0A  = 'IRQL_NOT_LESS_OR_EQUAL'
    0x18  = 'REFERENCE_BY_POINTER'
    0x1E  = 'KMODE_EXCEPTION_NOT_HANDLED'
    0x3B  = 'SYSTEM_SERVICE_EXCEPTION'
    0x50  = 'PAGE_FAULT_IN_NONPAGED_AREA'
    0x7E  = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED'
    0xC1  = 'SPECIAL_POOL_DETECTED_MEMORY_CORRUPTION'
    0xC2  = 'BAD_POOL_CALLER'
    0xC4  = 'DRIVER_VERIFIER_DETECTED_VIOLATION'
    0xC5  = 'DRIVER_CORRUPTED_EXPOOL'
    0xC9  = 'DRIVER_VERIFIER_IOMANAGER_VIOLATION'
    0xD1  = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL'
    0xD5  = 'DRIVER_PAGE_FAULT_IN_FREED_SPECIAL_POOL'
    0xD6  = 'DRIVER_PAGE_FAULT_BEYOND_END_OF_ALLOCATION'
    0xE6  = 'DRIVER_VERIFIER_DMA_VIOLATION'
    0x141 = 'VIDEO_ENGINE_TIMEOUT_DETECTED'
    0x193 = 'VIDEO_DXGKRNL_LIVEDUMP'
    0x19  = 'BAD_POOL_HEADER'
    0x1A  = 'MEMORY_MANAGEMENT'
    0x7F  = 'UNEXPECTED_KERNEL_MODE_TRAP'
    0x9C  = 'MACHINE_CHECK_EXCEPTION'
    0x9F  = 'DRIVER_POWER_STATE_FAILURE'
    0xA0  = 'INTERNAL_POWER_ERROR'
    0xBE  = 'ATTEMPTED_WRITE_TO_READONLY_MEMORY'
    0xEA  = 'THREAD_STUCK_IN_DEVICE_DRIVER'
    0xEF  = 'CRITICAL_PROCESS_DIED'
    0xFC  = 'ATTEMPTED_EXECUTE_OF_NOEXECUTE_MEMORY'
    0x101 = 'CLOCK_WATCHDOG_TIMEOUT'
    0x116 = 'VIDEO_TDR_FAILURE'
    0x117 = 'VIDEO_TDR_TIMEOUT_DETECTED'
    0x119 = 'VIDEO_SCHEDULER_INTERNAL_ERROR'
    0x124 = 'WHEA_UNCORRECTABLE_ERROR'
    0x133 = 'DPC_WATCHDOG_VIOLATION'
    0x139 = 'KERNEL_SECURITY_CHECK_FAILURE'
    0x13A = 'KERNEL_MODE_HEAP_CORRUPTION'
    0x144 = 'BUGCODE_USB3_DRIVER'
    0x154 = 'UNEXPECTED_STORE_EXCEPTION'
    0x15F = 'CONNECTED_STANDBY_WATCHDOG_TIMEOUT_LIVEDUMP'
    0x161 = 'LIVE_SYSTEM_DUMP'
    0x190 = 'WIN32K_CRITICAL_FAILURE_LIVEDUMP'
    0x1C8 = 'MANUALLY_INITIATED_POWER_BUTTON_HOLD'
}

# Bugchecks where Driver Verifier itself names the offender in a parameter.
$script:VerifierBugchecks = @(0xC1, 0xC4, 0xC9, 0xD5, 0xD6, 0xE6)

$script:MsDrivers = @(
    'ntoskrnl.exe','hal.dll','ks.sys','portcls.sys','ndis.sys','tcpip.sys',
    'win32k.sys','win32kbase.sys','win32kfull.sys','dxgkrnl.sys','dxgmms2.sys',
    'dxgmms1.sys','usbaudio.sys','usbhub3.sys','wdf01000.sys','acpi.sys',
    'fltmgr.sys','ntfs.sys','volmgr.sys','storport.sys','kdcom.dll','clfs.sys',
    'cng.sys','msrpc.sys','tm.sys','pci.sys','wpprecorder.sys','afd.sys',
    'ksthunk.sys','btha2dp.sys','bthhfaud.sys'
)

function Read-KernelDump {
    param([string]$Path)

    $d = [System.IO.File]::ReadAllBytes($Path)
    if ($d.Length -lt 0x3000) { throw 'File too small to be a kernel dump.' }
    if ([System.Text.Encoding]::ASCII.GetString($d, 0, 8) -ne 'PAGEDU64') {
        throw 'Not a 64-bit kernel dump (missing PAGEDU64 signature).'
    }

    $code   = [BitConverter]::ToUInt32($d, 0x38)
    $params = @(0..3 | ForEach-Object { [BitConverter]::ToUInt64($d, 0x40 + 8 * $_) })

    # _TRIAGE_DUMP64 immediately follows the 0x2000-byte header.
    $callStackOff  = [BitConverter]::ToUInt32($d, 0x2000 + 0x28)
    $callStackSize = [BitConverter]::ToUInt32($d, 0x2000 + 0x2C)
    $driverListOff = [BitConverter]::ToUInt32($d, 0x2000 + 0x30)
    $driverCount   = [BitConverter]::ToUInt32($d, 0x2000 + 0x34)

    # Each _DUMP_DRIVER_ENTRY64 is 144 bytes: name offset + KLDR_DATA_TABLE_ENTRY64.
    $mods = New-Object System.Collections.Generic.List[object]
    if ($driverCount -gt 0 -and $driverCount -lt 4096) {
        for ($i = 0; $i -lt $driverCount; $i++) {
            $e = $driverListOff + $i * 144
            if ($e + 144 -gt $d.Length) { break }
            $nameOff = [BitConverter]::ToUInt64($d, $e)
            $base    = [BitConverter]::ToUInt64($d, $e + 0x38)
            $size    = [BitConverter]::ToUInt32($d, $e + 0x48)
            $name    = ''
            if ($nameOff -gt 0 -and $nameOff -lt ($d.Length - 4)) {
                $len = [BitConverter]::ToUInt32($d, $nameOff)
                if ($len -gt 0 -and $len -lt 260 -and ($nameOff + 4 + $len * 2) -le $d.Length) {
                    $name = [System.Text.Encoding]::Unicode.GetString($d, [int]$nameOff + 4, [int]$len * 2)
                }
            }
            if ($base -ne 0 -and $size -gt 0) {
                $mods.Add([pscustomobject]@{ Base = $base; Size = $size; Name = $name })
            }
        }
    }
    $sorted = @($mods | Sort-Object Base)

    $resolve = {
        param($addr)
        foreach ($m in $sorted) {
            if ($addr -ge $m.Base -and $addr -lt ($m.Base + $m.Size)) {
                return [pscustomobject]@{ Name = $m.Name; Offset = $addr - $m.Base }
            }
        }
        return $null
    }

    $frames   = New-Object System.Collections.Generic.List[object]
    $lastName = ''
    if ($callStackSize -gt 0) {
        $end = [Math]::Min($callStackOff + $callStackSize, $d.Length - 8)
        for ($o = $callStackOff; $o -lt $end; $o += 8) {
            $v = [BitConverter]::ToUInt64($d, $o)
            $r = & $resolve $v
            if ($r -and $r.Name -ne $lastName) {
                $lastName = $r.Name
                $frames.Add([pscustomobject]@{
                    Address = $v; Name = $r.Name; Offset = $r.Offset
                    ThirdParty = ($script:MsDrivers -notcontains $r.Name.ToLower())
                })
            }
        }
    }

    $verifierHits = New-Object System.Collections.Generic.List[object]
    if ($script:VerifierBugchecks -contains [int]$code) {
        for ($i = 0; $i -lt 4; $i++) {
            $r = & $resolve $params[$i]
            if ($r) {
                $verifierHits.Add([pscustomobject]@{
                    Param = $i + 1; Name = $r.Name; Offset = $r.Offset
                })
            }
        }
    }

    $faultAt = & $resolve $params[3]

    [pscustomobject]@{
        Path         = $Path
        Code         = $code
        CodeName     = $(if ($script:BugcheckNames.ContainsKey([int]$code)) { $script:BugcheckNames[[int]$code] } else { 'unknown' })
        Params       = $params
        ModuleCount  = $sorted.Count
        FaultAt      = $faultAt
        Frames       = $frames
        VerifierHits = $verifierHits
        Suspects     = @($frames | Where-Object { $_.ThirdParty } | Select-Object -ExpandProperty Name -Unique)
    }
}

function Format-DumpReport {
    param($Dump)

    $sb = New-Object System.Text.StringBuilder
    $w  = { param($t) [void]$sb.AppendLine($t) }

    & $w ('=' * 74)
    & $w ('  CRASH REPORT  -  {0}' -f (Split-Path $Dump.Path -Leaf))
    & $w ('  dump written  :  {0}' -f (Get-Item $Dump.Path).LastWriteTime)
    & $w ('  analysed      :  {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    & $w ('=' * 74)
    & $w ''
    & $w ('  Bugcheck  : 0x{0:X}  {1}' -f $Dump.Code, $Dump.CodeName)
    for ($i = 0; $i -lt 4; $i++) {
        & $w ('    param{0}  : 0x{1:x16}' -f ($i + 1), $Dump.Params[$i])
    }
    & $w ('  Modules   : {0}' -f $Dump.ModuleCount)
    & $w ''

    if ($Dump.VerifierHits.Count) {
        & $w '  -- DRIVER VERIFIER NAMED THE OFFENDER --'
        foreach ($h in $Dump.VerifierHits) {
            & $w ('    param{0} -> {1} +0x{2:x}' -f $h.Param, $h.Name, $h.Offset)
        }
        & $w ''
    }

    if ($Dump.FaultAt) {
        & $w ('  Fault address -> {0} +0x{1:x}' -f $Dump.FaultAt.Name, $Dump.FaultAt.Offset)
        & $w ''
    }

    & $w '  Call stack:'
    if ($Dump.Frames.Count) {
        foreach ($f in $Dump.Frames) {
            $mark = ''
            if ($f.ThirdParty) { $mark = '   <-- THIRD PARTY' }
            & $w ('    0x{0:x16}  {1,-28} +0x{2:x}{3}' -f $f.Address, $f.Name, $f.Offset, $mark)
        }
    } else {
        & $w '    (no frames resolved)'
    }
    & $w ''

    if ($Dump.VerifierHits.Count) {
        & $w ('  VERDICT: Verifier caught {0}' -f (($Dump.VerifierHits | Select-Object -ExpandProperty Name -Unique) -join ', '))
    } elseif ($Dump.Suspects.Count) {
        & $w ('  VERDICT: third-party driver(s) on the stack: {0}' -f ($Dump.Suspects -join ', '))
    } else {
        & $w '  VERDICT: no third-party driver captured in this stack.'
    }
    & $w ''
    $sb.ToString()
}

# ------------------------------------------------------------------ state

# One filename per line. JSON round-trips a flat string array badly here -
# a single-element array collapses to a scalar and ConvertTo-Json's wrapper
# comes back as an object, so the "already seen" test silently never matches.
# Write state atomically. A hard power-off mid-write leaves NTFS with the file
# extended but the data unflushed, which shows up as a run of NUL bytes at the
# head of the file - that happened here and made the watcher re-report old
# dumps. Write to a temp file, flush, then replace.
function Write-StateFile {
    param([string]$Path, [string[]]$Lines)
    $dir = Split-Path $Path
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $clean = @($Lines |
        ForEach-Object { if ($_) { $_.Trim().TrimStart([char]0xFEFF) } } |
        Where-Object { $_ -and $_ -notmatch '^[\x00\s]*$' } |
        Select-Object -Unique)
    $tmp = "$Path.tmp"
    $enc = New-Object System.Text.UTF8Encoding($false)   # no BOM
    [System.IO.File]::WriteAllLines($tmp, [string[]]$clean, $enc)
    [System.IO.File]::Copy($tmp, $Path, $true)
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

function Get-SeenDumps {
    if (Test-Path $stateFile) {
        try {
            return @(Get-Content $stateFile -ErrorAction Stop |
                     ForEach-Object { $_.Trim().TrimStart([char]0xFEFF) } |
                     Where-Object { $_ })
        } catch { }
    }
    return @()
}

function Save-SeenDumps {
    param([string[]]$Names)
    Write-StateFile -Path $stateFile -Lines $Names
}

function Invoke-DumpScan {
    <# Returns report objects for dumps not seen before. #>
    $seen = @(Get-SeenDumps)
    $found = @()
    if (-not (Test-Path $DumpDir)) { return $found }

    $dumps = @(Get-ChildItem (Join-Path $DumpDir '*.dmp') -Force -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime)
    foreach ($f in $dumps) {
        if ($seen -contains $f.Name) { continue }

        # A dump still being written will fail to open exclusively - skip this round.
        try {
            $fs = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'None')
            $fs.Close()
        } catch {
            Write-Log ('dump still being written, deferring: {0}' -f $f.Name)
            continue
        }

        try {
            $dump = Read-KernelDump -Path $f.FullName
            $text = Format-DumpReport -Dump $dump
            New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
            $out = Join-Path $reportDir ('crash-{0}.txt' -f $f.BaseName)
            Set-Content -Path $out -Value $text -Encoding utf8
            Write-Log ('analysed {0} -> 0x{1:X} {2}' -f $f.Name, $dump.Code, $dump.CodeName)
            $found += [pscustomobject]@{ Dump = $dump; ReportPath = $out; Name = $f.Name }
        } catch {
            Write-Log ('FAILED to parse {0}: {1}' -f $f.Name, $_.Exception.Message)
        }
        $seen += $f.Name
    }
    Save-SeenDumps -Names $seen
    return $found
}

# ------------------------------------------------- live kernel events (WER)
#
# Live kernel events (0x141 GPU engine timeouts, 0x193 dxgkrnl livedumps) never
# produce a minidump, so the dump folder never changes and the scan above stays
# silent. They surface as Kernel_<code>_<hash>_<guid> folders under WER instead.
#
# Folder timestamps are useless - WER re-queues every report at boot, so they
# all carry the same mtime. The real time is EventTime inside Report.wer, a
# FILETIME (100ns ticks since 1601). Reading that is the whole point of this:
# it is the only way to learn WHEN a fault actually happened.

$script:WerRoots = if ($WerRoot) { $WerRoot } else {
    @(
        "$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
        "$env:ProgramData\Microsoft\Windows\WER\ReportArchive"
    )
}

function ConvertFrom-FileTime {
    param([string]$Value)
    $n = 0L
    if (-not [long]::TryParse($Value, [ref]$n)) { return $null }
    # Valid FILETIMEs for this era are ~1.3e17; anything far outside is junk.
    if ($n -lt 100000000000000000L -or $n -gt 160000000000000000L) { return $null }
    try { return [DateTime]::FromFileTimeUtc($n).ToLocalTime() } catch { return $null }
}

function Read-WerReport {
    param([string]$Dir)

    $name = Split-Path $Dir -Leaf
    $code = $null
    if ($name -match '^Kernel_([0-9a-fA-F]+)_') {
        try { $code = [Convert]::ToInt32($matches[1], 16) } catch { }
    }

    $when   = $null
    $params = @()
    $wer = Join-Path $Dir 'Report.wer'
    if (Test-Path $wer) {
        try {
            # Report.wer is UTF-16; Get-Content -Raw with default encoding mangles it.
            $text = [System.IO.File]::ReadAllText($wer, [System.Text.Encoding]::Unicode)
            if ($text -notmatch 'EventType') {
                $text = [System.IO.File]::ReadAllText($wer, [System.Text.Encoding]::UTF8)
            }
            foreach ($line in ($text -split "`r?`n")) {
                if ($line -match '^EventTime=(\d+)') { $when = ConvertFrom-FileTime $matches[1] }
                if ($line -match '^Sig\[(\d+)\]\.Value=(.*)$') { $params += $matches[2].Trim() }
            }
        } catch { }
    }

    [pscustomobject]@{
        Folder   = $name
        Code     = $code
        CodeName = $(if ($code -ne $null -and $script:BugcheckNames.ContainsKey($code)) { $script:BugcheckNames[$code] } else { 'unknown' })
        When     = $when
        Params   = $params
    }
}

function Get-SeenLive {
    if (Test-Path $liveState) {
        try {
            return @(Get-Content $liveState -ErrorAction Stop |
                     ForEach-Object { $_.Trim().TrimStart([char]0xFEFF) } | Where-Object { $_ })
        } catch { }
    }
    return @()
}

function Save-SeenLive {
    param([string[]]$Names)
    Write-StateFile -Path $liveState -Lines $Names
}

function Get-KernelReportFolders {
    $out = @()
    foreach ($r in $script:WerRoots) {
        if (-not (Test-Path $r)) { continue }
        $out += @(Get-ChildItem $r -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like 'Kernel_*' })
    }
    return $out
}

function Invoke-LiveKernelScan {
    $seen  = @(Get-SeenLive)
    $found = @()
    foreach ($d in (Get-KernelReportFolders)) {
        if ($seen -contains $d.Name) { continue }
        try {
            $info = Read-WerReport -Dir $d.FullName
            $stamp = if ($info.When) { $info.When.ToString('yyyy-MM-dd HH:mm:ss') } else { 'time unknown' }

            New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
            $safe = if ($info.Code -ne $null) { '0x{0:X}' -f $info.Code } else { 'unknown' }
            $out  = Join-Path $reportDir ('live-{0}-{1}.txt' -f $safe, $d.Name.Substring($d.Name.Length - 8))

            $lines = @(
                ('=' * 74)
                ('  LIVE KERNEL EVENT  -  {0}  {1}' -f $safe, $info.CodeName)
                ('  occurred  :  {0}' -f $stamp)
                ('  report    :  {0}' -f $d.FullName)
                ('=' * 74)
                ''
                '  Parameters:'
            )
            for ($i = 0; $i -lt $info.Params.Count -and $i -lt 6; $i++) {
                $lines += ('    Sig[{0}] = {1}' -f $i, $info.Params[$i])
            }
            $lines += ''
            $lines += '  Note: live kernel events are non-fatal. Windows captured state and'
            $lines += '  recovered. No minidump is produced, so there is no call stack here.'
            Set-Content -Path $out -Value $lines -Encoding utf8

            Write-Log ('live kernel event {0} {1} at {2}' -f $safe, $info.CodeName, $stamp)
            $found += [pscustomobject]@{ Info = $info; ReportPath = $out; Stamp = $stamp }
        } catch {
            Write-Log ('FAILED to read {0}: {1}' -f $d.Name, $_.Exception.Message)
        }
        $seen += $d.Name
    }
    Save-SeenLive -Names $seen
    return $found
}

# ------------------------------------------------------------- install/remove

if ($Install) {
    if (-not (Test-Admin)) {
        Write-Host 'Elevating to register the scheduled task...' -ForegroundColor DarkGray
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Install')
        return
    }
    # Stop any instance already running, otherwise the old process lingers and
    # keeps polling alongside the new one.
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'watch-dumps' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    $extra = ''
    if ($NotifyLiveEvents) { $extra = ' -NotifyLiveEvents' }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"{1}' -f $PSCommandPath, $extra)
    $trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                    -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
                    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
                    -LogonType Interactive -RunLevel Highest

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null

    Write-Host ''
    Write-Host ('Installed "{0}" - starts at logon, runs elevated and hidden.' -f $taskName) -ForegroundColor Green
    Write-Host 'Starting it now...' -ForegroundColor DarkGray
    Start-ScheduledTask -TaskName $taskName
    Write-Host 'Running. A tray icon appears; it notifies you when a new dump lands.' -ForegroundColor Green
    Write-Host ''
    return
}

if ($Uninstall) {
    if (-not (Test-Admin)) {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Uninstall')
        return
    }
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host ('Removed scheduled task "{0}".' -f $taskName) -ForegroundColor Green
    return
}

# -------------------------------------------------------------------- run

if (-not (Test-Admin)) {
    Write-Warning 'C:\Windows\Minidump is readable only with elevation. Re-run elevated, or use -Install.'
}

# First run with nothing recorded: baseline the existing dumps so old crashes
# do not all fire notifications at once.
if (-not (Test-Path $stateFile) -and -not $ReportExisting) {
    $existing = @(Get-ChildItem (Join-Path $DumpDir '*.dmp') -Force -ErrorAction SilentlyContinue |
                  Select-Object -ExpandProperty Name)
    Save-SeenDumps -Names $existing
    Write-Log ('baselined {0} existing dump(s); only new ones will be reported' -f $existing.Count)
}
if (-not (Test-Path $liveState) -and -not $ReportExisting) {
    $existingLive = @(Get-KernelReportFolders | Select-Object -ExpandProperty Name)
    Save-SeenLive -Names $existingLive
    Write-Log ('baselined {0} existing kernel report(s); only new ones will be reported' -f $existingLive.Count)
}

if ($Once) {
    $new  = @(Invoke-DumpScan)
    $live = @(Invoke-LiveKernelScan)
    foreach ($n in ($new + $live)) {
        Write-Host ''
        Get-Content $n.ReportPath | Write-Host
    }
    if (-not $new.Count -and -not $live.Count) {
        Write-Host 'No new crash dumps or kernel events.' -ForegroundColor Green
    }
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$icon = New-Object System.Windows.Forms.NotifyIcon
$icon.Icon = [System.Drawing.SystemIcons]::Shield
$icon.Text = 'Kernel dump watcher'
$icon.Visible = $true
$script:LatestReport = $null

$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Scan now', $null, {
    $n = @(Invoke-DumpScan)
    $l = @(Invoke-LiveKernelScan)
    if ($n.Count)      { Show-Found $n }
    elseif ($l.Count)  { Show-LiveFound $l }   # explicit request, so always shown
    else {
        $icon.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]::Info
        $icon.BalloonTipTitle = 'Nothing new'
        $icon.BalloonTipText  = 'No new crash dumps or kernel events.'
        $icon.ShowBalloonTip(4000)
    }
})
[void]$menu.Items.Add('Open reports folder', $null, {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    Start-Process explorer.exe $reportDir
})
[void]$menu.Items.Add('Exit', $null, {
    $icon.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})
$icon.ContextMenuStrip = $menu

$icon.add_BalloonTipClicked({
    if ($script:LatestReport -and (Test-Path $script:LatestReport)) {
        Start-Process notepad.exe $script:LatestReport
    }
})

function Show-Found {
    param($Found)
    $d = $Found[-1].Dump
    $script:LatestReport = $Found[-1].ReportPath

    if ($d.VerifierHits.Count) {
        $who = ($d.VerifierHits | Select-Object -ExpandProperty Name -Unique) -join ', '
    } elseif ($d.Suspects.Count) {
        $who = $d.Suspects -join ', '
    } else {
        $who = 'no third-party driver in stack'
    }

    $icon.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]::Error
    $icon.BalloonTipTitle = ('Crash analysed: 0x{0:X} {1}' -f $d.Code, $d.CodeName)
    $icon.BalloonTipText  = ("{0}`nClick to open the full report." -f $who)
    $icon.ShowBalloonTip(20000)
    Write-Log ('NOTIFIED: 0x{0:X} {1} - {2}' -f $d.Code, $d.CodeName, $who)
}

function Show-LiveFound {
    param($Found)
    $latest = $Found[-1]
    $script:LatestReport = $latest.ReportPath
    $i = $latest.Info

    $extra = ''
    if ($Found.Count -gt 1) { $extra = (" (+{0} more)" -f ($Found.Count - 1)) }

    $icon.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]::Warning
    $icon.BalloonTipTitle = ('Kernel event: 0x{0:X} {1}{2}' -f $i.Code, $i.CodeName, $extra)
    $icon.BalloonTipText  = ("{0}`nNon-fatal - system recovered. Click for details." -f $latest.Stamp)
    $icon.ShowBalloonTip(15000)
    Write-Log ('NOTIFIED live: 0x{0:X} {1} at {2}' -f $i.Code, $i.CodeName, $latest.Stamp)
}

Write-Log ('watcher started; polling {0} every {1}s' -f $DumpDir, $PollSeconds)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $PollSeconds * 1000
$timer.add_Tick({
    try {
        $n = @(Invoke-DumpScan)
        if ($n.Count) { Show-Found $n }
        $l = @(Invoke-LiveKernelScan)
        if ($l.Count -and $NotifyLiveEvents) { Show-LiveFound $l }
    } catch {
        Write-Log ('scan error: {0}' -f $_.Exception.Message)
    }
})
$timer.Start()

# Catch anything that landed before the watcher started (the usual case after a
# bugcheck, since the dump is materialised during the next boot).
try {
    $n = @(Invoke-DumpScan)
    if ($n.Count) { Show-Found $n }
    $l = @(Invoke-LiveKernelScan)
    if ($l.Count -and $NotifyLiveEvents) { Show-LiveFound $l }
} catch { Write-Log ('startup scan error: {0}' -f $_.Exception.Message) }

[System.Windows.Forms.Application]::Run()
$icon.Visible = $false
