<#
    make-shortcut.ps1 - build an icon for the control panel and place shortcuts.

    Creates:
      - ControlPanel.ico  (drawn here, matching the app's shield icon)
      - a Desktop shortcut
      - a Start Menu shortcut, so it is searchable and easy to pin

    Windows blocks programmatic taskbar pinning, so that stays a manual
    right-click. This script makes it one, by putting the shortcut where the
    Start menu can find it.
#>

[CmdletBinding()]
param([switch]$Remove)

Add-Type -AssemblyName System.Drawing

$Root     = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Target   = Join-Path $Root 'ControlPanel.ps1'
$IconPath = Join-Path $Root 'ControlPanel.ico'
$LinkName = 'stopcode-toolkit Control Panel.lnk'
$Desktop  = Join-Path ([Environment]::GetFolderPath('Desktop')) $LinkName
$StartDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'Stopcode Toolkit'
$StartLnk = Join-Path $StartDir $LinkName

# Earlier versions were named after the laptop they were written on.
$OldDir   = Join-Path ([Environment]::GetFolderPath('Programs')) 'ZenBook Tools'
$OldLinks = @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'ZenBook Control Panel.lnk'),
              (Join-Path $OldDir 'ZenBook Control Panel.lnk'))
function Remove-OldLinks {
    foreach ($p in $OldLinks) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Write-Host "removed old $p" }
    }
    if ((Test-Path $OldDir) -and -not (Get-ChildItem $OldDir -Force)) { Remove-Item -LiteralPath $OldDir -Force }
}

if ($Remove) {
    foreach ($p in @($Desktop, $StartLnk)) {
        if (Test-Path $p) { Remove-Item -LiteralPath $p -Force; Write-Host "removed $p" }
    }
    if ((Test-Path $StartDir) -and -not (Get-ChildItem $StartDir -Force)) {
        Remove-Item -LiteralPath $StartDir -Force
    }
    Remove-OldLinks
    return
}

if (-not (Test-Path $Target)) { Write-Error "ControlPanel.ps1 not found beside this script."; return }

# ------------------------------------------------------------------ the icon
# Drawn rather than shipped as a binary: a dark rounded tile with the same
# teal shield used in the app header.

$size = 256
$bmp  = New-Object System.Drawing.Bitmap $size, $size
$g    = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.Clear([System.Drawing.Color]::Transparent)

function New-RoundedPath {
    param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    $p.AddArc($X,            $Y,            $d, $d, 180, 90)
    $p.AddArc($X + $W - $d,  $Y,            $d, $d, 270, 90)
    $p.AddArc($X + $W - $d,  $Y + $H - $d,  $d, $d,   0, 90)
    $p.AddArc($X,            $Y + $H - $d,  $d, $d,  90, 90)
    $p.CloseFigure()
    return $p
}

$tile   = New-RoundedPath 8 8 240 240 44
$fill   = New-Object System.Drawing.SolidBrush -ArgumentList ([System.Drawing.ColorTranslator]::FromHtml('#151B24'))
$edge   = New-Object System.Drawing.Pen -ArgumentList ([System.Drawing.ColorTranslator]::FromHtml('#28313D')), 5
$g.FillPath($fill, $tile)
$g.DrawPath($edge, $tile)

$teal = [System.Drawing.ColorTranslator]::FromHtml('#4FB8C0')

# Shield outline: wide at the shoulders, tapering to a point.
$shield = New-Object System.Drawing.Drawing2D.GraphicsPath
$pts = @(
    (New-Object System.Drawing.PointF 128, 48),
    (New-Object System.Drawing.PointF 198, 78),
    (New-Object System.Drawing.PointF 198, 128),
    (New-Object System.Drawing.PointF 128, 208),
    (New-Object System.Drawing.PointF  58, 128),
    (New-Object System.Drawing.PointF  58, 78)
)
$shield.AddPolygon([System.Drawing.PointF[]]$pts)
$shieldPen = New-Object System.Drawing.Pen -ArgumentList $teal, 12
$shieldPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
$g.DrawPath($shieldPen, $shield)

# Upward arrow inside it.
$pen = New-Object System.Drawing.Pen -ArgumentList $teal, 12
$pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
$g.DrawLine($pen, 128, 168, 128, 92)
$g.DrawLine($pen, 128, 88, 164, 124)
$g.DrawLine($pen, 128, 88,  92, 124)

$g.Dispose()

# ICO files may wrap a PNG directly (Vista onward), which keeps this simple and
# gives a crisp 256px icon.
$ms = New-Object System.IO.MemoryStream
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$png = $ms.ToArray()
$ms.Dispose(); $bmp.Dispose()

$ico = New-Object System.IO.MemoryStream
$bw  = New-Object System.IO.BinaryWriter $ico
$bw.Write([uint16]0)            # reserved
$bw.Write([uint16]1)            # type: icon
$bw.Write([uint16]1)            # image count
$bw.Write([byte]0)              # width  0 means 256
$bw.Write([byte]0)              # height 0 means 256
$bw.Write([byte]0)              # palette
$bw.Write([byte]0)              # reserved
$bw.Write([uint16]1)            # colour planes
$bw.Write([uint16]32)           # bits per pixel
$bw.Write([uint32]$png.Length)  # size of image data
$bw.Write([uint32]22)           # offset to image data
$bw.Write($png)
$bw.Flush()
[System.IO.File]::WriteAllBytes($IconPath, $ico.ToArray())
$bw.Dispose(); $ico.Dispose()
Write-Host ("icon written: {0} ({1:N0} bytes)" -f $IconPath, (Get-Item $IconPath).Length) -ForegroundColor Green

# ------------------------------------------------------------- the shortcuts

$shell = New-Object -ComObject WScript.Shell

function New-Link {
    param([string]$Path)
    $dir = Split-Path $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath       = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk.Arguments        = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $Target)
    $lnk.WorkingDirectory = $Root
    $lnk.IconLocation     = ('{0},0' -f $IconPath)
    $lnk.Description      = 'Gaming mode, kernel fault monitoring and cleanup tools'
    $lnk.WindowStyle      = 7      # minimised, so the host console stays out of the way
    $lnk.Save()
    Write-Host ("shortcut: {0}" -f $Path) -ForegroundColor Green
}

Remove-OldLinks
New-Link $Desktop
New-Link $StartLnk

Write-Host ''
Write-Host '  To pin it to the taskbar (Windows does not allow this to be scripted):' -ForegroundColor Cyan
Write-Host '    press Start, type "stopcode", right-click the result, Pin to taskbar'
Write-Host ''
