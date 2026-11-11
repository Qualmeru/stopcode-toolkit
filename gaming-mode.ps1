<#
    gaming-mode.ps1 - free up the machine before a game, with you choosing what closes.

    Game stutter and desktop crashes are often commit pressure, not raw speed:
    a game plus a full browser load can exhaust the commit limit (RAM plus
    pagefile) badly enough to kill dwm.exe. So the single most useful thing
    before playing is reclaiming commit, and the second is stopping background
    work that was never needed.

    Nothing is closed without you picking it. Apps are asked to close politely
    first so they can save state, and only forced if they ignore it.

    Usage:
        .\gaming-mode.ps1              pick VR / flat interactively
        .\gaming-mode.ps1 -VR          VR session: start the VR stack
        .\gaming-mode.ps1 -Flat        non-VR: shut the VR stack down
        .\gaming-mode.ps1 -Restore     bring the VR stack and power plan back
        .\gaming-mode.ps1 -WhatIf      show what it would do, change nothing
        .\gaming-mode.ps1 -Flat -Recommended   take the recommended set, no prompt
        .\gaming-mode.ps1 -Flat -Preset browse keep web browsers, close the rest
        .\gaming-mode.ps1 -Flat -Keep chrome,Discord   spare these whatever else is picked
        .\gaming-mode.ps1 -Flat -PowerPlan     also switch the power plan
#>

[CmdletBinding()]
param(
    [switch]$VR,
    [switch]$Flat,
    [switch]$Restore,
    [switch]$WhatIf,
    [switch]$PowerPlan,
    [switch]$Recommended,
    [ValidateSet('clean','browse','work')]
    [string]$Preset,
    [string[]]$Keep,
    [int]$MinimumMB = 150
)

# Keep-presets: start from the recommended set, then spare the named processes.
# Browsers and VS Code are usually the biggest things the recommended set
# frees, so they are the ones worth a dedicated preset.
$Browsers = @('chrome','msedge','firefox','brave','opera','vivaldi')
$Presets = @{
    'clean'  = @{ Keep = @();                       Desc = 'close everything recommended' }
    'browse' = @{ Keep = $Browsers;                 Desc = 'keep web browsers for looking things up' }
    'work'   = @{ Keep = $Browsers + @('Code');     Desc = 'keep web browsers and VS Code' }
}

$stateFile = Join-Path $PSScriptRoot 'diag\gaming-mode-state.json'

# powershell.exe -File passes every argument as a plain string, so
# "-Keep chrome,Discord" arrives as ONE element containing a comma rather than
# two. Split it here so both invocation styles behave the same.
if ($Keep) {
    $Keep = @($Keep -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# --------------------------------------------------------------- protected set
# Never offered for closing: the OS would break, security would be weakened, or
# the fault monitoring would stop recording.
$Protected = @(
    'System','Idle','Registry','Memory Compression','csrss','wininit','winlogon',
    'services','lsass','smss','fontdrvhost','dwm','explorer','sihost','ctfmon',
    'taskhostw','RuntimeBroker','ShellExperienceHost','StartMenuExperienceHost',
    'SearchHost','TextInputHost','audiodg','svchost','spoolsv','conhost',
    'MsMpEng','SecurityHealthService','NisSrv','WmiPrvSE','dllhost','WUDFHost',
    'powershell','pwsh','WindowsTerminal','cmd',
    # Graphics driver hosts: killing these can take the display stack down.
    'NVDisplay.Container','nvcontainer','igfxEM','igfxCUIService','IntelCpHDCPSvc'
)

# Recommended to close: safe to shut down, restores its own state, and not
# normally wanted mid-game. Anything NOT named here is never recommended, so an
# unrecognised process is left alone by default rather than guessed at.
$Recommend = @{
    'chrome'           = 'biggest commit consumer; restores tabs'
    'msedge'           = 'browser; restores tabs'
    'firefox'          = 'browser; restores tabs'
    'brave'            = 'browser; restores tabs'
    'opera'            = 'browser; restores tabs'
    'vivaldi'          = 'browser; restores tabs'
    'msedgewebview2'   = 'embedded browsers in other apps'
    'Code'             = 'VS Code; reopens with files intact'
    'Signal'           = 'chat; reconnects'
    'stremio-shell-ng' = 'media app'
    'stremio-runtime'  = 'media app backend'
    'vFlat Send to PC' = 'phone transfer helper'
    'SnippingTool'     = 'screenshot tool'
    'Taskmgr'          = 'Task Manager'
    'copilot-runtime'  = 'background assistant'
    'sqlservr'         = 'SQL Server; restart when you need it'
    'mongod'           = 'MongoDB; restart when you need it'
    'esrv'             = 'Intel energy telemetry helper'
    'NVIDIA App'       = 'driver UI; drivers unaffected'
}

# Deliberately NOT recommended, with the reason shown so the choice is yours.
$Caution = @{
    'claude'                 = 'ends our session'
    'Discord'                = 'you may want voice chat while playing'
    'steamwebhelper'         = 'Steam UI - needed to launch Steam games'
    'java'                   = 'could be a running server or Minecraft'
    'javaw'                  = 'could be a running server or Minecraft'
    'Vortex'                 = 'mod manager - may be mid-deploy'
    'AsusScreenXpertReunion' = 'closing may disable the ScreenPad'
    'Docker Desktop'         = 'stops your containers'
    'com.docker.backend'     = 'stops your containers'
}

# VR services, discovered rather than hardcoded, so this keeps working if the
# installed VR software changes.
function Get-VrServices {
    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match 'OVR|Oculus|VirtualDesktop' -or
            $_.DisplayName -match 'Oculus|Virtual Desktop|SteamVR|Vive'
        } |
        Where-Object { $_.Name -notmatch 'LibraryService' }   # on-demand, leave alone
}

function Get-VrProcesses {
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match '^(OVRServer_x64|OVRRedir|OVRServiceLauncher|VirtualDesktop\.Service|vrserver|vrmonitor|vrcompositor|vrdashboard)$' }
}

function Get-Commit {
    $s = (Get-Counter '\Memory\Committed Bytes','\Memory\Commit Limit' -ErrorAction SilentlyContinue).CounterSamples
    $c = ($s | Where-Object { $_.Path -match 'Committed' }).CookedValue
    $l = ($s | Where-Object { $_.Path -match 'Limit' }).CookedValue
    [pscustomobject]@{ UsedGB = $c/1GB; LimitGB = $l/1GB; Pct = if ($l) { $c/$l*100 } else { 0 } }
}

function Show-Commit {
    param([string]$Label)
    $c = Get-Commit
    $col = if ($c.Pct -ge 85) { 'Red' } elseif ($c.Pct -ge 70) { 'Yellow' } else { 'Green' }
    Write-Host ("  {0,-10} {1,5:N1} GB of {2,4:N1} GB committed  ({3,3:N0}%)" -f $Label, $c.UsedGB, $c.LimitGB, $c.Pct) -ForegroundColor $col
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

# --------------------------------------------------------------------- restore

if ($Restore) {
    Write-Host ''
    Write-Host '  Restoring' -ForegroundColor Cyan
    if (Test-Path $stateFile) {
        $st = Get-Content $stateFile -Raw | ConvertFrom-Json
        if ($st.PowerScheme) {
            & powercfg /setactive $st.PowerScheme 2>&1 | Out-Null
            Write-Host ('    power plan restored')
        }
        if ($st.VrWasRunning) {
            if (-not (Test-Admin)) {
                Write-Host '    VR services need elevation - re-run elevated to restart them' -ForegroundColor Yellow
            } else {
                foreach ($n in $st.VrServices) {
                    Start-Service -Name $n -ErrorAction SilentlyContinue
                    Write-Host ('    started {0}' -f $n)
                }
            }
        }
    } else {
        Write-Host '    no saved state - nothing to restore' -ForegroundColor DarkGray
    }
    Write-Host ''
    Show-Commit 'commit'
    Write-Host ''
    return
}

# ------------------------------------------------------------------ mode choice

if (-not $VR -and -not $Flat) {
    Write-Host ''
    Write-Host '  What kind of session?' -ForegroundColor Cyan
    Write-Host '    [1] VR      - start the VR stack (Oculus / Meta, Virtual Desktop, SteamVR)'
    Write-Host '    [2] Flat    - shut the VR stack down and reclaim what it uses'
    Write-Host ''
    $pick = Read-Host '  Choose 1 or 2'
    if     ($pick -eq '1') { $VR = $true }
    elseif ($pick -eq '2') { $Flat = $true }
    else { Write-Host '  Cancelled.' -ForegroundColor Yellow; return }
}

$mode = if ($VR) { 'VR' } else { 'FLAT' }
Write-Host ''
Write-Host ('  ===== GAMING MODE: {0} =====' -f $mode) -ForegroundColor Cyan
Write-Host ''
Show-Commit 'before'
Write-Host ''

# Remember what to put back later.
$state = @{
    PowerScheme  = ((powercfg /getactivescheme) -replace '.*GUID:\s*([0-9a-f-]+).*', '$1').Trim()
    VrWasRunning = [bool](@(Get-VrProcesses).Count)
    VrServices   = @(Get-VrServices | Where-Object { $_.State -eq 'Running' } | Select-Object -ExpandProperty Name)
    When         = (Get-Date).ToString('s')
}

# ------------------------------------------------------------------- VR stack

$vrSvc = @(Get-VrServices)
Write-Host '  VR stack' -ForegroundColor Cyan
if (-not $vrSvc) {
    Write-Host '    no VR software installed - nothing to start or stop' -ForegroundColor DarkGray
} else {
    foreach ($s in $vrSvc) {
        Write-Host ('    {0,-30} {1}' -f $s.DisplayName, $s.State)
    }
    $needAdmin = $false
    if ($VR) {
        $toStart = @($vrSvc | Where-Object { $_.State -ne 'Running' })
        if (-not $toStart) {
            Write-Host '    already running - nothing to start' -ForegroundColor Green
        } elseif ($WhatIf) {
            Write-Host ('    WOULD START: {0}' -f (($toStart | Select-Object -ExpandProperty Name) -join ', ')) -ForegroundColor Yellow
        } elseif (-not (Test-Admin)) { $needAdmin = $true }
        else {
            foreach ($s in $toStart) {
                try { Start-Service -Name $s.Name -ErrorAction Stop; Write-Host ('    started {0}' -f $s.Name) -ForegroundColor Green }
                catch { Write-Host ('    could not start {0}: {1}' -f $s.Name, $_.Exception.Message) -ForegroundColor Yellow }
            }
        }
    } else {
        $toStop = @($vrSvc | Where-Object { $_.State -eq 'Running' })
        if (-not $toStop) {
            Write-Host '    already stopped' -ForegroundColor Green
        } elseif ($WhatIf) {
            Write-Host ('    WOULD STOP: {0}' -f (($toStop | Select-Object -ExpandProperty Name) -join ', ')) -ForegroundColor Yellow
        } elseif (-not (Test-Admin)) { $needAdmin = $true }
        else {
            foreach ($s in $toStop) {
                try { Stop-Service -Name $s.Name -Force -ErrorAction Stop; Write-Host ('    stopped {0}' -f $s.Name) -ForegroundColor Green }
                catch { Write-Host ('    could not stop {0}: {1}' -f $s.Name, $_.Exception.Message) -ForegroundColor Yellow }
            }
            Get-VrProcesses | ForEach-Object {
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
    if ($needAdmin) {
        Write-Host '    SKIPPED - VR services need an elevated shell' -ForegroundColor Yellow
    }
}
Write-Host ''

# -------------------------------------------------------- heavy process picker

$cands = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $Protected -notcontains $_.ProcessName } |
    Group-Object ProcessName |
    ForEach-Object {
        [pscustomobject]@{
            Name     = $_.Name
            Count    = $_.Count
            CommitMB = [math]::Round((($_.Group | Measure-Object PrivateMemorySize64 -Sum).Sum) / 1MB)
            Ids      = @($_.Group | Select-Object -ExpandProperty Id)
        }
    } |
    Where-Object { $_.CommitMB -ge $MinimumMB } |
    Sort-Object CommitMB -Descending

if (-not $cands) {
    Write-Host '  Nothing above the size threshold is running.' -ForegroundColor Green
} else {
    $recMB = (($cands | Where-Object { $Recommend.ContainsKey($_.Name) } | Measure-Object CommitMB -Sum).Sum)
    if (-not $recMB) { $recMB = 0 }

    Write-Host ('  Heavy processes (over {0} MB). Pick what to close:' -f $MinimumMB) -ForegroundColor Cyan
    Write-Host ''
    Write-Host '      #   Process                  Inst   Commit   Note'
    Write-Host '    - --  -----------------------  ----  -------   ----------------------------------'
    for ($i = 0; $i -lt $cands.Count; $i++) {
        $c = $cands[$i]
        $isRec = $Recommend.ContainsKey($c.Name)
        if ($isRec)                            { $note = $Recommend[$c.Name]; $col = 'Green' }
        elseif ($Caution.ContainsKey($c.Name)) { $note = 'keep? ' + $Caution[$c.Name]; $col = 'Yellow' }
        else                                   { $note = ''; $col = 'Gray' }
        $mark = if ($isRec) { '*' } else { ' ' }
        $gb = if ($c.CommitMB -ge 1024) { '{0,5:N1} GB' -f ($c.CommitMB/1024) } else { '{0,5} MB' -f $c.CommitMB }
        Write-Host ('    {0} {1,2}  {2,-23}  {3,4}  {4}   {5}' -f $mark, ($i+1), $c.Name, $c.Count, $gb, $note) -ForegroundColor $col
    }
    # What each preset would actually free, given what is running right now.
    function Get-PresetSet {
        param([string[]]$KeepNames)
        @($cands | Where-Object {
            $Recommend.ContainsKey($_.Name) -and ($KeepNames -notcontains $_.Name)
        })
    }
    function Get-SetGB {
        param($Set)
        $s = ($Set | Measure-Object CommitMB -Sum).Sum
        if ($s) { $s / 1024 } else { 0 }
    }

    Write-Host ''
    Write-Host ('    * = recommended ({0} items, frees ~{1:N1} GB)' -f `
        @($cands | Where-Object { $Recommend.ContainsKey($_.Name) }).Count, ($recMB/1024)) -ForegroundColor Green
    Write-Host '    Unmarked items are left out of the presets on purpose.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '    Presets:' -ForegroundColor Cyan
    foreach ($key in @('r','b','w')) {
        $name = switch ($key) { 'r' { 'clean' } 'b' { 'browse' } 'w' { 'work' } }
        $set  = Get-PresetSet -KeepNames $Presets[$name].Keep
        Write-Host ('      [{0}]  {1,-7} {2,-34} frees ~{3,4:N1} GB' -f `
            $key, $name, $Presets[$name].Desc, (Get-SetGB $set))
    }
    Write-Host ''
    Write-Host '      [a]  everything listed        numbers, e.g. 1,3,4        Enter = nothing'
    Write-Host ''

    $sel = if ($Preset) { switch ($Preset) { 'clean' {'r'} 'browse' {'b'} 'work' {'w'} } }
           elseif ($Recommended) { 'r' }
           else { Read-Host '  Close' }

    $chosen = @()
    if     ($sel -eq 'a') { $chosen = $cands }
    elseif ($sel -eq 'r') { $chosen = Get-PresetSet -KeepNames $Presets['clean'].Keep }
    elseif ($sel -eq 'b') { $chosen = Get-PresetSet -KeepNames $Presets['browse'].Keep }
    elseif ($sel -eq 'w') { $chosen = Get-PresetSet -KeepNames $Presets['work'].Keep }
    elseif ($sel) {
        foreach ($tok in ($sel -split '[,\s]+')) {
            $n = 0
            if ([int]::TryParse($tok, [ref]$n) -and $n -ge 1 -and $n -le $cands.Count) {
                $chosen += $cands[$n - 1]
            }
        }
    }

    # -Keep spares named processes whatever the selection was.
    if ($Keep) {
        $spared  = @($chosen | Where-Object { $Keep -contains $_.Name } | Select-Object -ExpandProperty Name)
        $chosen  = @($chosen | Where-Object { $Keep -notcontains $_.Name })
        if ($spared) {
            Write-Host ('  keeping: {0}' -f ($spared -join ', ')) -ForegroundColor Cyan
        }
        # A name that matches nothing is almost always a typo or wrong casing -
        # say so rather than silently closing what the user meant to protect.
        $unmatched = @($Keep | Where-Object { $n = $_; -not ($cands | Where-Object { $_.Name -eq $n }) })
        if ($unmatched) {
            Write-Host ('  -Keep matched nothing for: {0}' -f ($unmatched -join ', ')) -ForegroundColor Yellow
            Write-Host '    (names must match the Process column exactly, e.g. chrome, Code, Discord)' -ForegroundColor DarkGray
        }
    }

    if (-not $chosen) {
        Write-Host '  Nothing selected.' -ForegroundColor DarkGray
    } else {
        Write-Host ''
        foreach ($c in $chosen) {
            if ($WhatIf) {
                Write-Host ('    WOULD CLOSE {0} ({1} proc, {2} MB)' -f $c.Name, $c.Count, $c.CommitMB) -ForegroundColor Yellow
                continue
            }
            # Ask politely first so apps can save; force only what ignores it.
            foreach ($procId in $c.Ids) {
                $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
                if ($p) { try { [void]$p.CloseMainWindow() } catch { } }
            }
            Start-Sleep -Milliseconds 1500
            $left = @($c.Ids | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
            if ($left) {
                Start-Sleep -Seconds 2
                $left = @($c.Ids | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
                foreach ($p in $left) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
            }
            $still = @($c.Ids | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count
            if ($still -eq 0) { Write-Host ('    closed  {0,-22} freed ~{1} MB' -f $c.Name, $c.CommitMB) -ForegroundColor Green }
            else { Write-Host ('    {0}: {1} process(es) would not close' -f $c.Name, $still) -ForegroundColor Yellow }
        }
    }
}

# ---------------------------------------------------------------- power plan

if ($PowerPlan -and -not $WhatIf) {
    Write-Host ''
    # No High Performance scheme exists here by default; derive one from the
    # built-in template if needed.
    $hp = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    $have = (powercfg /list) -match $hp
    if (-not $have) {
        & powercfg -duplicatescheme $hp 2>&1 | Out-Null
    }
    & powercfg /setactive $hp 2>&1 | Out-Null
    $now = (powercfg /getactivescheme)
    Write-Host ('  power plan: {0}' -f ($now -replace '^.*\(', '(')) -ForegroundColor Green
    Write-Host '  (note: this CPU sits at base clock from power/thermal limits, not the plan)' -ForegroundColor DarkGray
}

# -------------------------------------------------------------------- summary

if (-not $WhatIf) {
    New-Item -ItemType Directory -Path (Split-Path $stateFile) -Force | Out-Null
    $state | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding utf8
}

Write-Host ''
Show-Commit 'after'
$c = Get-Commit
$head = $c.LimitGB - $c.UsedGB
Write-Host ('  {0,-10} {1,5:N1} GB of headroom' -f 'free', $head) -ForegroundColor $(if ($head -lt 10) { 'Yellow' } else { 'Green' })
if ($head -lt 12) {
    Write-Host ''
    Write-Host '  WARNING: a demanding game can commit 10 GB or more on its own. With' -ForegroundColor Yellow
    Write-Host '           under 12 GB free, running out of commit can crash the desktop (dwm).' -ForegroundColor Yellow
}
Write-Host ''
Write-Host '  Afterwards:  .\gaming-mode.ps1 -Restore' -ForegroundColor DarkGray
Write-Host ''
