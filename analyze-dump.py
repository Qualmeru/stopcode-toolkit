#!/usr/bin/env python3
r"""
Parse Windows kernel triage dumps (PAGEDU64) without WinDbg.

Resolves the faulting address and every call-stack frame against the dump's
own loaded-module list, and flags non-Microsoft drivers - which is normally
the driver you are actually looking for.

Usage:  python analyze-dump.py [dump-or-directory ...]
        (defaults to .\diag\minidumps, then C:\Windows\Minidump)
"""

import os
import struct
import sys
import glob

# Bugchecks worth naming on sight.
BUGCHECKS = {
    0x0A: "IRQL_NOT_LESS_OR_EQUAL",
    0x18: "REFERENCE_BY_POINTER",
    0x3B: "SYSTEM_SERVICE_EXCEPTION",
    0x50: "PAGE_FAULT_IN_NONPAGED_AREA",
    0x7E: "SYSTEM_THREAD_EXCEPTION_NOT_HANDLED",
    0xC1: "SPECIAL_POOL_DETECTED_MEMORY_CORRUPTION",
    0xC4: "DRIVER_VERIFIER_DETECTED_VIOLATION",
    0xC9: "DRIVER_VERIFIER_IOMANAGER_VIOLATION",
    0xD1: "DRIVER_IRQL_NOT_LESS_OR_EQUAL",
    0xD6: "DRIVER_PAGE_FAULT_BEYOND_END_OF_ALLOCATION",
    0xE6: "DRIVER_VERIFIER_DMA_VIOLATION",
    0x141: "VIDEO_ENGINE_TIMEOUT_DETECTED",
    0x193: "VIDEO_DXGKRNL_LIVEDUMP",
    0x19: "BAD_POOL_HEADER",
    0x1A: "MEMORY_MANAGEMENT",
    0x1E: "KMODE_EXCEPTION_NOT_HANDLED",
    0x7F: "UNEXPECTED_KERNEL_MODE_TRAP",
    0x9C: "MACHINE_CHECK_EXCEPTION",
    0x9F: "DRIVER_POWER_STATE_FAILURE",
    0xA0: "INTERNAL_POWER_ERROR",
    0xBE: "ATTEMPTED_WRITE_TO_READONLY_MEMORY",
    0xC2: "BAD_POOL_CALLER",
    0xC5: "DRIVER_CORRUPTED_EXPOOL",
    0xD5: "DRIVER_PAGE_FAULT_IN_FREED_SPECIAL_POOL",
    0xEA: "THREAD_STUCK_IN_DEVICE_DRIVER",
    0xEF: "CRITICAL_PROCESS_DIED",
    0xFC: "ATTEMPTED_EXECUTE_OF_NOEXECUTE_MEMORY",
    0x101: "CLOCK_WATCHDOG_TIMEOUT",
    0x116: "VIDEO_TDR_FAILURE",
    0x117: "VIDEO_TDR_TIMEOUT_DETECTED",
    0x119: "VIDEO_SCHEDULER_INTERNAL_ERROR",
    0x124: "WHEA_UNCORRECTABLE_ERROR",
    0x133: "DPC_WATCHDOG_VIOLATION",
    0x139: "KERNEL_SECURITY_CHECK_FAILURE",
    0x13A: "KERNEL_MODE_HEAP_CORRUPTION",
    0x144: "BUGCODE_USB3_DRIVER",
    0x154: "UNEXPECTED_STORE_EXCEPTION",
    0x15F: "CONNECTED_STANDBY_WATCHDOG_TIMEOUT_LIVEDUMP",
    0x161: "LIVE_SYSTEM_DUMP",
    0x190: "WIN32K_CRITICAL_FAILURE_LIVEDUMP",
    0x1C8: "MANUALLY_INITIATED_POWER_BUTTON_HOLD",

}

# Drivers shipped with Windows - not suspects by default.
MS_DRIVERS = {
    'ntoskrnl.exe', 'hal.dll', 'ks.sys', 'portcls.sys', 'ndis.sys', 'tcpip.sys',
    'win32k.sys', 'win32kbase.sys', 'win32kfull.sys', 'dxgkrnl.sys', 'dxgmms2.sys',
    'dxgmms1.sys', 'usbaudio.sys', 'usbhub3.sys', 'wdf01000.sys', 'acpi.sys',
    'fltmgr.sys', 'ntfs.sys', 'volmgr.sys', 'storport.sys', 'kdcom.dll', 'clfs.sys',
    'cng.sys', 'msrpc.sys', 'tm.sys', 'pci.sys', 'wpprecorder.sys', 'afd.sys',
}

TRIAGE_FIELDS = [
    'ServicePackBuild', 'SizeOfDump', 'ValidOffset', 'ContextOffset',
    'ExceptionOffset', 'MmOffset', 'UnloadedDriversOffset', 'PrcbOffset',
    'ProcessOffset', 'ThreadOffset', 'CallStackOffset', 'SizeOfCallStack',
    'DriverListOffset', 'DriverCount', 'StringPoolOffset', 'StringPoolSize',
    'BrokenDriverOffset', 'TriageOptions',
]


def read_modules(d, driver_list_off, count):
    """Each _DUMP_DRIVER_ENTRY64 is 144 bytes: name offset + KLDR_DATA_TABLE_ENTRY64."""
    mods = []
    for i in range(count):
        e = driver_list_off + i * 144
        if e + 144 > len(d):
            break
        name_off, = struct.unpack_from('<Q', d, e)
        base,     = struct.unpack_from('<Q', d, e + 0x38)
        size,     = struct.unpack_from('<I', d, e + 0x48)
        name = ''
        if 0 < name_off < len(d) - 4:
            ln, = struct.unpack_from('<I', d, name_off)
            if 0 < ln < 260:
                name = d[name_off + 4:name_off + 4 + ln * 2].decode('utf-16-le', 'replace')
        if base:
            mods.append((base, size, name))
    mods.sort()
    return mods


def resolve(mods, addr):
    lo, hi = 0, len(mods) - 1
    while lo <= hi:
        m = (lo + hi) // 2
        base, size, name = mods[m]
        if addr < base:
            hi = m - 1
        elif addr >= base + size:
            lo = m + 1
        else:
            return name, addr - base
    return None, None


def third_party(name):
    return name and name.lower() not in MS_DRIVERS


def analyze(path):
    with open(path, 'rb') as fh:
        d = fh.read()

    print('=' * 78)
    print(os.path.basename(path))
    print('=' * 78)

    if d[:8] != b'PAGEDU64':
        print('  Not a 64-bit kernel dump (signature %r) - skipping.\n' % d[:8])
        return

    code, = struct.unpack_from('<I', d, 0x38)
    params = [struct.unpack_from('<Q', d, 0x40 + 8 * i)[0] for i in range(4)]
    label = BUGCHECKS.get(code, 'unknown')
    print('  Bugcheck : 0x%X  %s' % (code, label))
    for i, p in enumerate(params, 1):
        print('    param%d : 0x%016x' % (i, p))

    tri = struct.unpack_from('<18I', d, 0x2000)
    t = dict(zip(TRIAGE_FIELDS, tri))
    mods = read_modules(d, t['DriverListOffset'], t['DriverCount'])
    if not mods:
        print('  No module list recovered.\n')
        return
    print('  Modules loaded: %d' % len(mods))

    # Driver Verifier bugchecks put the offending driver's address in a param.
    if code in (0xC1, 0xC4, 0xC9, 0xD6, 0xE6):
        print('\n  -- Driver Verifier caught a violation --')
        for i, p in enumerate(params, 1):
            nm, off = resolve(mods, p)
            if nm:
                print('    param%d -> %s +0x%x' % (i, nm, off))

    nm, off = resolve(mods, params[3])
    if nm:
        print('\n  Fault address -> %s +0x%x' % (nm, off))

    cs, css = t['CallStackOffset'], t['SizeOfCallStack']
    frames, suspects = [], []
    for o in range(cs, min(cs + css, len(d) - 8), 8):
        v, = struct.unpack_from('<Q', d, o)
        n2, o2 = resolve(mods, v)
        if n2 and (not frames or frames[-1][0] != n2):
            frames.append((n2, o2, v))
            if third_party(n2):
                suspects.append(n2)

    print('\n  Call stack:')
    for n2, o2, v in frames:
        mark = '  <-- THIRD PARTY' if third_party(n2) else ''
        print('    0x%016x  %-28s +0x%-8x%s' % (v, n2, o2, mark))

    print('\n  VERDICT: ', end='')
    if suspects:
        uniq = list(dict.fromkeys(suspects))
        print('third-party driver(s) on the stack: ' + ', '.join(uniq))
    else:
        print('no third-party driver captured in this stack.')
    print()


def collect(args):
    paths = []
    for a in args:
        if os.path.isdir(a):
            paths += sorted(glob.glob(os.path.join(a, '*.dmp')))
        elif os.path.isfile(a):
            paths.append(a)
    return paths


def main():
    args = sys.argv[1:]
    if not args:
        here = os.path.dirname(os.path.abspath(__file__))
        for cand in (os.path.join(here, 'diag', 'minidumps'), r'C:\Windows\Minidump'):
            if os.path.isdir(cand) and glob.glob(os.path.join(cand, '*.dmp')):
                args = [cand]
                break
    paths = collect(args)
    if not paths:
        print('No .dmp files found. Run collect-crash.ps1 first (it needs admin).')
        return 1
    paths.sort(key=os.path.getmtime, reverse=True)
    for p in paths:
        try:
            analyze(p)
        except Exception as exc:
            print('  Failed to parse: %s\n' % exc)
    return 0


if __name__ == '__main__':
    sys.exit(main())
