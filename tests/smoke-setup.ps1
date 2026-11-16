<#
    smoke-setup.ps1 - run the README's setup and removal steps for real and
    check each one did what the README says.

    Installs KernelDumpWatcher and VideoEngineLogger, checks they start and
    report their state, uninstalls them, then creates and removes the
    shortcuts. Fails if anything is left behind or the clone is changed
    outside diag\.

    Meant for a throwaway Windows machine such as a GitHub Actions runner. It
    refuses to run where the tasks or shortcuts already exist, so it cannot
    replace or remove a real installation.

    Usage (elevated Windows PowerShell 5.1):
        powershell -ExecutionPolicy Bypass -File tests\smoke-setup.ps1
#>

[CmdletBinding()]
param([int]$StartTimeoutSeconds = 30)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$ps     = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tasks  = @(
    @{ Name = 'KernelDumpWatcher'; Script = 'watch-dumps.ps1';      RunLevel = 'Highest' },
    @{ Name = 'VideoEngineLogger'; Script = 'log-video-engine.ps1'; RunLevel = 'Limited' }
)
$linkName = 'stopcode-toolkit Control Panel.lnk'
$desktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) $linkName
$startDir    = Join-Path ([Environment]::GetFolderPath('Programs')) 'Stopcode Toolkit'
$startLink   = Join-Path $startDir $linkName

$script:Failures = 0
function Pass { param([string]$Message) Write-Host ('  PASS  ' + $Message) -ForegroundColor Green }
function Fail {
    param([string]$Message)
    $script:Failures++
    Write-Host ('  FAIL  ' + $Message) -ForegroundColor Red
}
function Check {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Pass $Message } else { Fail $Message }
}
function Step { param([string]$Title) Write-Host ''; Write-Host ('== ' + $Title) -ForegroundColor Cyan }

function Invoke-Script {
    param([string]$Script, [string[]]$Arguments)
    $path = Join-Path $root $Script
    $out = & $ps -NoProfile -ExecutionPolicy Bypass -File $path @Arguments 2>&1
    $code = $LASTEXITCODE
    $out | ForEach-Object { Write-Host ('        ' + $_) -ForegroundColor DarkGray }
    Check ($code -eq 0) ('{0} {1} exited with code {2}' -f $Script, ($Arguments -join ' '), $code)
}

function Get-TaskProcesses {
    param([string]$Script)
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match [regex]::Escape($Script) -and $_.ProcessId -ne $PID })
}

# ------------------------------------------------------------------ preflight

Step 'Preflight'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
    [Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $admin) { throw 'Run this elevated: the installers would otherwise open a UAC prompt.' }
Pass 'running elevated'
Check ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1) (
    'Windows PowerShell {0}' -f $PSVersionTable.PSVersion)
Pass ('{0} build {1}' -f (Get-CimInstance Win32_OperatingSystem).Caption, [Environment]::OSVersion.Version.Build)

$existing = @($tasks | Where-Object { Get-ScheduledTask -TaskName $_.Name -ErrorAction SilentlyContinue })
$existingLinks = @(@($desktopLink, $startLink) | Where-Object { Test-Path -LiteralPath $_ })
if ($existing.Count -or $existingLinks.Count) {
    throw ('Not a clean machine - already installed: {0}. This test would replace them, so it stops here.' -f (
        (@($existing | ForEach-Object { $_.Name }) + $existingLinks) -join ', '))
}
Pass 'no tasks or shortcuts installed yet'

$gitBefore = @(git -C $root status --porcelain --untracked-files=all)

# --------------------------------------------------------------------- install

Step 'Install the scheduled tasks'
foreach ($t in $tasks) {
    Invoke-Script $t.Script @('-Install')
    $task = Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue
    if (-not $task) { Fail ('{0} registered' -f $t.Name); continue }
    Pass ('{0} registered' -f $t.Name)
    $action = @($task.Actions)[0]
    Check ($action.Execute -eq 'powershell.exe' -and
           $action.Arguments -like ('*"{0}"*' -f (Join-Path $root $t.Script))) (
        '{0} runs {1} from this clone' -f $t.Name, $t.Script)
    Check (@($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' }).Count -eq 1) (
        '{0} starts at logon' -f $t.Name)
    Check ([string]$task.Principal.RunLevel -eq $t.RunLevel) (
        '{0} run level is {1} (expected {2})' -f $t.Name, $task.Principal.RunLevel, $t.RunLevel)
}

# ------------------------------------------------------------- run and status

Step 'Check the tasks are running'
foreach ($t in $tasks) {
    $deadline = (Get-Date).AddSeconds($StartTimeoutSeconds)
    do {
        $state = [string](Get-ScheduledTask -TaskName $t.Name).State
        $procs = Get-TaskProcesses $t.Script
        if ($state -eq 'Running' -and $procs.Count) { break }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    $info = Get-ScheduledTaskInfo -TaskName $t.Name
    Check ($state -eq 'Running') ('{0} state is {1} (last result 0x{2:X})' -f $t.Name, $state, $info.LastTaskResult)
    Check ($procs.Count -ge 1) ('{0} has {1} {2} process(es)' -f $t.Name, $procs.Count, $t.Script)
}

# The README's status command, run as documented.
$status = & $ps -NoProfile -Command 'Get-ScheduledTask KernelDumpWatcher,VideoEngineLogger | Select-Object TaskName,State' 2>&1 | Out-String
Write-Host ($status.TrimEnd() -replace '(?m)^', '        ') -ForegroundColor DarkGray
foreach ($t in $tasks) {
    Check ($status -match ('{0}\s+Running' -f $t.Name)) ('README status command shows {0} Running' -f $t.Name)
}

# ------------------------------------------------------------------- uninstall

Step 'Uninstall the scheduled tasks'
foreach ($t in $tasks) {
    Invoke-Script $t.Script @('-Uninstall')
    Check (-not (Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue)) ('{0} removed' -f $t.Name)
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-TaskProcesses $t.Script).Count -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    $left = Get-TaskProcesses $t.Script
    Check ($left.Count -eq 0) ('{0} left {1} process(es) running' -f $t.Name, $left.Count)
}

# ------------------------------------------------------------------- shortcuts

Step 'Create and remove the shortcuts'
Invoke-Script 'make-shortcut.ps1' @()
$shell = New-Object -ComObject WScript.Shell
foreach ($p in @($desktopLink, $startLink)) {
    if (-not (Test-Path -LiteralPath $p)) { Fail ('created {0}' -f $p); continue }
    $lnk = $shell.CreateShortcut($p)
    Check ($lnk.Arguments -like ('*"{0}"*' -f (Join-Path $root 'ControlPanel.ps1'))) ('{0} opens ControlPanel.ps1' -f $p)
}
Invoke-Script 'make-shortcut.ps1' @('-Remove')
foreach ($p in @($desktopLink, $startLink, $startDir)) {
    Check (-not (Test-Path -LiteralPath $p)) ('removed {0}' -f $p)
}

# ------------------------------------------------------------------ leftovers

Step 'Check nothing else changed'
$gitAfter = @(git -C $root status --porcelain --untracked-files=all)
$changed = @(Compare-Object $gitBefore $gitAfter -PassThru)
Check ($changed.Count -eq 0) ('tracked and unignored files unchanged{0}' -f $(if ($changed.Count) { ': ' + ($changed -join '; ') } else { '' }))

# Ignored output belongs in diag\; ControlPanel.ico is the documented exception.
$ignored = @(git -C $root status --porcelain --ignored --untracked-files=all |
    Where-Object { $_ -like '!! *' } | ForEach-Object { $_.Substring(3) } |
    Where-Object { $_ -notlike 'diag/*' -and $_ -ne 'ControlPanel.ico' -and $_ -notmatch '(^|/)__pycache__/' })
Check ($ignored.Count -eq 0) ('no output outside diag\{0}' -f $(if ($ignored.Count) { ': ' + ($ignored -join ', ') } else { '' }))

Write-Host ''
if ($script:Failures) {
    Write-Host ('{0} check(s) failed.' -f $script:Failures) -ForegroundColor Red
    exit 1
}
Write-Host 'Setup smoke test passed.' -ForegroundColor Green
