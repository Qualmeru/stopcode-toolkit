#!/usr/bin/env python3
"""
Rebuild the per-app GPU / AutoHDR preference list from a saved PowerShell
Format-List dump, and emit a .reg file to restore it.

Format-List wrapped each value one character per continuation line, so a few
characters are lost or duplicated at wrap boundaries. Values are therefore
re-derived from the tokens found rather than trusted verbatim.
"""

import re
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "bhecjlvlp.txt"
OUT = sys.argv[2] if len(sys.argv) > 2 else "restore-gpu-prefs.reg"

with open(SRC, encoding="utf-8", errors="replace") as fh:
    lines = [ln.rstrip("\r\n") for ln in fh]

BS = chr(92)
start = re.compile(r"^([A-Za-z]:" + BS + BS + r".*[.]exe)\s+:\s*(\S)\s*$")
cont = re.compile(r"^\s{20,}(\S)\s*$")

entries = []
path = None
val = []

for ln in lines:
    m = start.match(ln)
    if m:
        if path:
            entries.append((path, "".join(val)))
        path, val = m.group(1).strip(), [m.group(2)]
        continue
    c = cont.match(ln)
    if c and path:
        val.append(c.group(1))
        continue
    if not ln.strip() and path:
        entries.append((path, "".join(val)))
        path, val = None, []

if path:
    entries.append((path, "".join(val)))


def clean(raw):
    """Re-derive a canonical value from whatever survived the wrapping."""
    raw = "".join(ch for ch in raw if ord(ch) < 128)
    parts = []
    g = re.search(r"GpuPreference=(\d)", raw)
    if g:
        parts.append("GpuPreference=" + g.group(1))
    h = re.search(r"utoHDREnable=(\d+)", raw)   # leading 'A' is sometimes lost
    if h:
        parts.append("AutoHDREnable=" + h.group(1))
    return ";".join(parts) + ";" if parts else None


rows = []
for p, v in entries:
    c = clean(v)
    if c:
        rows.append((p, c))

label = {"1": "iGPU", "2": "dGPU"}
print("recovered %d entries\n" % len(rows))
for p, v in rows:
    g = re.search(r"GpuPreference=(\d)", v)
    tag = label.get(g.group(1), "-") if g else "AutoHDR only"
    print("  %-12s %-34s %s" % (tag, v, p))

with open(OUT, "w", encoding="utf-16") as fh:
    fh.write("Windows Registry Editor Version 5.00\n\n")
    fh.write(r"[HKEY_CURRENT_USER\SOFTWARE\Microsoft\DirectX\UserGpuPreferences]")
    fh.write("\n")
    for p, v in rows:
        esc = p.replace(BS, BS + BS)
        fh.write('"%s"="%s"\n' % (esc, v))

print("\nwritten to %s" % OUT)
