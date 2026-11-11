<#
    peek-livedump.ps1 - read the header of a live kernel dump without copying it.

    Live kernel dumps can be many gigabytes, so this streams only the first
    0x3000 bytes: enough for DUMP_HEADER64 (bugcheck code and parameters) and
    to test whether a _TRIAGE_DUMP64 section is present at 0x2000. A triage
    section means the module list and call stack can be resolved the same way
    watch-dumps.ps1 resolves a minidump.

    Needs elevation. Writes results beside this script.
#>

$out = Join-Path $PSScriptRoot 'peek-livedump.txt'
$lines = @()

$dumps = Get-ChildItem -LiteralPath "$env:SystemRoot\LiveKernelReports" -Recurse -Force -ErrorAction SilentlyContinue |
         Where-Object { -not $_.PSIsContainer -and $_.Extension -eq '.dmp' } |
         Sort-Object LastWriteTime -Descending

if (-not $dumps) {
    $lines += 'No live kernel dumps found.'
    Set-Content -LiteralPath $out -Value $lines -Encoding utf8
    $lines | ForEach-Object { Write-Host $_ }
    Start-Sleep -Seconds 3
    return
}

$BUGCHECKS = @{
    0x0A  = 'IRQL_NOT_LESS_OR_EQUAL'
    0x141 = 'VIDEO_ENGINE_TIMEOUT_DETECTED'
    0x193 = 'VIDEO_DXGKRNL_LIVEDUMP'
    0x1A1 = 'VIDEO_TDR_APPLICATION_BLOCKED'
    0x18  = 'REFERENCE_BY_POINTER'
    0x19  = 'BAD_POOL_HEADER'
    0x1A  = 'MEMORY_MANAGEMENT'
    0x1E  = 'KMODE_EXCEPTION_NOT_HANDLED'
    0x3B  = 'SYSTEM_SERVICE_EXCEPTION'
    0x50  = 'PAGE_FAULT_IN_NONPAGED_AREA'
    0x7E  = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED'
    0x7F  = 'UNEXPECTED_KERNEL_MODE_TRAP'
    0x9C  = 'MACHINE_CHECK_EXCEPTION'
    0x9F  = 'DRIVER_POWER_STATE_FAILURE'
    0xA0  = 'INTERNAL_POWER_ERROR'
    0xBE  = 'ATTEMPTED_WRITE_TO_READONLY_MEMORY'
    0xC1  = 'SPECIAL_POOL_DETECTED_MEMORY_CORRUPTION'
    0xC2  = 'BAD_POOL_CALLER'
    0xC4  = 'DRIVER_VERIFIER_DETECTED_VIOLATION'
    0xC5  = 'DRIVER_CORRUPTED_EXPOOL'
    0xC9  = 'DRIVER_VERIFIER_IOMANAGER_VIOLATION'
    0xD1  = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL'
    0xD5  = 'DRIVER_PAGE_FAULT_IN_FREED_SPECIAL_POOL'
    0xD6  = 'DRIVER_PAGE_FAULT_BEYOND_END_OF_ALLOCATION'
    0xE6  = 'DRIVER_VERIFIER_DMA_VIOLATION'
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

foreach ($d in $dumps) {
    $lines += ('=' * 72)
    $lines += ('  {0}' -f $d.Name)
    $lines += ('  {0:N2} GB   written {1}' -f ($d.Length / 1GB), $d.LastWriteTime)
    $lines += ('=' * 72)

    $buf = New-Object byte[] 0x3000
    try {
        $fs = [System.IO.File]::Open($d.FullName, 'Open', 'Read', 'ReadWrite')
        $null = $fs.Read($buf, 0, $buf.Length)
        $fs.Close()
    } catch {
        $lines += ('  cannot open: {0}' -f $_.Exception.Message)
        continue
    }

    $sig = [System.Text.Encoding]::ASCII.GetString($buf, 0, 8)
    $lines += ('  signature      : {0}' -f $sig)
    if ($sig -ne 'PAGEDU64') {
        $lines += '  not a 64-bit kernel dump - cannot parse'
        continue
    }

    $code = [BitConverter]::ToUInt32($buf, 0x38)
    $name = if ($BUGCHECKS.ContainsKey([int]$code)) { $BUGCHECKS[[int]$code] } else { 'unknown' }
    $lines += ('  bugcheck       : 0x{0:X}  {1}' -f $code, $name)
    for ($i = 0; $i -lt 4; $i++) {
        $lines += ('    param{0}        : 0x{1:x16}' -f ($i + 1), [BitConverter]::ToUInt64($buf, 0x40 + 8 * $i))
    }

    # DumpType: 1 = full, 2 = kernel/summary, 5 = triage-ish. Field position
    # varies by build, so the triage probe below is the reliable test.
    $lines += ('  machine type   : 0x{0:X}' -f [BitConverter]::ToUInt32($buf, 0x30))
    $lines += ('  processors     : {0}' -f [BitConverter]::ToUInt32($buf, 0x34))

    # Probe for a _TRIAGE_DUMP64 at 0x2000: SizeOfDump and DriverCount should be sane.
    $sizeOfDump  = [BitConverter]::ToUInt32($buf, 0x2000 + 0x04)
    $driverList  = [BitConverter]::ToUInt32($buf, 0x2000 + 0x30)
    $driverCount = [BitConverter]::ToUInt32($buf, 0x2000 + 0x34)
    $stackOff    = [BitConverter]::ToUInt32($buf, 0x2000 + 0x28)
    $stackSize   = [BitConverter]::ToUInt32($buf, 0x2000 + 0x2C)

    $plausible = ($driverCount -gt 10 -and $driverCount -lt 4096 -and
                  $driverList -gt 0x2000 -and $driverList -lt 0x4000000)

    $lines += ''
    $lines += '  triage section probe:'
    $lines += ('    SizeOfDump   : {0:N0}' -f $sizeOfDump)
    $lines += ('    DriverCount  : {0}' -f $driverCount)
    $lines += ('    DriverList   : 0x{0:x}' -f $driverList)
    $lines += ('    CallStack    : offset 0x{0:x}, {1} bytes' -f $stackOff, $stackSize)
    if ($plausible) {
        $lines += '    -> TRIAGE SECTION LOOKS PRESENT: module list and stack are resolvable.'
    } else {
        $lines += '    -> no triage section (full/summary dump); needs a real debugger for a stack.'
    }
    $lines += ''
}

Set-Content -LiteralPath $out -Value $lines -Encoding utf8
$lines | ForEach-Object { Write-Host $_ }
Start-Sleep -Seconds 4
