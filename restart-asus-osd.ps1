<#
    restart-asus-osd.ps1 - restart the ASUS hotkey / on-screen-display stack.

    On ZenBooks a volume or brightness keypress goes:
        key -> ASUS System Control Interface -> ASUSOptimization -> AsusOSD overlay
    so a stale AsusOSD makes the popup lag even though audio is fine.

    AsusOSD is usually orphaned (its launcher exits), so it is restarted by
    bouncing the ASUSOptimization service rather than killed on its own.

    Writes results beside this script so an unelevated session can read them.
#>

$out = Join-Path $PSScriptRoot 'restart-asus-osd.txt'
$log = @()

function Note { param([string]$m) ; $script:log += ('{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) }

Note 'before:'
Get-Process AsusOSD -ErrorAction SilentlyContinue |
    ForEach-Object { Note ('  AsusOSD pid {0} started {1}' -f $_.Id, $_.StartTime) }

# Bounce the hotkey service; it re-launches the overlay.
foreach ($svc in @('ASUSOptimization')) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $s) { Note ("  service {0} not found" -f $svc); continue }
    Note ('restarting service {0} (was {1})' -f $svc, $s.Status)
    try {
        Restart-Service -Name $svc -Force -ErrorAction Stop
        Note ('  -> now {0}' -f (Get-Service -Name $svc).Status)
    } catch {
        Note ('  -> FAILED: {0}' -f $_.Exception.Message)
    }
}

Start-Sleep -Seconds 6

Note 'after:'
$osd = Get-Process AsusOSD -ErrorAction SilentlyContinue
if ($osd) {
    $osd | ForEach-Object { Note ('  AsusOSD pid {0} started {1}' -f $_.Id, $_.StartTime) }
} else {
    Note '  AsusOSD not running - it did not come back on its own'
    $exe = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Filter 'AsusOSD.exe' -Recurse -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($exe) {
        Note ('  relaunching {0}' -f $exe.FullName)
        Start-Process $exe.FullName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        $osd2 = Get-Process AsusOSD -ErrorAction SilentlyContinue
        if ($osd2) { Note ('  AsusOSD pid {0} relaunched' -f $osd2.Id) }
        else { Note '  relaunch did not take' }
    } else {
        Note '  AsusOSD.exe not found in the DriverStore'
    }
}

Set-Content -LiteralPath $out -Value $log -Encoding utf8
$log | ForEach-Object { Write-Host $_ }
Start-Sleep -Seconds 3
