<#
    vr.ps1 - turn the VR stack (Oculus runtime + Virtual Desktop) on or off.

    Why: the Virtual Desktop service creates a 59 Hz virtual display that
    Windows was using as the primary monitor. Mixed 59/60 Hz across displays
    makes video stutter. Turning the stack off when not in VR removes it.

    Usage:  .\vr.ps1 status
            .\vr.ps1 off
            .\vr.ps1 on
#>

[CmdletBinding()]
param(
    [ValidateSet('on', 'off', 'status')]
    [string]$Action = 'status'
)

$services = @(
    @{ Name = 'OVRService';                 Label = 'Oculus VR Runtime' },
    @{ Name = 'VirtualDesktop.Service.exe'; Label = 'Virtual Desktop'   }
)

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Show-Status {
    Write-Host ''
    Write-Host '  Service                 State      Startup' -ForegroundColor Cyan
    Write-Host '  ----------------------  ---------  -------'
    foreach ($s in $services) {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$($s.Name)'" -ErrorAction SilentlyContinue
        if ($null -eq $svc) {
            Write-Host ("  {0,-22}  {1}" -f $s.Label, 'not installed') -ForegroundColor DarkGray
            continue
        }
        if ($svc.State -eq 'Running') { $color = 'Yellow' } else { $color = 'Green' }
        Write-Host ("  {0,-22}  {1,-9}  {2}" -f $s.Label, $svc.State, $svc.StartMode) -ForegroundColor $color
    }

    $virt = Get-CimInstance Win32_VideoController -Filter "Name='Virtual Desktop Monitor'" -ErrorAction SilentlyContinue
    Write-Host ''
    if ($null -ne $virt -and $null -ne $virt.CurrentRefreshRate) {
        Write-Host ("  Virtual monitor ACTIVE at {0}x{1} @ {2} Hz" -f `
            $virt.CurrentHorizontalResolution, $virt.CurrentVerticalResolution, $virt.CurrentRefreshRate) -ForegroundColor Yellow
    } else {
        Write-Host '  Virtual monitor not attached.' -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '  Real displays:' -ForegroundColor Cyan
    Get-CimInstance Win32_VideoController |
        Where-Object { $_.CurrentRefreshRate -and $_.Name -ne 'Virtual Desktop Monitor' } |
        ForEach-Object {
            Write-Host ("    {0,-38} {1}x{2} @ {3} Hz" -f `
                $_.Name, $_.CurrentHorizontalResolution, $_.CurrentVerticalResolution, $_.CurrentRefreshRate)
        }
    Write-Host ''
}

if ($Action -eq 'status') {
    Show-Status
    return
}

# on/off need admin - relaunch elevated if we are not already
if (-not (Test-Admin)) {
    Write-Host 'Elevating...' -ForegroundColor DarkGray
    $psi = @{
        FilePath     = 'powershell.exe'
        Verb         = 'RunAs'
        ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
                         '-File', "`"$PSCommandPath`"", $Action)
    }
    try { Start-Process @psi } catch { Write-Warning 'Elevation cancelled.'; return }
    return
}

if ($Action -eq 'off') {
    foreach ($s in $services) {
        $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
        if ($null -eq $svc) { continue }
        if ($svc.Status -ne 'Stopped') {
            Write-Host ("Stopping {0}..." -f $s.Label)
            try { Stop-Service -Name $s.Name -Force -ErrorAction Stop } catch { Write-Warning $_.Exception.Message }
        }
        Set-Service -Name $s.Name -StartupType Manual -ErrorAction SilentlyContinue
    }
    # sweep up anything the services left behind
    Get-Process -Name OVRServer_x64, OVRRedir, OVRServiceLauncher, VirtualDesktop.Service -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host 'VR stack OFF. Startup set to Manual.' -ForegroundColor Green
}

if ($Action -eq 'on') {
    foreach ($s in $services) {
        $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
        if ($null -eq $svc) { continue }
        Write-Host ("Starting {0}..." -f $s.Label)
        try { Start-Service -Name $s.Name -ErrorAction Stop } catch { Write-Warning $_.Exception.Message }
    }
    Write-Host 'VR stack ON.' -ForegroundColor Green
}

Start-Sleep -Seconds 2
Show-Status
Write-Host 'Press any key to close...' -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
