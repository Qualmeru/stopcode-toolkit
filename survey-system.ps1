<#
    survey-system.ps1 - report admin-only disk-space targets. Read-only.

    Writes its findings to survey-system.txt beside this script so an elevated
    run can be read back from an unelevated session.
#>

$out = Join-Path $PSScriptRoot 'survey-system.txt'
$lines = @()

function Get-Size {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $m = Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
         Where-Object { -not $_.PSIsContainer } |
         Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue
    if ($m.Sum) { return [int64]$m.Sum }
    return 0
}

$lines += '=== large system files ==='
foreach ($f in @('C:\hiberfil.sys', 'C:\pagefile.sys', 'C:\swapfile.sys')) {
    $i = Get-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    if ($i) { $lines += ('{0,-22} {1,8:N2} GB' -f $i.Name, ($i.Length / 1GB)) }
    else    { $lines += ('{0,-22} {1}' -f (Split-Path $f -Leaf), 'not present') }
}

$lines += ''
$lines += '=== admin-only folders ==='
foreach ($p in @(
    "$env:SystemRoot\LiveKernelReports",
    "$env:SystemRoot\Minidump",
    "$env:SystemRoot\SoftwareDistribution\Download",
    "$env:SystemRoot\Temp",
    "$env:ProgramData\Microsoft\Windows\WER"
)) {
    $lines += ('{0,-56} {1,8:N2} GB' -f $p, ((Get-Size $p) / 1GB))
}

$lines += ''
$lines += '=== biggest individual live kernel dumps ==='
$big = Get-ChildItem -LiteralPath "$env:SystemRoot\LiveKernelReports" -Recurse -Force -ErrorAction SilentlyContinue |
       Where-Object { -not $_.PSIsContainer } |
       Sort-Object Length -Descending | Select-Object -First 6
if ($big) {
    foreach ($b in $big) {
        $lines += ('{0,8:N2} GB  {1}  {2}' -f ($b.Length / 1GB), $b.LastWriteTime.ToString('yyyy-MM-dd'), $b.Name)
    }
} else {
    $lines += '  none'
}

$lines += ''
$lines += '=== hibernation ==='
$hp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue).HibernateEnabled
$lines += ("HibernateEnabled = {0}  (1 = on; hiberfil.sys exists and Fast Startup uses it)" -f $hp)

# DISM's AnalyzeComponentStore can hang for many minutes on this machine, so it
# is opt-in rather than part of the default survey.
if ($env:SURVEY_WITH_DISM -eq '1') {
    $lines += ''
    $lines += '=== component store (WinSxS) ==='
    $d = & dism.exe /Online /Cleanup-Image /AnalyzeComponentStore 2>&1
    $lines += ($d | Where-Object { $_ -match 'Actual Size|Shared with|Backups and|Cache and|Reclaimable|Recommended' })
}

Set-Content -LiteralPath $out -Value $lines -Encoding utf8
Write-Host "written to $out"
Start-Sleep -Seconds 3
