#!/usr/bin/env python3
"""
Insert ToolTip attributes into ControlPanel.ps1's inline XAML.

Done as a script rather than by hand because each tooltip has to land on the
opening tag of a specific named control, and several of those tags span
multiple lines.
"""

import re
import sys

PATH = "ControlPanel.ps1"

# Help text for named controls, keyed by x:Name.
BUTTONS = {
    "BtnRefresh": "Re-read every value on this panel now, including the GPU "
                  "(which is otherwise only polled every 20 seconds).",
    "RbVr": "VR session: start the Oculus runtime and Virtual Desktop services. "
            "Needs administrator rights, so expect a UAC prompt when you press Apply.",
    "RbFlat": "Flat session: stop the VR services. They start with Windows and keep "
              "using CPU even when no headset is connected.",
    "BtnPreClean": "Tick every recommended app. Frees the most memory, but closes "
                   "your browser too.",
    "BtnPreBrowse": "Tick everything recommended except Chrome, so you can still look "
                    "things up while playing.",
    "BtnPreWork": "Keep Chrome, Edge, Firefox and VS Code open. Frees the least - check the "
                  "headroom reading before using this with a demanding game.",
    "BtnPreNone": "Untick everything. Nothing will be closed when you press Apply.",
    "BtnApply": "Apply the VR choice, then close every ticked app. Each one is asked "
                "to close normally first so it can save; only apps that ignore that "
                "are forced after a few seconds.",
    "BtnRescan": "Rebuild the list from what is running right now. Useful after you "
                 "have opened or closed things yourself.",
    "BtnRestoreVr": "Start the VR services again and put the power plan back the way "
                    "it was. Use this when you have finished playing.",
    "BtnFaultCount": "Compare the current kernel fault counts against the saved "
                     "baseline, to see whether anything new has happened since.",
    "BtnFaultBaseline": "Save the current counts as the new baseline. Do this when you "
                        "change something and want to measure its effect from now on.",
    "BtnFaultAnalyze": "Collect crash dumps and error reports into the diag folder so "
                       "they can be read. Needs administrator rights.",
    "BtnVideoReport": "Show which programs have been using each GPU's video engines. "
                      "Intel's video engine is where the 0x141 faults happen, so this "
                      "shows what might be triggering them.",
    "BtnGpuMonitor": "Watch the GPU for five minutes (temperature, power and throttling "
                     "on NVIDIA; engine load and memory on other GPUs), and report "
                     "whether any new faults occurred.",
    "BtnCleanScan": "List what could be deleted and how much space it would free. "
                    "Changes nothing.",
    "BtnCleanApply": "Delete regenerable caches and stale crash dumps. Never touches "
                     "documents, Downloads or game installs. Needs admin.",
    "BtnReport": "Open the written investigation: what each fault was, how it was "
                 "found, and what is still open.",
    "BtnFolder": "Open the folder containing all of these scripts.",
    "BtnClearLog": "Empty the log box below.",
    "BtnCopyLog": "Copy everything in the log to the clipboard, ready to paste.",
    "TxtLog": "Everything this panel does is recorded here, with timestamps. "
              "Copy it if you want to share what happened.",
    "PnlProcs": "Programs currently using more than 150 MB. A green star marks ones "
                "that are safe to close and reopen later. Amber ones you may want to "
                "keep. System processes are never listed.",
}

# Help text for the header readings, keyed by the label inside each tile.
TILES = {
    "COMMIT": "Memory committed against the total available (RAM plus pagefile). "
              "When this reaches the limit, programs stop being able to allocate and "
              "the desktop can collapse - which has happened twice on this machine.",
    "HEADROOM": "How much commit is still free. Witcher 3 on its own needs about "
                "10 GB. Green is comfortable, amber is tight, red means a demanding "
                "game is likely to cause problems.",
    "GPU": "Current temperature and power draw of an NVIDIA GPU, read from nvidia-smi. "
           "Turns amber above 75 degrees and red above 85. Shows n/a when there is "
           "no NVIDIA GPU.",
    "FAULTS": "Kernel faults recorded by Windows, shown as 0x141 / 0x193 / 0xA. "
              "The 0x141 engine timeouts come from Intel's display driver and are the "
              "long-running problem on this machine.",
}


def insert_attr(text, idx, attr):
    """Insert attr into the opening tag containing position idx."""
    start = text.rfind("<", 0, idx)
    end = text.find(">", idx)
    if start < 0 or end < 0:
        return text, False
    tag = text[start:end]
    # Drop any ToolTip already present so this is repeatable.
    tag = re.sub(r'\s+ToolTip="[^"]*"', "", tag)
    if tag.rstrip().endswith("/"):
        tag = tag.rstrip()[:-1].rstrip() + " " + attr + " /"
    else:
        tag = tag.rstrip() + " " + attr
    return text[:start] + tag + text[end:], True


def main():
    with open(PATH, encoding="utf-8") as fh:
        src = fh.read()

    done = 0

    for name, tip in BUTTONS.items():
        needle = 'x:Name="%s"' % name
        idx = src.find(needle)
        if idx < 0:
            print("  MISSING control:", name)
            continue
        src, ok = insert_attr(src, idx, 'ToolTip="%s"' % tip)
        if ok:
            done += 1

    for label, tip in TILES.items():
        needle = 'Text="%s"' % label
        idx = src.find(needle)
        if idx < 0:
            print("  MISSING tile:", label)
            continue
        # Walk out to the Border wrapping the tile so the whole pill is hoverable.
        border = src.rfind("<Border", 0, idx)
        if border < 0:
            continue
        src, ok = insert_attr(src, border + 1, 'ToolTip="%s"' % tip)
        if ok:
            done += 1

    with open(PATH, "w", encoding="utf-8") as fh:
        fh.write(src)

    print("tooltips applied:", done)
    return 0


if __name__ == "__main__":
    sys.exit(main())
