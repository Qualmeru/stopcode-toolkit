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
        .\gaming-mode.ps1 -Game witcher3       target a game: sets VR/flat, checks
                                               its GPU pinning and headroom need
        .\gaming-mode.ps1 -Game alyx -Launch   prepare, check, then start it
        .\gaming-mode.ps1 -Games               list the games it can see
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
    [string]$Game,
    [switch]$Games,
    [switch]$Launch,
    [switch]$PinGpu,
    [switch]$NoPreflight,
    [int]$MinimumMB = 150
)

# --------------------------------------------------------------- game profiles
# Steam libraries are read from libraryfolders.vdf rather than hardcoded, since
# games are often spread over several drives. Steam's own install folder comes
# from the registry, with the usual locations as a fallback.
function Get-SteamLibraries {
    $libs = @()
    $roots = @()
    foreach ($k in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
        foreach ($v in @($p.SteamPath, $p.InstallPath)) { if ($v) { $roots += ($v -replace '/', '\') } }
    }
    $roots += @('C:\Games\Steam', 'C:\Program Files (x86)\Games\Steam',
                'C:\Program Files (x86)\Steam', "$env:ProgramFiles\Steam")
    foreach ($root in @($roots | Select-Object -Unique)) {
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (-not (Test-Path $vdf)) { continue }
        $libs += $root
        foreach ($line in (Get-Content $vdf -ErrorAction SilentlyContinue)) {
            if ($line -match '"path"\s+"([^"]+)"') {
                $libs += ($matches[1] -replace '\\\\', '\')
            }
        }
    }
    return @($libs | Select-Object -Unique | Where-Object { Test-Path $_ })
}

# CommitGB: only Witcher 3 is a measured figure (observed at ~10 GB during an
# exhaustion event). The rest are rough classes, flagged as estimates, because
# guessing precisely would be worse than admitting the uncertainty.
$GameProfiles = @(
    [pscustomobject]@{ Key='witcher3'; Name='The Witcher 3';     Folder='The Witcher 3';   Exe='bin\x64_dx12\witcher3.exe';     VR=$false; CommitGB=10; Measured=$true  }
    [pscustomobject]@{ Key='alyx';     Name='Half-Life: Alyx';   Folder='Half-Life Alyx';  Exe='game\bin\win64\hlvr.exe';       VR=$true;  CommitGB=8;  Measured=$false }
    [pscustomobject]@{ Key='cyberpunk';Name='Cyberpunk 2077';    Folder='Cyberpunk 2077';  Exe='bin\x64\Cyberpunk2077.exe';     VR=$false; CommitGB=9;  Measured=$false }
    [pscustomobject]@{ Key='skyrim';   Name='Skyrim SE';         Folder='Skyrim Special Edition'; Exe='SkyrimSE.exe';           VR=$false; CommitGB=5;  Measured=$false }
    [pscustomobject]@{ Key='pragmata'; Name='PRAGMATA';          Folder='PRAGMATA';        Exe=$null;                           VR=$false; CommitGB=8;  Measured=$false }
    [pscustomobject]@{ Key='winds';    Name='Where Winds Meet';  Folder='Where Winds Meet';Exe=$null;                           VR=$false; CommitGB=8;  Measured=$false }
    [pscustomobject]@{ Key='outerwilds';Name='Outer Wilds';      Folder='Outer Wilds';     Exe='OuterWilds.exe';                VR=$false; CommitGB=3;  Measured=$false }
    [pscustomobject]@{ Key='stray';    Name='Stray';             Folder='Stray';           Exe=$null;                           VR=$false; CommitGB=4;  Measured=$false }
    [pscustomobject]@{ Key='falloutnv';Name='Fallout: New Vegas';Folder='Fallout New Vegas';Exe=$null;                          VR=$false; CommitGB=2;  Measured=$false }
)

function Resolve-GameProfile {
    param($Profile, [string[]]$Libraries)
    foreach ($lib in $Libraries) {
        $dir = Join-Path $lib ('steamapps\common\' + $Profile.Folder)
        if (-not (Test-Path $dir)) { continue }
        $exe = $null
        if ($Profile.Exe) {
            $cand = Join-Path $dir $Profile.Exe
            if (Test-Path $cand) { $exe = $cand }
        }
        if (-not $exe) {
            # Fall back to the largest executable in the folder tree, which is
            # almost always the game rather than a launcher or crash handler.
            $exe = Get-ChildItem $dir -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue -Depth 4 |
                   Where-Object { $_.Name -notmatch 'unins|crash|redist|vcredist|launcher|setup|helper' } |
                   Sort-Object Length -Descending | Select-Object -First 1 -ExpandProperty FullName
        }
        return [pscustomobject]@{
            Key = $Profile.Key; Name = $Profile.Name; Dir = $dir; Exe = $exe
            VR = $Profile.VR; CommitGB = $Profile.CommitGB; Measured = $Profile.Measured
        }
    }
    return $null
}

function Get-InstalledGames {
    $libs = Get-SteamLibraries
    $out = @()
    foreach ($p in $GameProfiles) {
        $r = Resolve-GameProfile -Profile $p -Libraries $libs
        if ($r) { $out += $r }
    }
    return $out
}

if ($Games) {
    Write-Host ''
    Write-Host '  Games this script can see' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '    key          game                   type   needs    exe found'
    Write-Host '    -----------  ---------------------  -----  -------  ---------'
    foreach ($g in (Get-InstalledGames)) {
        $need = '{0} GB{1}' -f $g.CommitGB, $(if ($g.Measured) { '*' } else { '' })
        Write-Host ('    {0,-11}  {1,-21}  {2,-5}  {3,-7}  {4}' -f `
            $g.Key, $g.Name, $(if ($g.VR) { 'VR' } else { 'flat' }), $need,
            $(if ($g.Exe) { 'yes' } else { 'no' }))
    }
    Write-Host ''
    Write-Host '    * measured. Others are estimates - treat them as rough.' -ForegroundColor DarkGray
    Write-Host ''
    return
}

# Keep-presets: start from the recommended set, then spare the named processes.
# Browsers and work apps are usually the biggest things the recommended set
# frees, so they are the ones worth a dedicated preset.
$Browsers = @('chrome','msedge','firefox','brave','opera','vivaldi')
# Apps you work in, kept open by the Work preset: editors and IDEs, AI
# assistants, databases and their tools, and chat/mail.
$WorkApps = @(
    'Code','devenv','Ssms','copilot-runtime','copilot-language-server','Copilot',
    'sqlservr','mongod','postgres','mysqld','redis-server',
    'idea64','rider64','pycharm64','webstorm64','datagrip64','clion64','goland64','jetbrains-toolbox',
    'Slack','ms-teams','Teams','OUTLOOK','olk','Notepad++',
    'msedgewebview2'   # Teams, new Outlook and Copilot draw their windows with it
)
$Presets = @{
    'clean'  = @{ Keep = @();                       Desc = 'close everything recommended' }
    'browse' = @{ Keep = $Browsers;                 Desc = 'keep web browsers for looking things up' }
    'work'   = @{ Keep = $Browsers + $WorkApps;     Desc = 'keep browsers and work apps (Code, Copilot, SQL...)' }
}

$stateFile = Join-Path $PSScriptRoot 'diag\gaming-mode-state.json'

# powershell.exe -File passes every argument as a plain string, so
# "-Keep chrome,Discord" arrives as ONE element containing a comma rather than
# two. Split it here so both invocation styles behave the same.
if ($Keep) {
    $Keep = @($Keep -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# ------------------------------------------------------- stubborn processes
# Three different reasons something "will not close", each needing a different
# answer:
#   1. it is a Windows service      -> Stop-Process cannot touch it; stop the service
#   2. it respawns instantly        -> killing it achieves nothing
#   3. it did close, just slowly    -> the old check simply looked too early
# Names that genuinely refuse are remembered here and skipped next time.
$wontCloseFile = Join-Path $PSScriptRoot 'diag\wont-close.txt'

function Get-WontClose {
    if (Test-Path $wontCloseFile) {
        return @(Get-Content $wontCloseFile -ErrorAction SilentlyContinue |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    return @()
}

function Add-WontClose {
    param([string]$Name)
    $all = @(Get-WontClose) + $Name | Select-Object -Unique
    New-Item -ItemType Directory -Path (Split-Path $wontCloseFile) -Force | Out-Null
    Set-Content -LiteralPath $wontCloseFile -Value $all -Encoding utf8
}

# Map process id -> service name, so service-backed processes can be identified
# before anything pointless is attempted on them.
function Get-ServiceProcessMap {
    $m = @{}
    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -gt 0 } |
        ForEach-Object { $m[[int]$_.ProcessId] = $_.Name }
    return $m
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

# ----------------------------------------------------------------- pre-flight
# Every check here corresponds to something that has actually gone wrong on this
# machine, rather than generic advice.

function Write-Check {
    param([string]$State, [string]$What, [string]$Detail)
    $mark, $col = switch ($State) {
        'ok'   { '  ok  ', 'Green' }
        'warn' { ' warn ', 'Yellow' }
        'fail' { ' FAIL ', 'Red' }
        default { '  --  ', 'DarkGray' }
    }
    Write-Host ('   [' + $mark + '] ') -NoNewline -ForegroundColor $col
    Write-Host ('{0,-26} {1}' -f $What, $Detail)
}

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

function Invoke-PreFlight {
    param($Target, [bool]$WantVr)

    Write-Host ''
    Write-Host '  Pre-flight' -ForegroundColor Cyan
    $problems = 0

    # Is the target already running? If so its memory is already committed, and
    # demanding headroom for it a second time is simply wrong.
    $running = $null
    if ($Target -and $Target.Exe) {
        $leaf = [System.IO.Path]::GetFileNameWithoutExtension($Target.Exe)
        $running = Get-Process -Name $leaf -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    # 1. Commit headroom against what the game actually needs.
    $c = Get-Commit
    $head = $c.LimitGB - $c.UsedGB
    if ($Target -and $running) {
        $used = [math]::Round($running.PrivateMemorySize64 / 1GB, 1)
        if ($head -ge 4) {
            Write-Check 'ok' 'commit headroom' ('{0} already running on {1:N1} GB; {2:N1} GB still free' -f $Target.Name, $used, $head)
        } else {
            Write-Check 'warn' 'commit headroom' ('{0} is running but only {1:N1} GB is left - close something' -f $Target.Name, $head)
            $problems++
        }
    } elseif ($Target) {
        $need = $Target.CommitGB
        $margin = $head - $need
        if ($margin -ge 4) {
            Write-Check 'ok' 'commit headroom' ('{0:N1} GB free, {1} needs ~{2} GB' -f $head, $Target.Name, $need)
        } elseif ($margin -ge 0) {
            Write-Check 'warn' 'commit headroom' ('{0:N1} GB free, {1} needs ~{2} GB - only {3:N1} GB spare' -f $head, $Target.Name, $need, $margin)
            $problems++
        } else {
            Write-Check 'fail' 'commit headroom' ('{0:N1} GB free but {1} needs ~{2} GB - close more' -f $head, $Target.Name, $need)
            $problems++
        }
    } else {
        $state = if ($head -ge 14) { 'ok' } elseif ($head -ge 10) { 'warn' } else { 'fail' }
        Write-Check $state 'commit headroom' ('{0:N1} GB free of {1:N1} GB' -f $head, $c.LimitGB)
        if ($state -ne 'ok') { $problems++ }
    }

    # 2. Is the game pinned to the discrete GPU? Witcher 3 was not, and Chrome
    #    silently ran on the integrated GPU for weeks for the same reason.
    if ($Target -and $Target.Exe) {
        # Check the path that is actually running where possible: the profile's
        # resolved path can differ from it (a different build, or a fallback
        # guess), and that difference previously showed up as a bare "not set"
        # with no way to tell which path had been looked at.
        $checkPath = $Target.Exe
        if ($running -and $running.Path -and $running.Path -ne $Target.Exe) {
            $checkPath = $running.Path
        }
        $k = 'HKCU:\SOFTWARE\Microsoft\DirectX\UserGpuPreferences'
        $props = Get-ItemProperty $k -ErrorAction SilentlyContinue
        $pref = $null
        if ($props) { $pref = ($props.PSObject.Properties | Where-Object { $_.Name -eq $checkPath }).Value }

        if ($pref -match 'GpuPreference=2') {
            Write-Check 'ok' 'GPU preference' 'pinned to the discrete GPU'
        } elseif ($pref) {
            Write-Check 'warn' 'GPU preference' ('set to "{0}" - not high performance' -f $pref)
            $problems++
        } else {
            Write-Check 'warn' 'GPU preference' 'not set for the executable checked'
            Write-Host ('           checked: {0}' -f $checkPath) -ForegroundColor DarkGray
            Write-Host ('           fix:     .\gaming-mode.ps1 -Game {0} -PinGpu' -f $Target.Key) -ForegroundColor DarkGray
            $problems++
        }

        # The preference only decides what Windows hands out at launch; if the
        # game is already running, say where it actually ended up.
        if ($running) {
            try {
                $map = Get-AdapterMap
                $onNv = $false; $onIntel = $false
                (Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue).CounterSamples |
                    Where-Object { $_.CookedValue -gt 1 -and $_.InstanceName -match ('pid_' + $running.Id + '_') } |
                    ForEach-Object {
                        if ($_.InstanceName -match 'luid_0x[0-9a-f]+_(0x[0-9a-f]+)_') {
                            $ad = if ($map.ContainsKey($matches[1])) { $map[$matches[1]] } else { '' }
                            if ($ad -match 'NVIDIA') { $onNv = $true } elseif ($ad -match 'Intel') { $onIntel = $true }
                        }
                    }
                if ($onNv)        { Write-Check 'ok'   'running on' 'the discrete GPU, measured' }
                elseif ($onIntel) { Write-Check 'fail' 'running on' 'the integrated GPU - restart it after pinning'; $problems++ }
            } catch { }
        }
    }

    # 3. VR stack state should match the kind of session.
    $vrRunning = [bool](@(Get-VrProcesses).Count)
    if ($WantVr -and $vrRunning)        { Write-Check 'ok'   'VR stack' 'running, as needed' }
    elseif ($WantVr -and -not $vrRunning){ Write-Check 'warn' 'VR stack' 'not running yet - Apply will start it' }
    elseif (-not $WantVr -and $vrRunning){ Write-Check 'warn' 'VR stack' 'still running for a flat game - wasting CPU'; $problems++ }
    else                                 { Write-Check 'ok'   'VR stack' 'stopped, as it should be' }

    # 4. Anything driving Intel's video engine - the block igdkmd64.sys times
    #    out in, and the cause of the 0x141 faults.
    try {
        $map = Get-AdapterMap
        $busy = @()
        (Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue).CounterSamples |
            Where-Object { $_.CookedValue -gt 1 -and $_.InstanceName -match 'videodecode|videoencode|videoprocessing' } |
            ForEach-Object {
                if ($_.InstanceName -match 'pid_(\d+)_luid_0x[0-9a-f]+_(0x[0-9a-f]+)_') {
                    $ad = if ($map.ContainsKey($matches[2])) { $map[$matches[2]] } else { '' }
                    if ($ad -match 'Intel') {
                        $pr = Get-Process -Id $matches[1] -ErrorAction SilentlyContinue
                        if ($pr) { $busy += $pr.ProcessName }
                    }
                }
            }
        $busy = @($busy | Select-Object -Unique)
        if ($busy) {
            Write-Check 'warn' 'Intel video engine' ('in use by {0} - this is where 0x141 faults happen' -f ($busy -join ', '))
            $problems++
        } else {
            Write-Check 'ok' 'Intel video engine' 'idle'
        }
    } catch { }

    # 5. Disk space on the drive the game lives on.
    if ($Target -and $Target.Dir) {
        $drv = Get-PSDrive -Name ($Target.Dir.Substring(0,1)) -ErrorAction SilentlyContinue
        if ($drv) {
            $free = $drv.Free / 1GB
            $state = if ($free -ge 20) { 'ok' } elseif ($free -ge 8) { 'warn' } else { 'fail' }
            Write-Check $state 'disk space' ('{0:N0} GB free on {1}:' -f $free, $drv.Name)
            if ($state -eq 'fail') { $problems++ }
        }
    }

    Write-Host ''
    if ($problems -eq 0) { Write-Host '   Nothing to flag.' -ForegroundColor Green }
    else { Write-Host ("   {0} thing(s) worth a look above." -f $problems) -ForegroundColor Yellow }
    Write-Host ''
    return $problems
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

# A named game decides VR vs flat on its own, so the prompt is skipped.
$Target = $null
if ($Game) {
    $Target = Get-InstalledGames | Where-Object { $_.Key -eq $Game -or $_.Name -like "*$Game*" } | Select-Object -First 1
    if (-not $Target) {
        Write-Host ''
        Write-Host ("  No installed game matches '{0}'. Run -Games to list them." -f $Game) -ForegroundColor Yellow
        Write-Host ''
        return
    }
    if ($Target.VR) { $VR = $true; $Flat = $false } else { $Flat = $true; $VR = $false }
    Write-Host ''
    Write-Host ('  Target: {0}  ({1} session, needs ~{2} GB{3})' -f `
        $Target.Name, $(if ($Target.VR) { 'VR' } else { 'flat' }), $Target.CommitGB,
        $(if ($Target.Measured) { ', measured' } else { ', estimated' })) -ForegroundColor Cyan
}

# -PinGpu sets the per-app preference the pre-flight check looks for.
if ($PinGpu) {
    if (-not $Target -or -not $Target.Exe) {
        Write-Host '  -PinGpu needs -Game with a resolvable executable.' -ForegroundColor Yellow
        return
    }
    $k = 'HKCU:\SOFTWARE\Microsoft\DirectX\UserGpuPreferences'
    if (-not (Test-Path $k)) {
        # Note: New-Item -Force on an existing registry key DELETES its values,
        # so only create it when it genuinely does not exist.
        New-Item -Path $k -Force | Out-Null
    }
    Set-ItemProperty -Path $k -Name $Target.Exe -Value 'GpuPreference=2;' -Type String
    Write-Host ('  pinned {0} to the discrete GPU' -f $Target.Name) -ForegroundColor Green
    Write-Host ('    {0}' -f $Target.Exe) -ForegroundColor DarkGray
    Write-Host ''
    return
}

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
    # Anything that has proved it will not close is shown but never auto-ticked,
    # so presets stop wasting time on it.
    $stubborn = @(Get-WontClose)
    $svcMapUi = Get-ServiceProcessMap
    foreach ($c in $cands) {
        $isSvc = @($c.Ids | Where-Object { $svcMapUi.ContainsKey($_) }).Count -gt 0
        Add-Member -InputObject $c -NotePropertyName Stubborn -NotePropertyValue ($stubborn -contains $c.Name) -Force
        Add-Member -InputObject $c -NotePropertyName IsService -NotePropertyValue $isSvc -Force
    }

    $recMB = (($cands | Where-Object { $Recommend.ContainsKey($_.Name) -and -not $_.Stubborn } | Measure-Object CommitMB -Sum).Sum)
    if (-not $recMB) { $recMB = 0 }

    Write-Host ('  Heavy processes (over {0} MB). Pick what to close:' -f $MinimumMB) -ForegroundColor Cyan
    Write-Host ''
    Write-Host '      #   Process                  Inst   Commit   Note'
    Write-Host '    - --  -----------------------  ----  -------   ----------------------------------'
    for ($i = 0; $i -lt $cands.Count; $i++) {
        $c = $cands[$i]
        $isRec = $Recommend.ContainsKey($c.Name) -and -not $c.Stubborn
        if ($c.Stubborn)                       { $note = 'skipped - would not close before'; $col = 'DarkGray' }
        elseif ($c.IsService)                  { $note = 'service - needs an elevated run to stop'; $col = 'DarkCyan' }
        elseif ($isRec)                        { $note = $Recommend[$c.Name]; $col = 'Green' }
        elseif ($Caution.ContainsKey($c.Name)) { $note = 'keep? ' + $Caution[$c.Name]; $col = 'Yellow' }
        else                                   { $note = ''; $col = 'Gray' }
        $mark = if ($isRec) { '*' } elseif ($c.Stubborn) { 'x' } else { ' ' }
        $gb = if ($c.CommitMB -ge 1024) { '{0,5:N1} GB' -f ($c.CommitMB/1024) } else { '{0,5} MB' -f $c.CommitMB }
        Write-Host ('    {0} {1,2}  {2,-23}  {3,4}  {4}   {5}' -f $mark, ($i+1), $c.Name, $c.Count, $gb, $note) -ForegroundColor $col
    }
    # What each preset would actually free, given what is running right now.
    function Get-PresetSet {
        param([string[]]$KeepNames)
        @($cands | Where-Object {
            $Recommend.ContainsKey($_.Name) -and
            ($KeepNames -notcontains $_.Name) -and
            -not $_.Stubborn
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
        $svcMap = Get-ServiceProcessMap
        $admin  = Test-Admin

        foreach ($c in $chosen) {
            if ($WhatIf) {
                Write-Host ('    WOULD CLOSE {0} ({1} proc, {2} MB)' -f $c.Name, $c.Count, $c.CommitMB) -ForegroundColor Yellow
                continue
            }

            # Service-backed: Stop-Process is the wrong tool and will just fail.
            $svcNames = @($c.Ids | Where-Object { $svcMap.ContainsKey($_) } | ForEach-Object { $svcMap[$_] } | Select-Object -Unique)
            if ($svcNames) {
                if (-not $admin) {
                    Write-Host ('    skipped {0,-22} is a service ({1}) - needs an elevated run' -f $c.Name, ($svcNames -join ', ')) -ForegroundColor Yellow
                    continue
                }
                foreach ($s in $svcNames) {
                    try {
                        Stop-Service -Name $s -Force -ErrorAction Stop
                        Write-Host ('    stopped {0,-22} service {1}, freed ~{2} MB' -f $c.Name, $s, $c.CommitMB) -ForegroundColor Green
                    } catch {
                        Write-Host ('    {0}: could not stop service {1}' -f $c.Name, $s) -ForegroundColor Yellow
                        Add-WontClose $c.Name
                    }
                }
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

            # Give Windows a moment to actually reap them. The previous version
            # counted immediately and reported failures for apps that were in
            # fact closing - Signal and the Snipping Tool among them.
            Start-Sleep -Milliseconds 900
            $still = @($c.Ids | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count

            if ($still -eq 0) {
                Write-Host ('    closed  {0,-22} freed ~{1} MB' -f $c.Name, $c.CommitMB) -ForegroundColor Green
                continue
            }

            # Still there: either it is being respawned by a parent, or it is
            # protected. Either way, stop trying on future runs.
            $respawned = @(Get-Process -Name $c.Name -ErrorAction SilentlyContinue).Count
            if ($respawned -gt 0) {
                Write-Host ('    {0}: respawns immediately - skipping it from now on' -f $c.Name) -ForegroundColor Yellow
            } else {
                Write-Host ('    {0}: {1} process(es) refused to close' -f $c.Name, $still) -ForegroundColor Yellow
            }
            Add-WontClose $c.Name
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

# The pre-flight only reads, so it runs under -WhatIf too - that is the mode
# you want when checking whether a session is ready without changing anything.
if (-not $NoPreflight) {
    $issues = Invoke-PreFlight -Target $Target -WantVr ([bool]$VR)
} else {
    $issues = 0
}

if (-not $Target -and $head -lt 12) {
    Write-Host '  WARNING: a demanding game can commit 10 GB or more on its own. With' -ForegroundColor Yellow
    Write-Host '           under 12 GB free, running out of commit can crash the desktop (dwm).' -ForegroundColor Yellow
    Write-Host ''
}

if ($Launch -and $Target -and -not $WhatIf) {
    if (-not $Target.Exe) {
        Write-Host '  Cannot launch: no executable resolved for this game.' -ForegroundColor Yellow
    } else {
        if ($issues -gt 0) {
            Write-Host ('  {0} pre-flight item(s) flagged above.' -f $issues) -ForegroundColor Yellow
            $go = Read-Host '  Launch anyway? [y/N]'
            if ($go -notmatch '^\s*(y|yes)\s*$') { Write-Host '  Not launched.' -ForegroundColor Yellow; return }
        }
        Write-Host ('  Launching {0}...' -f $Target.Name) -ForegroundColor Green
        try { Start-Process -FilePath $Target.Exe -WorkingDirectory (Split-Path $Target.Exe) }
        catch { Write-Host ('  Launch failed: {0}' -f $_.Exception.Message) -ForegroundColor Red }
    }
    Write-Host ''
}

Write-Host '  Afterwards:  .\gaming-mode.ps1 -Restore' -ForegroundColor DarkGray
Write-Host ''
