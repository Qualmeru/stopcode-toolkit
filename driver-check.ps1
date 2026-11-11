<#
    driver-check.ps1 - see which driver updates Windows is offering, compare them
    against what is installed, and pick which to take.

    Uses the Windows Update Agent API, so everything comes from Microsoft's own
    catalogue and is WHQL-signed. This deliberately does NOT fetch installers
    from vendor sites: for NVIDIA and Intel graphics, use their own apps, which
    this script points you at instead.

    Nothing is installed unless you choose it. The default is a read-only scan.

    Usage:
        .\driver-check.ps1              scan and compare, change nothing
        .\driver-check.ps1 -Install     scan, then pick what to install (admin)
        .\driver-check.ps1 -Install -Select 1,3    non-interactive pick
        .\driver-check.ps1 -Inventory   list installed drivers by age
        .\driver-check.ps1 -SkipOnline  cached list only, no online check

    The scan shows Windows' cached list at once, then checks online (about a
    minute) with a counter, and reprints only if the online check changed it.
#>

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Inventory,
    [int[]]$Select,
    [int]$AgeYears = 3,
    [switch]$SkipOnline     # use only Windows' cached list (set on the elevated relaunch, which follows an online check)
)

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Write-Rule { param([int]$W = 78) Write-Host ('  ' + ('-' * $W)) -ForegroundColor DarkGray }

# Installed drivers, read once, for comparing against what is offered.
$installed = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
    Where-Object { $_.DeviceName } |
    Select-Object DeviceName, DriverVersion, DriverDate, DriverProviderName, DeviceClass)

function Find-Installed {
    param([string]$Model)
    # Match on the device model only. Falling back to manufacturer matched the
    # wrong device and reported a version that had nothing to do with the
    # update - worse than admitting no match was found.
    if (-not $Model) { return $null }
    $hit = $installed | Where-Object { $_.DeviceName -eq $Model } | Select-Object -First 1
    if ($hit) { return $hit }
    return ($installed |
        Where-Object { $_.DeviceName -like "*$Model*" -or $Model -like ('*' + $_.DeviceName + '*') } |
        Select-Object -First 1)
}

function Get-OfferedVersion {
    # The API usually leaves DriverVerVersion empty; the version is in the title.
    param($Update)
    $v = ''
    try { $v = $Update.DriverVerVersion } catch { }
    if (-not $v -and $Update.Title -match '\(([\d]+(?:\.[\d]+){1,3})\)') { $v = $matches[1] }
    return $v
}

function Compare-Version {
    param([string]$Offered, [string]$Current)
    if (-not $Offered -or -not $Current) { return 'unknown' }
    try {
        $o = [version]$Offered; $c = [version]$Current
        if ($o -gt $c) { return 'newer' }
        if ($o -lt $c) { return 'OLDER' }
        return 'same'
    } catch { return 'unknown' }
}

# ------------------------------------------------------------------ inventory

if ($Inventory) {
    Write-Host ''
    Write-Host '  Installed third-party drivers, oldest first' -ForegroundColor Cyan
    Write-Rule
    # Some vendors (Intel chipset INFs especially) stamp drivers 1968-07-18 on
    # purpose so Windows never prefers them over a real driver. That is a
    # placeholder, not an age, so leave those out rather than list them as oldest.
    $third = @($installed | Where-Object { $_.DriverProviderName -notmatch 'Microsoft' -and $_.DriverDate })
    $placeholder = @($third | Where-Object { $_.DriverDate.Year -lt 1990 })
    $third |
        Where-Object { $_.DriverDate.Year -ge 1990 } |
        Sort-Object DriverDate |
        Select-Object -First 25 |
        ForEach-Object {
            $age = ((Get-Date) - $_.DriverDate).Days / 365.25
            $col = if ($age -ge $AgeYears) { 'Yellow' } else { 'Gray' }
            Write-Host ('  {0}  {1,-42} {2,-16} {3}' -f `
                $_.DriverDate.ToString('yyyy-MM-dd'),
                ($_.DeviceName -replace '\s+', ' ').PadRight(42).Substring(0,42),
                $_.DriverVersion, $_.DriverProviderName) -ForegroundColor $col
        }
    Write-Host ''
    Write-Host ('  Yellow entries are over {0} years old. Age alone is not a problem:' -f $AgeYears) -ForegroundColor DarkGray
    Write-Host '  many devices simply never get new drivers.' -ForegroundColor DarkGray
    if ($placeholder.Count) {
        Write-Host ('  Not listed: {0} driver(s) dated before 1990 - a deliberate placeholder' -f $placeholder.Count) -ForegroundColor DarkGray
        Write-Host '  date some vendors use (Intel chipset files, for example), not a real age.' -ForegroundColor DarkGray
    }
    Write-Host ''
    return
}

# ---------------------------------------------------------------------- scan

$criteria = "IsInstalled=0 AND Type='Driver'"
$session  = New-Object -ComObject Microsoft.Update.Session

# Search Windows' local copy of the update catalogue. Takes a second or two;
# the online search below refreshes that copy.
function Get-CachedResult {
    $s = $session.CreateUpdateSearcher()
    $s.Online = $false
    return $s.Search($criteria)
}

# The installed BIOS version (e.g. 1.19), for judging system firmware updates.
$script:BiosVersion = ''; $script:BiosText = ''
try {
    $b = Get-CimInstance Win32_BIOS -ErrorAction Stop
    if ($null -ne $b.SystemBiosMajorVersion -and $b.SystemBiosMajorVersion -lt 255) {
        $script:BiosVersion = '{0}.{1}' -f $b.SystemBiosMajorVersion, $b.SystemBiosMinorVersion
    }
    $script:BiosText = (($b.SMBIOSBIOSVersion -replace '\s+', ' ') -replace '\(\s*(.*?)\s*\)', '($1)').Trim()
} catch { }

function Get-Offers {
    param($Result)
    $list = @()
    $i = 0
    foreach ($u in $Result.Updates) {
        $i++
        $model = ''; $mfr = ''; $vdate = $null
        try { $model = $u.DriverModel } catch { }
        try { $mfr   = $u.DriverManufacturer } catch { }
        try { $vdate = $u.DriverVerDate } catch { }
        $class = ''
        try { $class = $u.DriverClass } catch { }
        $offered = Get-OfferedVersion $u
        $curVer = ''; $curDate = $null; $note = ''

        if ($class -eq 'Firmware') {
            # Firmware devices all show Microsoft's generic firmware driver
            # (10.0.x), which says nothing about the firmware itself. For the
            # system firmware the real figure is the BIOS version; other
            # firmware (docks, controllers) cannot be compared from here.
            if ($model -match 'System Firmware' -and $script:BiosVersion) {
                $curVer  = $script:BiosVersion
                $short   = ($offered -split '\.')[0..1] -join '.'   # 1.19.0.0 -> 1.19
                $verdict = Compare-Version -Offered $short -Current $curVer
                $note    = 'BIOS / UEFI firmware update - compared with the installed BIOS ({0})' -f $script:BiosText
            } else {
                $verdict = 'unknown'
                $note    = 'device firmware - Windows does not expose its installed version, judge by the title'
            }
        } else {
            $cur = Find-Installed -Model $model
            $curVer  = if ($cur) { $cur.DriverVersion } else { '' }
            $curDate = if ($cur) { $cur.DriverDate } else { $null }
            $verdict = Compare-Version -Offered $offered -Current $curVer
        }

        $list += [pscustomobject]@{
            Index     = $i
            Update    = $u
            Id        = $u.Identity.UpdateID
            Title     = $u.Title
            Model     = $model
            Mfr       = $mfr
            Offered   = $offered
            OfferDate = $vdate
            Current   = $curVer
            CurDate   = $curDate
            Verdict   = $verdict
            Note      = $note
            SizeMB    = [math]::Round($u.MaxDownloadSize / 1MB, 1)
        }
    }
    return ,$list
}

function Show-Offers {
    param($List, [string]$Source)
    Write-Host ''
    Write-Host ('  {0} driver update(s) offered by Windows Update  ({1})' -f $List.Count, $Source) -ForegroundColor Cyan
    Write-Host ''
    if (-not $List.Count) {
        Write-Host '  Nothing offered. Note that Windows Update does not carry NVIDIA' -ForegroundColor DarkGray
        Write-Host '  Game Ready drivers or Intel graphics releases - use their own apps.' -ForegroundColor DarkGray
        Write-Host ''
        return
    }
    Write-Host '    #   Device                                    Offered      Installed    Size'
    Write-Rule
    foreach ($o in $List) {
        $col = switch ($o.Verdict) {
            'OLDER'   { 'Red' }
            'newer'   { 'Green' }
            'same'    { 'DarkGray' }
            default   { 'Gray' }
        }
        $name = if ($o.Model) { $o.Model } else { $o.Title }
        if ($name.Length -gt 40) { $name = $name.Substring(0, 39) + '.' }
        Write-Host ('   {0,2}   {1,-40}  {2,-11}  {3,-11}  {4,5} MB' -f `
            $o.Index, $name,
            $(if ($o.Offered) { $o.Offered } else { '-' }),
            $(if ($o.Current) { $o.Current } else { 'not found' }),
            $o.SizeMB) -ForegroundColor $col
        $note = switch ($o.Verdict) {
            'OLDER'   { 'DOWNGRADE - the installed driver is newer than this. Skip it.' }
            'newer'   { 'newer than installed' }
            'same'    { 'same version already installed' }
            default   { 'could not match to an installed device - judge by the title' }
        }
        if ($o.Note -and $o.Verdict -eq 'unknown') { $note = $o.Note }
        Write-Host ('        {0}' -f $note) -ForegroundColor DarkGray
        if ($o.Note -and $o.Verdict -ne 'unknown') { Write-Host ('        {0}' -f $o.Note) -ForegroundColor DarkGray }
        if ($o.OfferDate -and $o.OfferDate.Year -lt (Get-Date).Year - 5) {
            Write-Host ('        driver dated {0} - very old, unlikely to add anything' -f $o.OfferDate.ToString('yyyy-MM-dd')) -ForegroundColor DarkGray
        }
    }
}

# 1. Cached list first, so there is something to read straight away.
try {
    $offers = Get-Offers (Get-CachedResult)
    Show-Offers $offers 'cached - from Windows'' most recent check'
} catch {
    $offers = @()
    Write-Host ('  Could not read the cached list: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
}

# 2. Online check. It blocks for a minute or more, so run it in a background
#    runspace and show a counter, then re-read the (now refreshed) cache.
if (-not $SkipOnline) {
    Write-Host ''
    $ps = [powershell]::Create().AddScript({
        param($c)
        $s = New-Object -ComObject Microsoft.Update.Session
        [void]$s.CreateUpdateSearcher().Search($c)
    }).AddArgument($criteria)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $handle = $ps.BeginInvoke()
    while (-not $handle.IsCompleted) {
        Write-Host ("`r  Checking Windows Update online for newer offers... {0,4:N0} s " -f $sw.Elapsed.TotalSeconds) -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 500
    }
    $failed = $null
    try { [void]$ps.EndInvoke($handle) } catch { $failed = $_.Exception.Message }
    if (-not $failed -and $ps.Streams.Error.Count) { $failed = $ps.Streams.Error[0].ToString() }
    $ps.Dispose()
    Write-Host ("`r  Online check finished in {0:N0} s.                                  " -f $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray

    if ($failed) {
        Write-Host ('  Online check failed: {0}' -f $failed) -ForegroundColor Yellow
        Write-Host '  The list above is from the cache and may be out of date.' -ForegroundColor Yellow
    } else {
        $fresh = Get-Offers (Get-CachedResult)
        $oldIds = @($offers | ForEach-Object { $_.Id }) | Sort-Object
        $newIds = @($fresh  | ForEach-Object { $_.Id }) | Sort-Object
        $offers = $fresh
        if ((@($oldIds) -join ',') -eq (@($newIds) -join ',')) {
            Write-Host '  No change - the list above is current.' -ForegroundColor Green
        } else {
            Write-Host '  The online check changed the list:' -ForegroundColor Yellow
            Show-Offers $offers 'online - current'
        }
    }
}

if (-not $offers.Count) { Write-Host ''; return }

Write-Host ''
# Graphics drivers mostly come from the vendor, not Windows Update. Only list
# the vendors whose GPUs are actually in this machine.
$gpus = @($installed | Where-Object { $_.DeviceClass -eq 'DISPLAY' })
$gpuTips = @()
foreach ($g in $gpus) {
    if ($g.DeviceName -match 'NVIDIA') {
        $gpuTips += ('    {0} ({1}) - use the NVIDIA app; Game Ready drivers are not in WU' -f $g.DeviceName, $g.DriverVersion)
    } elseif ($g.DeviceName -match 'Intel') {
        $gpuTips += ('    {0} ({1}) - use Intel Driver and Support Assistant' -f $g.DeviceName, $g.DriverVersion)
    } elseif ($g.DeviceName -match 'AMD|Radeon') {
        $gpuTips += ('    {0} ({1}) - use AMD Software: Adrenalin Edition' -f $g.DeviceName, $g.DriverVersion)
    }
}
if ($gpuTips.Count) {
    Write-Host ''
    Write-Host '  Graphics drivers are usually newer from the vendor than from Windows Update:' -ForegroundColor Cyan
    $gpuTips | Select-Object -Unique | ForEach-Object { Write-Host $_ }
}
Write-Host ''

if (-not $Install) {
    Write-Host '  Read-only scan. Re-run with -Install to choose and apply.' -ForegroundColor DarkGray
    Write-Host ''
    return
}

# ------------------------------------------------------------------- install

if (-not (Test-Admin)) {
    Write-Host '  Installing drivers needs an elevated shell. Relaunching...' -ForegroundColor Yellow
    # This run has just refreshed the cache online, so the elevated one can skip that.
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File', ('"{0}"' -f $PSCommandPath), '-Install', '-SkipOnline')
    if ($Select) { $argList += @('-Select', ($Select -join ',')) }
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $argList } catch { Write-Host '  Elevation cancelled.' -ForegroundColor Yellow }
    return
}

if (-not $Select) {
    Write-Host '  Enter the numbers to install, separated by commas.' -ForegroundColor Cyan
    Write-Host '  Anything marked DOWNGRADE should normally be left alone.' -ForegroundColor DarkGray
    Write-Host '  Enter on its own installs nothing.' -ForegroundColor DarkGray
    Write-Host ''
    $raw = Read-Host '  Install'
    if (-not $raw) { Write-Host '  Nothing selected.' -ForegroundColor DarkGray; return }
    $Select = @()
    foreach ($tok in ($raw -split '[,\s]+')) {
        $n = 0
        if ([int]::TryParse($tok, [ref]$n)) { $Select += $n }
    }
}

$chosen = @($offers | Where-Object { $Select -contains $_.Index })
if (-not $chosen) { Write-Host '  Nothing matched your selection.' -ForegroundColor Yellow; return }

Write-Host ''
foreach ($c in $chosen) {
    $col = if ($c.Verdict -eq 'OLDER') { 'Red' } else { 'Green' }
    Write-Host ('  selected: {0}' -f $c.Title) -ForegroundColor $col
    if ($c.Verdict -eq 'OLDER') {
        Write-Host '            this is older than what you have installed' -ForegroundColor Red
    }
}
Write-Host ''
$ok = Read-Host '  Download and install these? [y/N]'
if ($ok -notmatch '^\s*(y|yes)\s*$') {
    Write-Host '  Cancelled - nothing was downloaded.' -ForegroundColor Yellow
    return
}

$coll = New-Object -ComObject Microsoft.Update.UpdateColl
foreach ($c in $chosen) {
    if (-not $c.Update.EulaAccepted) { try { $c.Update.AcceptEula() } catch { } }
    [void]$coll.Add($c.Update)
}

try {
    Write-Host ''
    Write-Host '  Downloading...' -ForegroundColor Cyan
    $dl = $session.CreateUpdateDownloader()
    $dl.Updates = $coll
    $dlRes = $dl.Download()
    Write-Host ('  download result code: {0}' -f $dlRes.ResultCode)

    Write-Host '  Installing...' -ForegroundColor Cyan
    $inst = $session.CreateUpdateInstaller()
    $inst.Updates = $coll
    $res = $inst.Install()

    $meaning = switch ($res.ResultCode) {
        2 { 'succeeded' } 3 { 'succeeded with errors' } 4 { 'failed' }
        5 { 'cancelled' } default { 'result ' + $res.ResultCode }
    }
    Write-Host ''
    Write-Host ('  Install: {0}' -f $meaning) -ForegroundColor $(if ($res.ResultCode -eq 2) { 'Green' } else { 'Yellow' })
    for ($k = 0; $k -lt $coll.Count; $k++) {
        $r = $res.GetUpdateResult($k)
        Write-Host ('    {0}  -> code {1}' -f $coll.Item($k).Title, $r.ResultCode)
    }
    if ($res.RebootRequired) {
        Write-Host ''
        Write-Host '  A restart is required to finish.' -ForegroundColor Yellow
    }
} catch {
    Write-Host ('  Install failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
}

Write-Host ''
Write-Host '  Re-run the scan afterwards to confirm the version changed.' -ForegroundColor DarkGray
Write-Host ''
