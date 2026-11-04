<#
    collect-crash.ps1 - gather crash evidence into a readable folder.

    Minidumps and WER kernel reports are ACL'd to SYSTEM/Administrators, so a
    normal session cannot read them. This copies them somewhere readable so the
    faulting driver can be identified.

    Self-elevates. Output: .\diag\
#>

[CmdletBinding()]
param()

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host 'Elevating...' -ForegroundColor DarkGray
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    } catch { Write-Warning 'Elevation cancelled.' }
    return
}

$dest = Join-Path $PSScriptRoot 'diag'
New-Item -ItemType Directory -Path $dest -Force | Out-Null

# 1. Kernel minidumps
$dumpDest = Join-Path $dest 'minidumps'
New-Item -ItemType Directory -Path $dumpDest -Force | Out-Null
$dumps = Get-ChildItem 'C:\Windows\Minidump\*.dmp' -ErrorAction SilentlyContinue
foreach ($d in $dumps) {
    Copy-Item $d.FullName -Destination $dumpDest -Force -ErrorAction SilentlyContinue
}
Write-Host ("Minidumps copied: {0}" -f $dumps.Count) -ForegroundColor Green

# 2. WER kernel reports (Report.wer names the faulting driver)
$werDest = Join-Path $dest 'wer'
New-Item -ItemType Directory -Path $werDest -Force | Out-Null
$n = 0
foreach ($root in @("$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
                    "$env:ProgramData\Microsoft\Windows\WER\ReportArchive")) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'Kernel_*' } |
        ForEach-Object {
            $wer = Join-Path $_.FullName 'Report.wer'
            if (Test-Path $wer) {
                Copy-Item $wer -Destination (Join-Path $werDest ($_.Name + '.wer')) -Force -ErrorAction SilentlyContinue
                $n++
            }
        }
}
Write-Host ("WER kernel reports copied: {0}" -f $n) -ForegroundColor Green

# 3. Live kernel dumps (the 0x141 / 0x193 graphics faults).
#    WATCHDOG dumps can be many gigabytes - copying those filled the disk once,
#    so anything over the cap is listed rather than copied.
$MaxDumpMB = 512
$lkDest = Join-Path $dest 'livekernel'
New-Item -ItemType Directory -Path $lkDest -Force | Out-Null
$lk = Get-ChildItem "$env:SystemRoot\LiveKernelReports" -Recurse -Include *.dmp -ErrorAction SilentlyContinue
$copied = 0
$skipped = @()
foreach ($f in $lk) {
    $mb = [math]::Round($f.Length / 1MB)
    if ($mb -gt $MaxDumpMB) {
        $skipped += ('{0}  ({1:N0} MB)  {2}' -f $f.Name, $mb, $f.FullName)
        continue
    }
    Copy-Item $f.FullName -Destination (Join-Path $lkDest ($f.Directory.Name + '_' + $f.Name)) -Force -ErrorAction SilentlyContinue
    $copied++
}
Write-Host ("Live kernel dumps copied: {0} of {1}" -f $copied, $lk.Count) -ForegroundColor Green
if ($skipped.Count) {
    Write-Host ("Skipped {0} dump(s) over {1} MB (left in place):" -f $skipped.Count, $MaxDumpMB) -ForegroundColor Yellow
    $skipped | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor DarkGray }
}

# 4. Make everything readable by the logged-on user
$user = (Get-CimInstance Win32_ComputerSystem).UserName
if ($user) {
    & icacls.exe $dest /grant "${user}:(OI)(CI)F" /T /Q 2>&1 | Out-Null
}

Write-Host ''
Write-Host ("Done. Collected into: " + $dest) -ForegroundColor Cyan
Write-Host 'Press any key to close...' -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
