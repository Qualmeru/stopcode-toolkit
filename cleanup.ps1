<#
    cleanup.ps1 - reclaim disk space from regenerable caches and stale temp data.

    Only touches things Windows or an application will rebuild on demand. Never
    touches user documents, Downloads, game installs or the project folder.

    Usage:
        .\cleanup.ps1            report only, delete nothing
        .\cleanup.ps1 -Apply     actually delete
        .\cleanup.ps1 -Apply -IncludeSystem   also the admin-only targets
                                              (needs an elevated shell)
#>

[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$IncludeSystem,
    [switch]$IncludeDev
)

function Get-FolderSize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $m = Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
         Where-Object { -not $_.PSIsContainer } |
         Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue
    if ($m.Sum) { return [int64]$m.Sum }
    return 0
}

function Invoke-Target {
    param(
        [string]$Label,
        [string]$Path,
        [datetime]$OlderThan = [datetime]::MaxValue,
        [string]$SkipPattern
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Label = $Label; Bytes = 0; Note = 'not present' }
    }

    $bytes = 0
    $items = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
             Where-Object { $_.LastWriteTime -lt $OlderThan }
    if ($SkipPattern) { $items = $items | Where-Object { $_.FullName -notmatch $SkipPattern } }

    foreach ($i in $items) {
        $sz = if ($i.PSIsContainer) { Get-FolderSize $i.FullName } else { [int64]$i.Length }
        if ($Apply) {
            Remove-Item -LiteralPath $i.FullName -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $i.FullName)) { $bytes += $sz }
        } else {
            $bytes += $sz
        }
    }
    return [pscustomobject]@{ Label = $Label; Bytes = $bytes; Note = '' }
}

$drive  = Get-PSDrive C
$before = $drive.Free
$dayOld = (Get-Date).AddDays(-1)

Write-Host ''
if ($Apply) { Write-Host '  DELETING' -ForegroundColor Yellow }
else        { Write-Host '  DRY RUN - nothing will be deleted' -ForegroundColor Cyan }
Write-Host ''

$results = @()

# --- always safe: regenerable caches, owned by the current user -------------
$results += Invoke-Target 'NVIDIA shader cache'  "$env:LOCALAPPDATA\NVIDIA\DXCache"
$results += Invoke-Target 'NVIDIA GL cache'      "$env:LOCALAPPDATA\NVIDIA\GLCache"
$results += Invoke-Target 'DirectX shader cache' "$env:LOCALAPPDATA\D3DSCache"
$results += Invoke-Target 'App crash dumps'      "$env:LOCALAPPDATA\CrashDumps"
$results += Invoke-Target 'Temp (over a day old)' $env:TEMP $dayOld 'claude'

# --- admin only -------------------------------------------------------------
# Admin-only. The WER folders are deliberately NOT here: they hold the kernel
# fault history this investigation is built on, and are only ~80 MB.
if ($IncludeSystem) {
    $results += Invoke-Target 'Windows Temp'         "$env:SystemRoot\Temp" $dayOld
    $results += Invoke-Target 'Windows Update cache' "$env:SystemRoot\SoftwareDistribution\Download"
    $results += Invoke-Target 'Live kernel dumps'    "$env:SystemRoot\LiveKernelReports"
}

# Developer caches - all re-download or rebuild on next use.
if ($IncludeDev) {
    $results += Invoke-Target 'NuGet package cache' "$env:USERPROFILE\.nuget\packages"
    $results += Invoke-Target 'npm cache'           "$env:APPDATA\npm-cache"
    $results += Invoke-Target 'Firefox cache'       "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"
}

$total = 0
foreach ($r in $results) {
    $total += $r.Bytes
    $note = if ($r.Note) { "  ($($r.Note))" } else { '' }
    Write-Host ("  {0,-26} {1,8:N2} GB{2}" -f $r.Label, ($r.Bytes / 1GB), $note)
}

Write-Host ''
Write-Host ("  {0,-26} {1,8:N2} GB" -f 'TOTAL', ($total / 1GB)) -ForegroundColor Cyan

if ($Apply) {
    $after = (Get-PSDrive C).Free
    Write-Host ''
    Write-Host ("  free before : {0,8:N1} GB" -f ($before / 1GB))
    Write-Host ("  free now    : {0,8:N1} GB" -f ($after / 1GB)) -ForegroundColor Green
    Write-Host ("  reclaimed   : {0,8:N2} GB" -f (($after - $before) / 1GB)) -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host '  Re-run with -Apply to delete.' -ForegroundColor DarkGray
}
Write-Host ''
