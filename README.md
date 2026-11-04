# stopcode

Windows kernel-fault diagnostics and system tuning, in PowerShell. No WinDbg, no
symbol server, no installer.

Built while chasing a real fault across seven weeks: a laptop that stuttered
during video, froze under load, and occasionally bluescreened. Four unrelated
causes turned out to be hiding behind each other. The tools here are what it
took to separate them.

---

## The part worth reading first

Windows writes a **live kernel dump** for non-fatal faults — `0x141`
VIDEO_ENGINE_TIMEOUT, `0x193` VIDEO_DXGKRNL_LIVEDUMP and friends. The system
recovers, so you get a flicker or a hitch instead of a crash, and almost no
information.

Two things make these hard to read:

1. **Windows Error Reporting shows nothing useful.** Every parameter in the
   `Report.wer` comes back as `aaaaaaaaaaaaaaaa` — the pool fill pattern. It
   looks like memory corruption. It isn't; those fields simply are not
   populated for live kernel events.

2. **The dump has no module list.** A minidump carries a `_TRIAGE_DUMP64`
   section with every loaded driver and its base address, so an address can be
   resolved from inside the file. Live kernel dumps carry no such section, and
   they can be many gigabytes.

So the obvious approaches fail: the report has no data, and the dump has data
you can't attribute to anything.

### What works instead

**Read the dump header, not the report.** The `DUMP_HEADER64` at the start of
the file carries the real bugcheck parameters even when WER shows poison. You
only need the first `0x3000` bytes, so a 9 GB dump costs one seek:

```
bugcheck 0x141  VIDEO_ENGINE_TIMEOUT_DETECTED
  param2 : 0xfffff80731cf67b0     <- a real kernel code pointer
```

**Resolve it against the running system.** If the machine has not rebooted
since the dump was written, ASLR has not moved anything: every driver still
sits at the base address it had at fault time. Enumerate the loaded modules now
and the address resolves.

```
0xfffff80731cf67b0  ->  igdkmd64.sys +0x467b0
                        base 0xfffff80731cb0000
                        Intel Corporation, version 31.0.101.2141
```

Two catches, both of which cost real time to find:

- **`EnumDeviceDrivers` returns null base addresses** unless `SeDebugPrivilege`
  is actively enabled in the token. Running elevated is *not* sufficient.
  `resolve-kernel-addr.ps1` enables it explicitly.
- **The evidence is perishable.** Reboot and the dump becomes unresolvable,
  because the bases it referred to no longer exist. Resolve before restarting.

Sanity-check the result rather than trusting the nearest base: an offset of
`+0x467b0` into a 44 MB driver is plausible, an offset larger than the module
is not. The script says so when the number looks wrong.

---

## What it found

The investigation that produced these scripts ended with four separate faults.
Worth recording because three of them masked the fourth:

| Fault | Cause |
|---|---|
| Video stutter | Browser rendering and decoding on the integrated GPU while the discrete GPU idled at its minimum clock |
| Desktop collapse | A pagefile configured to *start* at 2 GB on a 32 GB machine; commit exhausted, `dwm.exe` died with `STATUS_FATAL_MEMORY_EXHAUSTION` |
| Browser flicker | A GPU driver regression, fixed by the vendor's next release |
| Engine timeouts | `igdkmd64.sys` — the integrated graphics driver, on a GPU generation the vendor had moved to legacy support, so no fix exists |

One detail generalises beyond this machine:

> Windows' per-app GPU preference (`GpuPreference=2`) controls **rendering**.
> A browser picks its **video decode** device separately. Pinning Chrome to the
> discrete GPU improved frame rates 6.7x while hardware decode stayed on the
> integrated GPU for another seven weeks — which is where the faults were.

Check `GPU Engine` performance counters per adapter before concluding anything
about where work is actually happening. `log-video-engine.ps1` does this
continuously.

---

## Contents

### Fault diagnosis

| Script | What it does |
|---|---|
| `watch-dumps.ps1` | Tray watcher. Parses new minidumps, resolves the call stack against the dump's own module list, flags non-Microsoft drivers, and notifies. Also records live kernel events with **real timestamps**, decoded from the WER `EventTime` FILETIME — folder timestamps are useless because WER re-queues everything at boot. |
| `analyze-dump.py` | Standalone `PAGEDU64` triage-dump parser. Resolves the faulting address and every stack frame. Decodes Driver Verifier bugchecks by name. |
| `resolve-kernel-addr.ps1` | Maps a kernel address to its owning driver using the live module list. The technique described above. |
| `peek-livedump.ps1` | Reads a live kernel dump's header without copying it; reports the true bugcheck parameters and whether a triage section exists. |
| `collect-crash.ps1` | Copies dumps and WER reports somewhere readable. Skips dumps over 512 MB rather than filling the disk. |
| `crash-count.ps1` | Counts kernel faults by bugcheck and diffs against a saved baseline, so a change can be measured rather than guessed at. |

### Monitoring

| Script | What it does |
|---|---|
| `log-video-engine.ps1` | Records which process drives which GPU's video engines. The watcher says *when* a fault happened; this says *what was using the engine*. |
| `gpu-monitor.ps1` | Samples temperature, power, clocks and NVIDIA's clock-event reasons **by name**, plus TDR events and new kernel faults. Writes CSV. |
| `gpu-stress.html` | Browser stress test driving 3D *and* video decode together. Generates its test clip in-page, so nothing is downloaded. Pure-3D benchmarks never touch the decode engine, which is where some faults live. |

### System

| Script | What it does |
|---|---|
| `ControlPanel.ps1` | WPF GUI over everything below. Live readings, a process picker, and a log pane. |
| `gaming-mode.ps1` | Frees memory before a game. You choose what closes; apps are asked politely first so they save state. Presets for keeping a browser or an editor open. |
| `driver-check.ps1` | Driver updates via the Windows Update API only — WHQL-signed, no vendor-site downloads. Compares each offer against the installed version and **flags downgrades**, which Windows itself does not. |
| `cleanup.ps1` | Reclaims regenerable caches and stale dumps. Dry run by default. Never touches documents or game installs. |
| `vr.ps1` | Starts and stops a VR runtime that otherwise runs permanently. |
| `survey-system.ps1` | Admin-only disk and dump survey. |

---

## The GUI

```
powershell -ExecutionPolicy Bypass -File .\ControlPanel.ps1
```

Live commit, headroom, GPU and fault readings in the header. Gaming-mode process
picker with recommendations. Buttons for every tool, each with a tooltip
explaining what it does and whether it needs admin. A log pane records
everything it did.

Icons are vector `Path` geometry, so they stay sharp at any DPI.
`make-shortcut.ps1` draws an icon and places Desktop and Start Menu shortcuts.

---

## Requirements

- Windows 10 or 11
- **Windows PowerShell 5.1** — the scripts avoid `?:`, `??` and `::new()`
  accordingly
- Python 3 is optional, for `analyze-dump.py` only; `watch-dumps.ps1` carries
  its own parser in PowerShell so the scheduled task has no dependency
- `nvidia-smi` for GPU telemetry, if present

Most of it runs unelevated. Reading `C:\Windows\Minidump`, the WER folders,
service control and driver installation need admin; each script says so and
elevates itself rather than failing quietly.

---

## Notes

**Nothing here downloads an installer from a vendor site.** `driver-check.ps1`
uses the Windows Update Agent API, so every offer is from Microsoft's catalogue
and signed. For GPU drivers it tells you to use the vendor's own application
instead.

**Driver Verifier is powerful and expensive.** Standard flags produced 4,355
working-set trims in 6.4 minutes on the test machine and made it close to
unusable; `Force IRQL checking` is the flag responsible. Dropping it restores
usability but reduces the chance of catching an `IRQL_NOT_LESS_OR_EQUAL` bug.
That trade is real and worth making deliberately.

**These were written for one machine.** Paths use `$PSScriptRoot` and `$env:`
so they are portable, but the process recommendations in `gaming-mode.ps1` and
the vendor notes in `driver-check.ps1` reflect one particular setup. Read them
before trusting them.

---

## Licence

MIT.
