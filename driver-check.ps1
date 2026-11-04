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
#>

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Inventory,
    [int[]]$Select,
    [int]$AgeYears = 3
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
    $installed |
        Where-Object { $_.DriverProviderName -notmatch 'Microsoft' -and $_.DriverDate } |
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
    Write-Host '  Yellow entries are over {0} years old. Age alone is not a problem:' -f $AgeYears -ForegroundColor DarkGray
    Write-Host '  many devices simply never get new drivers.' -ForegroundColor DarkGray
    Write-Host ''
    return
}

# ---------------------------------------------------------------------- scan

Write-Host ''
Write-Host '  Asking Windows Update for driver updates...' -ForegroundColor DarkGray

try {
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $result   = $searcher.Search("IsInstalled=0 AND Type='Driver'")
} catch {
    Write-Host ('  Windows Update search failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
    return
}

$offers = @()
$i = 0
foreach ($u in $result.Updates) {
    $i++
    $model = ''; $mfr = ''; $vdate = $null
    try { $model = $u.DriverModel } catch { }
    try { $mfr   = $u.DriverManufacturer } catch { }
    try { $vdate = $u.DriverVerDate } catch { }
    $cur = Find-Installed -Model $model
    $offered = Get-OfferedVersion $u
    $verdict = Compare-Version -Offered $offered -Current $(if ($cur) { $cur.DriverVersion } else { '' })

    $offers += [pscustomobject]@{
        Index     = $i
        Update    = $u
        Title     = $u.Title
        Model     = $model
        Mfr       = $mfr
        Offered   = $offered
        OfferDate = $vdate
        Current   = $(if ($cur) { $cur.DriverVersion } else { '' })
        CurDate   = $(if ($cur) { $cur.DriverDate } else { $null })
        Verdict   = $verdict
        SizeMB    = [math]::Round($u.MaxDownloadSize / 1MB, 1)
    }
}

Write-Host ''
Write-Host ('  {0} driver update(s) offered by Windows Update' -f $offers.Count) -ForegroundColor Cyan
Write-Host ''

if (-not $offers) {
    Write-Host '  Nothing offered. Note that Windows Update does not carry NVIDIA' -ForegroundColor DarkGray
    Write-Host '  Game Ready drivers or Intel graphics releases - use their own apps.' -ForegroundColor DarkGray
    Write-Host ''
    return
}

Write-Host '    #   Device                                    Offered      Installed    Size'
Write-Rule
foreach ($o in $offers) {
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
    Write-Host ('        {0}' -f $note) -ForegroundColor DarkGray
    if ($o.OfferDate -and $o.OfferDate.Year -lt (Get-Date).Year - 5) {
        Write-Host ('        driver dated {0} - very old, unlikely to add anything' -f $o.OfferDate.ToString('yyyy-MM-dd')) -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host '  Not covered by Windows Update on this machine:' -ForegroundColor Cyan
Write-Host '    NVIDIA GeForce  - use the NVIDIA app (Game Ready drivers are not in WU)'
Write-Host '    Intel graphics  - use Intel Driver and Support Assistant'
Write-Host '                      (this GPU is on legacy support; 31.0.101.2141 is final)'
Write-Host ''

if (-not $Install) {
    Write-Host '  Read-only scan. Re-run with -Install to choose and apply.' -ForegroundColor DarkGray
    Write-Host ''
    return
}

# ------------------------------------------------------------------- install

if (-not (Test-Admin)) {
    Write-Host '  Installing drivers needs an elevated shell. Relaunching...' -ForegroundColor Yellow
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File', ('"{0}"' -f $PSCommandPath), '-Install')
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
