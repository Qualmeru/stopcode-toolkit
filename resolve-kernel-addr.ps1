<#
    resolve-kernel-addr.ps1 - map a kernel address to the driver that owns it.

    Live kernel dumps (0x141 / 0x193) carry no triage section, so there is no
    module list inside them. But if the machine has not rebooted since the dump
    was written, ASLR has not moved anything: the drivers loaded right now sit
    at the same base addresses they did at fault time, so the address can be
    resolved against the live system.

    Uses EnumDeviceDrivers, which returns null bases to non-elevated callers on
    modern Windows (kernel address disclosure is restricted), so this needs to
    run elevated.

    Usage:  .\resolve-kernel-addr.ps1 0xfffff80731cf67b0 [more addresses...]
#>

[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Address)

$out = Join-Path $PSScriptRoot 'resolve-kernel-addr.txt'
$lines = @()

$sig = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class Psapi {
    [DllImport("psapi.dll", SetLastError = true)]
    public static extern bool EnumDeviceDrivers(IntPtr[] imageBase, uint cb, out uint lpcbNeeded);

    [DllImport("psapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetDeviceDriverBaseName(IntPtr imageBase, StringBuilder baseName, int size);

    [DllImport("psapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetDeviceDriverFileName(IntPtr imageBase, StringBuilder fileName, int size);

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_PRIVILEGES {
        public uint PrivilegeCount;
        public LUID Luid;
        public uint Attributes;
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool LookupPrivilegeValue(string system, string name, out LUID luid);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll,
        ref TOKEN_PRIVILEGES newState, uint len, IntPtr prev, IntPtr retLen);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();

    // Kernel addresses are only disclosed to a caller holding SeDebugPrivilege
    // in its token - being elevated is not sufficient on its own.
    public static string EnableDebugPrivilege() {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x0020 | 0x0008, out token))
            return "OpenProcessToken failed " + Marshal.GetLastWin32Error();
        LUID luid;
        if (!LookupPrivilegeValue(null, "SeDebugPrivilege", out luid))
            return "LookupPrivilegeValue failed " + Marshal.GetLastWin32Error();
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.PrivilegeCount = 1;
        tp.Luid = luid;
        tp.Attributes = 0x00000002; // SE_PRIVILEGE_ENABLED
        if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero))
            return "AdjustTokenPrivileges failed " + Marshal.GetLastWin32Error();
        int err = Marshal.GetLastWin32Error();
        if (err == 1300) return "privilege not held (ERROR_NOT_ALL_ASSIGNED)";
        return "ok";
    }
}
'@
Add-Type -TypeDefinition $sig -ErrorAction Stop

$priv = [Psapi]::EnableDebugPrivilege()
$lines += ('SeDebugPrivilege: {0}' -f $priv)

# Allocate generously and call once. The sizing call cannot be made from
# PowerShell by passing $null for the array, so skip it.
$capacity = 4096
$bases = New-Object IntPtr[] $capacity
$needed = 0
$ok = [Psapi]::EnumDeviceDrivers($bases, [uint32]($capacity * [IntPtr]::Size), [ref]$needed)
if (-not $ok) {
    $lines += ('EnumDeviceDrivers failed (win32 error {0}) - are you elevated?' -f [Runtime.InteropServices.Marshal]::GetLastWin32Error())
    Set-Content -LiteralPath $out -Value $lines -Encoding utf8
    $lines | ForEach-Object { Write-Host $_ }
    Start-Sleep -Seconds 5
    return
}
$count = [int]($needed / [IntPtr]::Size)
if ($count -gt $capacity) { $count = $capacity }
$bases = $bases[0..([Math]::Max($count - 1, 0))]
$nonZero = @($bases | Where-Object { $_ -ne [IntPtr]::Zero }).Count
$lines += ('EnumDeviceDrivers: {0} entries, {1} with a non-null base' -f $count, $nonZero)

$mods = @()
foreach ($b in $bases) {
    if ($b -eq [IntPtr]::Zero) { continue }
    $sb = New-Object System.Text.StringBuilder 260
    [void][Psapi]::GetDeviceDriverBaseName($b, $sb, $sb.Capacity)
    $fb = New-Object System.Text.StringBuilder 1024
    [void][Psapi]::GetDeviceDriverFileName($b, $fb, $fb.Capacity)
    # Kernel pointers have the top bit set, so ToInt64() is negative and a
    # direct [uint64] cast throws. Reinterpret the bits instead.
    $mods += [pscustomobject]@{
        Base = [BitConverter]::ToUInt64([BitConverter]::GetBytes($b.ToInt64()), 0)
        Name = $sb.ToString()
        Path = $fb.ToString()
    }
}
$mods = @($mods | Sort-Object Base)

# Without elevation Windows returns every base as null, so nothing can resolve.
if (-not $mods.Count) {
    $lines += ''
    $lines += 'No driver addresses visible - Windows hides them from non-elevated'
    $lines += 'processes. Run this from an elevated (administrator) PowerShell.'
    Set-Content -LiteralPath $out -Value $lines -Encoding utf8
    $lines | ForEach-Object { Write-Host $_ }
    Start-Sleep -Seconds 5
    return
}
if (-not $Address) {
    $lines += ''
    $lines += 'Usage: .\resolve-kernel-addr.ps1 0xfffff80731cf67b0 [more addresses...]'
}

$lines += ('loaded kernel modules: {0}' -f $mods.Count)
$lines += ('lowest base  : 0x{0:x16}  {1}' -f $mods[0].Base, $mods[0].Name)
$lines += ('highest base : 0x{0:x16}  {1}' -f $mods[-1].Base, $mods[-1].Name)
$lines += ''

foreach ($a in $Address) {
    # Convert.ToUInt64 with base 16 handles the full unsigned range; a plain
    # [uint64]'0xffff...' cast does not.
    $target = [System.Convert]::ToUInt64(($a -replace '^0x', ''), 16)
    $lines += ('=== 0x{0:x16} ===' -f $target)

    # The module that owns an address is the one with the greatest base below it.
    $owner = $null
    foreach ($m in $mods) {
        if ($m.Base -le $target) { $owner = $m } else { break }
    }

    if ($owner) {
        $offset = $target - $owner.Base
        $lines += ('  owner   : {0}' -f $owner.Name)
        $lines += ('  base    : 0x{0:x16}' -f $owner.Base)
        $lines += ('  offset  : +0x{0:x}' -f $offset)
        $lines += ('  path    : {0}' -f $owner.Path)
        if ($offset -gt 0x4000000) {
            $lines += '  NOTE: offset is implausibly large - the address probably belongs to'
            $lines += '        no loaded driver (pool/session space), so treat this as unresolved.'
        }
    } else {
        $lines += '  below every loaded module base - not a driver address.'
    }
    $lines += ''
}

Set-Content -LiteralPath $out -Value $lines -Encoding utf8
$lines | ForEach-Object { Write-Host $_ }
Start-Sleep -Seconds 5
