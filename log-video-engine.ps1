<#
    log-video-engine.ps1 - record which processes use each GPU's video engines.

    The 0x141 faults resolve into igdkmd64.sys (Intel's graphics driver) and are
    VIDEO_ENGINE timeouts, so what matters is who is driving Intel's video
    decode/encode blocks at the moment one fires. The watcher records when a
    fault happened; this records what was using the engine, so the two can be
    lined up afterwards.

    Samples cheaply and only writes rows when a video engine is actually busy,
    plus a periodic heartbeat so gaps are distinguishable from downtime.

    Usage:
        .\log-video-engine.ps1 -Install      run at logon in the background
        .\log-video-engine.ps1 -Uninstall    remove the scheduled task
        .\log-video-engine.ps1 -Once         print one sample and exit
        .\log-video-engine.ps1               run in the foreground
        .\log-video-engine.ps1 -Report       summarise what the log holds
        .\log-video-engine.ps1 -Around '2026-11-05 22:17'   show +/- 5 min
#>

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Once,
    [switch]$Report,
    [string]$Around,
    [int]$IntervalSeconds = 20,
    [int]$KeepDays = 14
)

$root     = $PSScriptRoot
$csv      = Join-Path $root 'diag\video-engine.csv'
$taskName = 'VideoEngineLogger'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

# LUID -> adapter name. Re-derived per run: LUIDs change across reboots and
# driver installs, which silently broke an earlier version of this analysis.
function Get-AdapterMap {
    $m = @{}
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\DirectX' -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p.Description -and $p.AdapterLuid) {
            $m['0x{0:x8}' -f ($p.AdapterLuid -band 0xFFFFFFFF)] = $p.Description
        }
    }
    return $m
}

function Get-Sample {
    param([hashtable]$Map)
    $rows = @()
    $samples = (Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue).CounterSamples
    foreach ($s in $samples) {
        if ($s.CookedValue -le 0.5) { continue }
        if ($s.InstanceName -notmatch 'videodecode|videoencode|videoprocessing') { continue }
        if ($s.InstanceName -notmatch 'pid_(\d+)_luid_0x[0-9a-f]+_(0x[0-9a-f]+)_.*engtype_(\w+)') { continue }
        $procId = $matches[1]; $luid = $matches[2]; $eng = $matches[3]
        $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        $adapter = if ($Map.ContainsKey($luid)) { $Map[$luid] } else { "unknown($luid)" }
        $short = if ($adapter -match 'NVIDIA') { 'NVIDIA' } elseif ($adapter -match 'Intel') { 'Intel' } else { 'other' }
        $rows += [pscustomobject]@{
            Time    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Adapter = $short
            Engine  = $eng
            Process = $p.ProcessName
            Pid     = $procId
            Pct     = [math]::Round($s.CookedValue, 1)
        }
    }
    return $rows
}

# ------------------------------------------------------------------ reporting

if ($Report -or $Around) {
    if (-not (Test-Path $csv)) { Write-Host 'No log yet.' -ForegroundColor Yellow; return }
    $data = Import-Csv $csv
    if ($Around) {
        $t = [datetime]$Around
        $from = $t.AddMinutes(-5); $to = $t.AddMinutes(5)
        $data = $data | Where-Object { $_.Time -and ([datetime]$_.Time) -ge $from -and ([datetime]$_.Time) -le $to }
        Write-Host ''
        Write-Host ("  Video engine activity {0} to {1}" -f $from.ToString('HH:mm:ss'), $to.ToString('HH:mm:ss')) -ForegroundColor Cyan
        Write-Host ''
        $data | Where-Object { $_.Process -ne 'HEARTBEAT' } |
            Sort-Object Time | Format-Table Time, Adapter, Engine, Process, Pct -AutoSize
        return
    }
    $real = $data | Where-Object { $_.Process -ne 'HEARTBEAT' }
    Write-Host ''
    Write-Host ('  rows: {0}   span: {1}  ->  {2}' -f $data.Count,
        ($data | Select-Object -First 1).Time, ($data | Select-Object -Last 1).Time) -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Intel video-engine users (the ones that matter):' -ForegroundColor Cyan
    $real | Where-Object { $_.Adapter -eq 'Intel' } |
        Group-Object Process, Engine |
        ForEach-Object {
            [pscustomobject]@{
                Process = $_.Name.Split(',')[0].Trim()
                Engine  = $_.Name.Split(',')[1].Trim()
                Samples = $_.Count
                AvgPct  = [math]::Round((($_.Group | Measure-Object Pct -Average).Average), 1)
            }
        } | Sort-Object Samples -Descending | Format-Table -AutoSize
    Write-Host '  NVIDIA video-engine users (for comparison):' -ForegroundColor DarkGray
    $real | Where-Object { $_.Adapter -eq 'NVIDIA' } |
        Group-Object Process, Engine |
        ForEach-Object {
            [pscustomobject]@{
                Process = $_.Name.Split(',')[0].Trim()
                Engine  = $_.Name.Split(',')[1].Trim()
                Samples = $_.Count
            }
        } | Sort-Object Samples -Descending | Format-Table -AutoSize
    return
}

# ------------------------------------------------------------- install/remove

if ($Install) {
    if (-not (Test-Admin)) {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Install')
        return
    }
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'log-video-engine' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $PSCommandPath)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Write-Host ''
    Write-Host ('Installed "{0}" - sampling every {1}s into {2}' -f $taskName, $IntervalSeconds, $csv) -ForegroundColor Green
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
    Write-Host ('Removed "{0}".' -f $taskName) -ForegroundColor Green
    return
}

# ------------------------------------------------------------------- sampling

$map = Get-AdapterMap
New-Item -ItemType Directory -Path (Split-Path $csv) -Force | Out-Null
if (-not (Test-Path $csv)) {
    Set-Content -LiteralPath $csv -Value 'Time,Adapter,Engine,Process,Pid,Pct' -Encoding utf8
}

if ($Once) {
    $rows = Get-Sample -Map $map
    if ($rows) { $rows | Format-Table -AutoSize } else { Write-Host 'No video-engine activity right now.' }
    return
}

$lastHeartbeat = [datetime]::MinValue
$lastTrim = [datetime]::MinValue

while ($true) {
    try {
        $rows = Get-Sample -Map $map
        foreach ($r in $rows) {
            Add-Content -LiteralPath $csv -Encoding utf8 -Value (
                '{0},{1},{2},{3},{4},{5}' -f $r.Time, $r.Adapter, $r.Engine, $r.Process, $r.Pid, $r.Pct)
        }
        # Heartbeat every 10 minutes so a quiet period is distinguishable from
        # the logger not running.
        if (((Get-Date) - $lastHeartbeat).TotalMinutes -ge 10) {
            Add-Content -LiteralPath $csv -Encoding utf8 -Value (
                '{0},-,-,HEARTBEAT,0,0' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
            $lastHeartbeat = Get-Date
        }
        # Trim daily so the file cannot grow without bound.
        if (((Get-Date) - $lastTrim).TotalHours -ge 24) {
            $cut = (Get-Date).AddDays(-$KeepDays)
            $all = Import-Csv $csv -ErrorAction SilentlyContinue
            if ($all) {
                $keep = $all | Where-Object { $_.Time -and ([datetime]$_.Time) -ge $cut }
                if ($keep.Count -lt $all.Count) {
                    $tmp = "$csv.tmp"
                    $keep | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding utf8
                    [System.IO.File]::Copy($tmp, $csv, $true)
                    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                }
            }
            $lastTrim = Get-Date
        }
    } catch { }
    Start-Sleep -Seconds $IntervalSeconds
}
