#!/usr/bin/env python3
"""Report for phase88-clock-measure.sh.

stdin: one sample per line, "card hw_ptr tstamp", where hw_ptr is the Envy24
capture DMA position and tstamp is the timestamp of exactly that position (the
kernel reports the pair together, which is what makes the measurement immune to
PCI and scheduling jitter).

hw_ptr is cumulative, so a straight line fit of hw_ptr over tstamp gives the
bit clock of each card.  Two cards are locked when their slopes agree far below
1 ppm; free crystals sit tens of ppm apart and drift with temperature.
"""
import sys
from collections import defaultdict

cards = defaultdict(list)
for line in sys.stdin:
    f = line.split()
    if len(f) != 3:
        continue
    try:
        cards[f[0]].append((float(f[2]), int(f[1])))
    except ValueError:
        continue

rows = []
for c in sorted(cards):
    pts = sorted(set(cards[c]))
    if len(pts) < 3:
        print(f"card {c}: not enough samples (no stream with DMA timestamps?)")
        continue
    span = pts[-1][0] - pts[0][0]
    if span <= 0:
        print(f"card {c}: timestamps did not advance")
        continue
    n = len(pts)
    sx = sum(p[0] for p in pts)
    sy = sum(p[1] for p in pts)
    sxx = sum(p[0] * p[0] for p in pts)
    sxy = sum(p[0] * p[1] for p in pts)
    slope = (n * sxy - sx * sy) / (n * sxx - sx * sx)
    # rms of the fit residuals, as a stability figure
    icpt = (sy - slope * sx) / n
    rms = (sum((y - (slope * x + icpt)) ** 2 for x, y in pts) / n) ** 0.5
    rows.append((c, slope, rms, span))

for c, slope, rms, span in rows:
    print(f"card {c}: {slope:12.3f} frames/s  {(slope / 48000.0 - 1) * 1e6:+8.2f} ppm"
          f"  vs nominal 48000   (fit over {span:.1f} s, residual {rms * 1000:.1f} us)")

if len(rows) == 2:
    d = rows[0][1] - rows[1][1]
    rel = d / rows[1][1] * 1e6
    print(f"\ncard {rows[0][0]} - card {rows[1][0]}: {d:+.5f} frames/s  {rel:+.5f} ppm")
    if abs(rel) < 0.5:
        print("=> LOCKED: well inside 1 ppm, both cards run off one clock")
    elif abs(rel) < 5.0:
        print("=> borderline: closer than two free crystals usually are.")
        print("   measure again, and compare with both cards on their own clock")
    else:
        print("=> FREE RUNNING: two independent oscillators")
        print(f"   they slip one sample every {1 / abs(d):.3f} s, so in a 10 minute"
              f" take the two cards end up {abs(d) * 600:.0f} samples apart")
