#!/usr/bin/env python3
"""RFC/DEBUG helper for the TerraTec PHASE 88 bring-up.

Sweeps the two write-only registers of the chip-select expander (exposed by
the debug build of ews.c as "Phase88 Debug Expander Page 1/3") and records a
short sample after every value, so the meaning of the unknown bits can be
found with a signal connected to the inputs.

    usage: phase88-expander-sweep.sh [--page 1|3] [values...]

Without values it sweeps 0..255 of page 3 (the register the Terratec Windows
driver clears at init), then the flag nibble of page 1.
"""
import subprocess
import struct
import sys
import time

CARD = None
DEV = None
NUMIDS = {}
SECONDS = 1


def sh(cmd):
    return subprocess.run(cmd, capture_output=True)


def find_card():
    out = sh(["awk", "/ICE1712/{print $1; exit}", "/proc/asound/cards"]).stdout.decode().strip()
    if not out:
        sys.exit("no ICE1712 card")
    return out


def ctl_numid(name):
    out = sh(["amixer", "-c", CARD, "controls"]).stdout.decode()
    for line in out.splitlines():
        if f"name='{name}'" in line:
            return int(line.split(",")[0].split("=")[1])
    return None


def peaks():
    """record SECONDS seconds of 12 ch S32_LE and return the peak per channel"""
    r = subprocess.run(
        ["timeout", "-s", "KILL", str(SECONDS + 15), "arecord", "-q", "-D", DEV,
         "-c", "12", "-r", "48000", "-f", "S32_LE", "-d", str(SECONDS), "-t", "raw", "-"],
        capture_output=True)
    if r.returncode != 0 or len(r.stdout) < 24:
        return None, r.stderr.decode().strip()
    d = struct.unpack("<%di" % (len(r.stdout) // 4), r.stdout)
    per = []
    for c in range(12):
        ch = d[c::12]
        per.append(max(abs(x) for x in ch) if ch else 0)
    return per, None


def sweep(page, values):
    numid = NUMIDS[page]
    print(f"--- sweeping page {page} (numid {numid}), {len(values)} values "
          f"x {SECONDS}s = {len(values) * (SECONDS + 0.2) / 60:.1f} min ---")
    hits = []
    base = None
    for i, v in enumerate(values):
        sh(["amixer", "-c", CARD, "cset", f"numid={numid}", str(v)])
        time.sleep(0.05)
        per, err = peaks()
        if per is None:
            print(f"  {v:#04x}: arecord failed: {err}")
            continue
        best = max(per)
        bestch = per.index(best) + 1
        if base is None:
            base = best
        if best > max(base, 500):          # anything clearly above the baseline
            hits.append((v, best, bestch, per))
            print(f"  {v:#04x} ({v:3d}): CH{bestch} peak {best}  <-- SIGNAL {per}")
        elif i % 16 == 0:
            print(f"  {v:#04x} ({v:3d}): peak {best}")
    if not hits:
        print("  no value produced a signal above the baseline")
    return hits


def main():
    global CARD, DEV, NUMIDS
    args = sys.argv[1:]
    page = 3
    vals = None
    if args and args[0] == "--page":
        page = int(args[1])
        args = args[2:]
    if args:
        vals = [int(a, 0) for a in args]
    CARD = find_card()
    DEV = f"hw:{CARD},0"
    NUMIDS = {
        1: ctl_numid("Phase88 Debug Expander Page 1"),
        3: ctl_numid("Phase88 Debug Expander Page 3"),
    }
    if NUMIDS.get(page) is None:
        sys.exit(f"debug control for page {page} not found - is the RFC debug "
                 "build of snd-ice1712 loaded?")
    print(f"card {CARD} ({DEV}), debug numids: page1={NUMIDS[1]} page3={NUMIDS[3]}")
    print("baseline check (current register state):")
    per, err = peaks()
    if per is None:
        sys.exit(f"cannot record: {err}")
    print(f"  peaks: {per}")

    if vals is None:
        sweep(3, list(range(256)))
        sweep(1, [0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70,
                  0x80, 0x90, 0xa0, 0xb0, 0xc0, 0xd0, 0xe0, 0xf0])
    else:
        sweep(page, vals)


main()
